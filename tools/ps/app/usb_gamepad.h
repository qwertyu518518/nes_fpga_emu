/*
 * usb_gamepad.h -- USB HID gamepad on USB0 (host mode), the hardware half.
 *
 * THIS FILE TALKS TO SILICON AND CANNOT BE TESTED HERE.
 *   It uses the BSP's `xusbps` driver (a driver library, not vendor reference
 *   RTL) to bring USB0 up in host mode, enumerate one attached device through
 *   the control endpoint, hand the configuration descriptor to the host-tested
 *   parser in usb_hid.c, and poll the HID interrupt IN endpoint.  Nothing in
 *   this file runs on the host: no board is reachable, no device can be
 *   attached, and the project gate is Verilog.  See tools/ps/README.md,
 *   "USB gamepad", for exactly which parts are unverified.
 *
 * THE FAILURE CONTRACT
 *   Every stage returns a distinct code so the caller can name the stage it
 *   died at over UART and a stuck-at-silence path cannot hide.  In particular
 *   "configuration descriptor malformed", "no HID interface" and "no interrupt
 *   IN endpoint" are three different codes because a user needs to know which.
 */

#ifndef USB_GAMEPAD_H
#define USB_GAMEPAD_H

#include <stdint.h>

typedef enum {
    USBGP_OK                    =  0,
    USBGP_ERR_LOOKUP            = -1,  /* XUsbPs_LookupConfig returned NULL       */
    USBGP_ERR_CFG_INIT          = -2,  /* XUsbPs_CfgInitialize failed             */
    USBGP_ERR_DEV_CONFIG        = -3,  /* XUsbPs_ConfigureDevice (QH/DMA) failed  */
    USBGP_ERR_NO_DEVICE         = -4,  /* no connect detected / port reset failed */
    USBGP_ERR_DEV_DESCRIPTOR    = -5,  /* GET_DESCRIPTOR(device) failed/malformed */
    USBGP_ERR_SET_ADDRESS       = -6,  /* SET_ADDRESS failed                      */
    USBGP_ERR_CONFIG_DESCRIPTOR = -7,  /* GET_DESCRIPTOR(config) failed/malformed */
    USBGP_ERR_NO_HID            = -8,  /* config parsed, but no HID interface     */
    USBGP_ERR_NO_INT_IN         = -9,  /* HID interface has no interrupt IN ep    */
    USBGP_ERR_SET_CONFIG        = -10, /* SET_CONFIGURATION failed                */
    USBGP_ERR_SET_IDLE          = -11, /* SET_IDLE failed                         */
    USBGP_ERR_POLL              = -12, /* interrupt IN endpoint poll failed       */
    USBGP_ERR_REPORT_DESCRIPTOR = -13, /* GET_DESCRIPTOR(report) failed/malformed */
    USBGP_ERR_NOT_GAMEPAD       = -14  /* report descriptor is not a gamepad      */
} usbgp_status_t;

/* The parsed HID location and report sizing, as found during enumeration. */
typedef struct {
    uint8_t  hid_interface;
    uint8_t  ep_address;      /* bit 7 set == IN */
    uint16_t max_packet_size;
    uint8_t  interval;
    uint16_t report_bytes;
    int      is_gamepad;
    /* carried straight through from the host-tested parser for diagnostics */
    int      interfaces_seen;
    int      endpoints_seen;
} usb_gamepad_info_t;

/* A printable, stage-naming string for a usbgp_status_t (never NULL). */
const char *usbgp_strerror(int status);

/*
 * Bring USB0 up in host mode: look up the controller, initialise it, set up
 * the endpoint DMA/QH memory, switch to host mode, power the root port and
 * start the controller.  Returns USBGP_OK or a USBGP_ERR_* code.
 */
int usb_gamepad_init(void);

/*
 * Enumerate the device on the root port: wait for connect, bus-reset, read the
 * device descriptor, SET_ADDRESS, read the configuration descriptor, locate the
 * HID interrupt IN endpoint with the host-tested parser, SET_CONFIGURATION and
 * SET_IDLE.  Returns USBGP_OK or a stage-specific USBGP_ERR_* code.
 */
int usb_gamepad_enumerate(void);

/* The result of the last successful usb_gamepad_enumerate(). */
usb_gamepad_info_t usb_gamepad_info(void);

/*
 * Poll the HID interrupt IN endpoint once.  On a completed report, writes the
 * mapped NES button byte to *nes_buttons and returns USBGP_OK.  Returns
 * USBGP_ERR_POLL if the endpoint read failed.  A poll with no report ready is
 * reported as USBGP_OK with *nes_buttons left at its previous value; the caller
 * distinguishes the two by its own cadence, not by this call.
 */
int usb_gamepad_poll(uint8_t *nes_buttons);

/* Stop the controller. */
void usb_gamepad_close(void);

#endif /* USB_GAMEPAD_H */
