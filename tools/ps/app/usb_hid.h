/*
 * usb_hid.h -- pure USB HID parsing and the HID-report-to-NES-button mapping.
 *
 * WHY THIS FILE EXISTS
 *   The USB gamepad path has two halves that fail very differently.  One half
 *   talks to silicon (controller init, port reset, control transfers, an
 *   interrupt endpoint) and cannot be exercised without the board and a real
 *   device.  The other half is a pure function of bytes: walk a configuration
 *   descriptor to find the HID interface and its interrupt IN endpoint, read a
 *   HID report descriptor well enough to know the report length and whether the
 *   device is a gamepad, and turn one report into the 8 NES buttons.
 *
 *   Everything in this file is that second half.  It includes no Xilinx header,
 *   allocates nothing, and touches no hardware, so it compiles and is asserted
 *   on the host by tb-adjacent tooling (tools/ps/host_test).  What that test
 *   cannot cover is stated explicitly in tools/ps/host_test/README.md: none of
 *   the enumeration, transfer, timing or device behaviour is reachable from
 *   here.
 *
 * NES BUTTON BIT ORDER (authority: rtl/nes_core/controller/nes_controller.v)
 *   The controller latches `buttons` and shifts bit 0 out first on $4016:
 *
 *       buttons[0] = A       (nes_controller.v:62, :88-90)
 *       buttons[1] = B
 *       buttons[2] = Select
 *       buttons[3] = Start
 *       buttons[4] = Up
 *       buttons[5] = Down
 *       buttons[6] = Left
 *       buttons[7] = Right
 *
 *   The same order is named in rtl/nes_core/peripheral/nes_touch_input.v:92-94,
 *   whose `buttons = {touch_dpad, key_start, key_select, btn_b, btn_a}` puts
 *   {Up,Down,Left,Right} in bits 7..4 and Start/Select at 3/2.  That is the
 *   order this file produces.
 */

#ifndef USB_HID_H
#define USB_HID_H

#include <stdint.h>

/* ---- NES controller byte (see the bit order note above) ------------------ */
#define NES_BTN_A       0x01u
#define NES_BTN_B       0x02u
#define NES_BTN_SELECT  0x04u
#define NES_BTN_START   0x08u
#define NES_BTN_UP      0x10u
#define NES_BTN_DOWN    0x20u
#define NES_BTN_LEFT    0x40u
#define NES_BTN_RIGHT   0x80u

/* ---- USB descriptor types (USB 2.0, section 9.6) ------------------------- */
#define USB_DT_DEVICE     0x01u
#define USB_DT_CONFIG     0x02u
#define USB_DT_STRING     0x03u
#define USB_DT_INTERFACE  0x04u
#define USB_DT_ENDPOINT   0x05u
#define USB_DT_HID        0x21u
#define USB_DT_REPORT     0x22u

#define USB_CLASS_HID     0x03u

/* bmAttributes transfer type, low two bits (USB 2.0, table 9-13). */
#define USB_XFER_CONTROL     0x00u
#define USB_XFER_ISOCHRONOUS 0x01u
#define USB_XFER_BULK        0x02u
#define USB_XFER_INTERRUPT   0x03u

/* ---- configuration-descriptor walk --------------------------------------- */

/* Every failure is a distinct code so the caller can name the stage it died
 * at.  A silent stall would be the worst outcome, so "no HID interface" and
 * "HID interface but no interrupt IN endpoint" are different codes. */
#define USB_PARSE_OK                 0
#define USB_PARSE_ERR_TOO_SHORT     -1   /* buffer shorter than a config descriptor  */
#define USB_PARSE_ERR_NOT_CONFIG    -2   /* first descriptor is not a CONFIGURATION   */
#define USB_PARSE_ERR_BAD_LENGTH    -3   /* a bLength is zero, or < the fixed size    */
#define USB_PARSE_ERR_TRUNCATED     -4   /* a descriptor runs past wTotalLength/len   */
#define USB_PARSE_ERR_NO_HID        -5   /* no interface has bInterfaceClass == 3     */
#define USB_PARSE_ERR_NO_INT_IN     -6   /* HID interface has no interrupt IN endpoint*/

/* Where the HID interface and its interrupt IN endpoint live, plus counters
 * that let a test prove the walk actually reached the endpoint search instead
 * of passing vacuously. */
typedef struct {
    uint8_t  hid_interface;      /* bInterfaceNumber of the HID interface        */
    uint8_t  ep_address;         /* bEndpointAddress (bit 7 set: IN)             */
    uint16_t max_packet_size;    /* wMaxPacketSize                                */
    uint8_t  interval;           /* bInterval                                     */
    uint16_t report_desc_len;    /* wDescriptorLength from the HID descriptor    */
    uint8_t  report_desc_iface;  /* interface the HID descriptor belonged to     */

    /* Non-vacuity / diagnostics.  These are results of the search, not inputs. */
    int      interfaces_seen;    /* INTERFACE descriptors walked                 */
    int      endpoints_seen;     /* ENDPOINT descriptors walked                  */
    int      hid_interfaces_seen;/* interface descriptors with class == HID      */
} usb_hid_loc_t;

/*
 * Walk a configuration descriptor (the bytes USB returns for
 * GET_DESCRIPTOR(CONFIGURATION)) and locate the HID interface and its
 * interrupt IN endpoint.  `buf`/`len` is the whole descriptor block; `len` may
 * exceed wTotalLength (a host often reads a 64-byte buffer for a smaller
 * descriptor), in which case the walk is bounded by wTotalLength.
 *
 * Returns USB_PARSE_OK or one of the USB_PARSE_ERR_* codes.  On any error the
 * caller must treat `out` as meaningless and must not read the endpoint fields.
 */
int usb_parse_config_descriptor(const uint8_t *buf, int len, usb_hid_loc_t *out);

/* A stable, printable name for a usb_parse_* code (never NULL). */
const char *usb_parse_strerror(int rc);

/* ---- HID report descriptor ----------------------------------------------- */

#define HID_PARSE_OK              0
#define HID_PARSE_ERR_TOO_SHORT  -1   /* empty / NULL report descriptor            */
#define HID_PARSE_ERR_TRUNCATED  -2   /* an item's data runs past the end          */

/* What the report descriptor says, as far as this project needs it. */
typedef struct {
    int report_bytes;      /* total input report size in bytes (incl. report ID) */
    int is_gamepad;        /* heuristically yes/no (see the .c file)             */

    /* Non-vacuity / diagnostics. */
    int input_items_seen;          /* Main Input items                          */
    int report_count_seen;         /* Report Count globals                      */
    int usage_page_seen;           /* Usage Page globals                        */
    int button_page_seen;          /* a Button page (0x09) usage was seen       */
    int generic_desktop_seen;      /* a Generic Desktop page (0x01) was seen    */
    int gamepad_usage_seen;        /* Usage (Game Pad == 0x05) or Joystick      */
    int mouse_or_keyboard_seen;    /* Usage (Mouse == 0x02) or Keyboard == 0x06 */
    int report_id_seen;            /* a Report ID item exists (adds a prefix)   */
} hid_report_info_t;

/*
 * Walk a HID report descriptor and total up the input-report size, and decide
 * whether it looks like a gamepad.  This is deliberately shallow: it does NOT
 * locate individual fields, so which report bit is which button is *not* read
 * from here -- see nes_buttons_from_report() for the fixed documented button
 * layout this project accepts.
 *
 * Returns HID_PARSE_OK or a HID_PARSE_ERR_* code.
 */
int hid_parse_report_descriptor(const uint8_t *buf, int len, hid_report_info_t *out);

const char *hid_parse_strerror(int rc);

/* ---- report -> NES buttons ------------------------------------------------ */

/*
 * Map one HID input report to the NES controller byte.
 *
 * The accepted report layout is a fixed, documented convention (this project
 * has no vendor reference and no device to interrogate, so the button order is
 * a contract, not a discovery):
 *
 *   report[0]: bit0 = A        -> NES A
 *              bit1 = B        -> NES B
 *              bit2 = C        -> ignored
 *              bit3 = X        -> ignored
 *              bit4 = L1       -> ignored
 *              bit5 = R1       -> ignored
 *              bit6 = L2       -> ignored
 *              bit7 = R2       -> ignored
 *   report[1]: bit0 = Select   -> NES Select
 *              bit1 = Start    -> NES Start
 *              bit4 = Up       -> NES Up
 *              bit5 = Down     -> NES Down
 *              bit6 = Left     -> NES Left
 *              bit7 = Right    -> NES Right
 *
 * Only the bytes the report actually has are read: a 1-byte report can only
 * ever set A/B, and a report shorter than `report_bytes` is never read past its
 * caller-declared length.  Returns the NES byte (0 when nothing is pressed).
 */
uint8_t nes_buttons_from_report(const uint8_t *report, int report_len, int report_bytes);

#endif /* USB_HID_H */
