/*
 * test_usb_hid.c -- host test for the pure USB gamepad parsing logic.
 *
 * WHAT THIS COVERS
 *   Every byte-level decision in tools/ps/app/usb_hid.c: walking a
 *   configuration descriptor to the HID interface and its interrupt IN
 *   endpoint, reading a HID report descriptor for its report size and a
 *   gamepad hint, and mapping one report to the NES button byte -- including
 *   the Report ID offset, so a device whose report starts with an ID byte has
 *   its buttons read from the bytes after it rather than from the ID.
 *
 * WHAT IT CANNOT COVER (no board, no device, no host USB stack):
 *   enumeration, control transfers, port reset, timing, a real device's actual
 *   descriptor, and anything an interrupt endpoint does.  See
 *   tools/ps/host_test/README.md.
 *
 * NON-VACUITY
 *   A stub that returned a constant would have to reproduce the exact expected
 *   endpoint, packet size, interval, interface number, report size and button
 *   byte of every case below, so the assertions themselves defeat it.  On top
 *   of that the test counts how often the endpoint search actually ran and how
 *   many report/mapping cases produced a non-zero button pattern, and fails if
 *   either is zero:
 *       endpoints_seen_total  (from usb_hid_loc_t::endpoints_seen)
 *       nonzero_btn_cases     (mapping cases whose result != 0)
 *       input_items_total     (from hid_report_info_t::input_items_seen)
 *
 * Build: tools/ps/host_test/run_host_test.ps1 (MSVC cl.exe).
 */

#include <stdio.h>
#include <string.h>

#include "usb_hid.h"

/* ------------------------------------------------------------------ harness */

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond, what)                                                   \
    do {                                                                    \
        g_checks++;                                                         \
        if (!(cond)) {                                                      \
            g_failures++;                                                   \
            printf("  FAIL  %s  (line %d)\n", (what), __LINE__);            \
        }                                                                   \
    } while (0)

/* Non-vacuity accumulators. */
static int g_endpoints_seen_total = 0;
static int g_nonzero_btn_cases = 0;
static int g_input_items_total = 0;

/* ------------------------------------------------- descriptor building blocks */

static unsigned char g_cfg[512];
static int g_cfg_len = 0;

static const unsigned char DT_CONFIG_HDR[9] =
    { 9, USB_DT_CONFIG, 0, 0, /*wTotalLength patched*/ 0, 1, 0, 0x80, 50 };

static const unsigned char IF_VENDOR[9] =
    { 9, USB_DT_INTERFACE, 0, 0, 1, 0xFF, 0, 0, 0 };
static const unsigned char IF_HID_0[9] =
    { 9, USB_DT_INTERFACE, 0, 0, 1, USB_CLASS_HID, 0, 0, 0 };
static const unsigned char IF_HID_1[9] =
    { 9, USB_DT_INTERFACE, 1, 0, 1, USB_CLASS_HID, 0, 0, 0 };

static const unsigned char EP_BULK_OUT[7]  = { 7, USB_DT_ENDPOINT, 0x01, 0x02, 64, 0, 0 };
static const unsigned char EP_INT_IN_8[7]  = { 7, USB_DT_ENDPOINT, 0x81, 0x03, 8, 0, 10 };
static const unsigned char EP_INT_IN_16[7] = { 7, USB_DT_ENDPOINT, 0x82, 0x03, 16, 0, 5 };
static const unsigned char EP_INT_IN_64[7] = { 7, USB_DT_ENDPOINT, 0x83, 0x03, 64, 0, 1 };

/* bLength=9, bDescriptorType=0x21, bcdHID=0x0111, bCountryCode=0,
 * bNumDescriptors=1, bDescriptorType=0x22 REPORT, wDescriptorLength=2. */
static const unsigned char DT_HID_LEN2[9] =
    { 9, USB_DT_HID, 0x11, 0x01, 0, 1, USB_DT_REPORT, 2, 0 };

static void cfg_start(void)
{
    memset(g_cfg, 0, sizeof(g_cfg));
    g_cfg_len = 0;
}

static void cfg_put(const unsigned char *p, int n)
{
    memcpy(g_cfg + g_cfg_len, p, (size_t)n);
    g_cfg_len += n;
}

/* Emit the configuration header with wTotalLength set to the running total. */
static void cfg_header(void)
{
    memcpy(g_cfg, DT_CONFIG_HDR, 9);
    g_cfg_len = 9;
}

static void cfg_patch_total(int total)
{
    g_cfg[2] = (unsigned char)(total & 0xFF);
    g_cfg[3] = (unsigned char)((total >> 8) & 0xFF);
}

/* Run one configuration-descriptor case and accumulate non-vacuity. */
static int parse_cfg(const unsigned char *buf, int len, usb_hid_loc_t *out)
{
    int rc = usb_parse_config_descriptor(buf, len, out);
    g_endpoints_seen_total += out->endpoints_seen;
    return rc;
}

/* -------------------------------------------------------- config-desc cases */

static void test_config_descriptors(void)
{
    usb_hid_loc_t loc;
    int rc;

    printf("[configuration descriptors]\n");

    /* Case 1: well-formed gamepad, HID interface first, 8-byte interrupt IN. */
    cfg_start();
    cfg_header();
    cfg_put(IF_HID_0, 9);
    cfg_put(DT_HID_LEN2, 9);
    cfg_put(EP_INT_IN_8, 7);
    cfg_patch_total(g_cfg_len);
    memset(&loc, 0xAB, sizeof(loc));
    rc = parse_cfg(g_cfg, g_cfg_len, &loc);
    CHECK(rc == USB_PARSE_OK, "case1: parses");
    CHECK(loc.hid_interface == 0, "case1: HID interface number == 0");
    CHECK(loc.ep_address == 0x81, "case1: endpoint 0x81");
    CHECK(loc.max_packet_size == 8, "case1: wMaxPacketSize == 8");
    CHECK(loc.interval == 10, "case1: bInterval == 10");
    CHECK(loc.report_desc_len == 2, "case1: HID report descriptor length == 2");
    CHECK(loc.interfaces_seen == 1, "case1: 1 interface walked");
    CHECK(loc.endpoints_seen == 1, "case1: 1 endpoint walked (search reached)");
    CHECK(loc.hid_interfaces_seen == 1, "case1: 1 HID interface");

    /* Case 2: HID interface NOT first, and a non-default wMaxPacketSize (16). */
    cfg_start();
    cfg_header();
    cfg_put(IF_VENDOR, 9);
    cfg_put(EP_BULK_OUT, 7);
    cfg_put(IF_HID_1, 9);
    cfg_put(DT_HID_LEN2, 9);
    cfg_put(EP_INT_IN_16, 7);
    cfg_patch_total(g_cfg_len);
    memset(&loc, 0xAB, sizeof(loc));
    rc = parse_cfg(g_cfg, g_cfg_len, &loc);
    CHECK(rc == USB_PARSE_OK, "case2: parses");
    CHECK(loc.hid_interface == 1, "case2: HID interface is the SECOND one");
    CHECK(loc.ep_address == 0x82, "case2: endpoint 0x82");
    CHECK(loc.max_packet_size == 16, "case2: non-default wMaxPacketSize == 16");
    CHECK(loc.interval == 5, "case2: bInterval == 5");
    CHECK(loc.interfaces_seen == 2, "case2: 2 interfaces walked");
    CHECK(loc.endpoints_seen == 2, "case2: 2 endpoints walked");
    CHECK(loc.hid_interfaces_seen == 1, "case2: 1 HID interface");

    /* Case 3: another non-default wMaxPacketSize (64). */
    cfg_start();
    cfg_header();
    cfg_put(IF_HID_0, 9);
    cfg_put(DT_HID_LEN2, 9);
    cfg_put(EP_INT_IN_64, 7);
    cfg_patch_total(g_cfg_len);
    rc = parse_cfg(g_cfg, g_cfg_len, &loc);
    CHECK(rc == USB_PARSE_OK, "case3: parses");
    CHECK(loc.ep_address == 0x83, "case3: endpoint 0x83");
    CHECK(loc.max_packet_size == 64, "case3: wMaxPacketSize == 64");
    CHECK(loc.interval == 1, "case3: bInterval == 1");

    /* Case 4a: HID interface present, but only a BULK OUT endpoint -> a HID
     * interface with no interrupt IN endpoint (a DIFFERENT failure from
     * "no HID interface"). */
    cfg_start();
    cfg_header();
    cfg_put(IF_HID_0, 9);
    cfg_put(DT_HID_LEN2, 9);
    cfg_put(EP_BULK_OUT, 7);
    cfg_patch_total(g_cfg_len);
    rc = parse_cfg(g_cfg, g_cfg_len, &loc);
    CHECK(rc == USB_PARSE_ERR_NO_INT_IN, "case4a: HID interface, no interrupt IN endpoint");

    /* Case 4b: a perfectly good interface with an interrupt IN endpoint, but no
     * HID interface at all -> NO_HID (the other half of the distinction). */
    cfg_start();
    cfg_header();
    cfg_put(IF_VENDOR, 9);
    cfg_put(EP_INT_IN_8, 7);
    cfg_patch_total(g_cfg_len);
    rc = parse_cfg(g_cfg, g_cfg_len, &loc);
    CHECK(rc == USB_PARSE_ERR_NO_HID, "case4b: interrupt IN endpoint but no HID interface");

    /* Case 5a: wTotalLength claims more than the buffer holds -> TRUNCATED. */
    cfg_start();
    cfg_header();
    cfg_put(IF_HID_0, 9);
    cfg_put(DT_HID_LEN2, 9);
    cfg_put(EP_INT_IN_8, 7);
    cfg_patch_total(g_cfg_len + 64);
    rc = parse_cfg(g_cfg, g_cfg_len, &loc);
    CHECK(rc == USB_PARSE_ERR_TRUNCATED, "case5a: wTotalLength past the buffer");

    /* Case 5b: wTotalLength ends in the MIDDLE of a descriptor -> TRUNCATED. */
    cfg_start();
    cfg_header();
    cfg_put(IF_HID_0, 9);
    cfg_put(DT_HID_LEN2, 9);
    cfg_put(EP_INT_IN_8, 7);
    cfg_patch_total(9 + 9 + 4);   /* 4 bytes into the 7-byte endpoint */
    rc = parse_cfg(g_cfg, g_cfg_len, &loc);
    CHECK(rc == USB_PARSE_ERR_TRUNCATED, "case5b: descriptor runs past wTotalLength");

    /* Case 5c: a zero-length descriptor -> BAD_LENGTH (must not walk off). */
    cfg_start();
    cfg_header();
    cfg_put(IF_HID_0, 9);
    g_cfg[g_cfg_len] = 0;          /* bLength = 0 */
    g_cfg[g_cfg_len + 1] = 0x21;   /* some type */
    g_cfg_len += 2;
    cfg_patch_total(g_cfg_len);
    rc = parse_cfg(g_cfg, g_cfg_len, &loc);
    CHECK(rc == USB_PARSE_ERR_BAD_LENGTH, "case5c: zero-length descriptor rejected");

    /* Case 6: shorter than a configuration descriptor. */
    rc = parse_cfg(g_cfg, 5, &loc);
    CHECK(rc == USB_PARSE_ERR_TOO_SHORT, "case6: len < 9 rejected");

    /* Case 7: first descriptor is not a CONFIGURATION. */
    cfg_start();
    cfg_header();
    g_cfg[1] = USB_DT_INTERFACE;
    rc = parse_cfg(g_cfg, g_cfg_len, &loc);
    CHECK(rc == USB_PARSE_ERR_NOT_CONFIG, "case7: not a configuration descriptor");
}

/* ----------------------------------------------------------- HID desc cases */

static const unsigned char RD_GAMEPAD_16BTN[] = {
    0x05, 0x01,        /* Usage Page (Generic Desktop) */
    0x09, 0x05,        /* Usage (Game Pad) */
    0xA1, 0x01,        /* Collection (Application) */
    0x05, 0x09,        /*   Usage Page (Button) */
    0x19, 0x01,        /*   Usage Minimum (1) */
    0x29, 0x10,        /*   Usage Maximum (16) */
    0x15, 0x00,        /*   Logical Minimum (0) */
    0x25, 0x01,        /*   Logical Maximum (1) */
    0x95, 0x10,        /*   Report Count (16) */
    0x75, 0x01,        /*   Report Size (1) */
    0x81, 0x02,        /*   Input (Data,Var,Abs)  -> 16 bits = 2 bytes */
    0xC0               /* End Collection */
};

static const unsigned char RD_GAMEPAD_AXES[] = {
    0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x08,
    0x15, 0x00, 0x25, 0x01, 0x95, 0x08, 0x75, 0x01, 0x81, 0x02, /* 8 buttons = 8 bits */
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7F,
    0x75, 0x08, 0x95, 0x02, 0x81, 0x02,                          /* X,Y = 16 bits   */
    0xC0
};

/* Same 16-button gamepad, but with a Report ID (0x03) declared before the
 * buttons.  On the wire the report is [ID][byte0][byte1], so report_bytes must
 * be 3 (2 button bytes + the ID) and a mapper that ignores the ID reads the ID
 * byte as buttons.  This is the descriptor shape a real device may use. */
static const unsigned char RD_GAMEPAD_REPORTID[] = {
    0x05, 0x01,        /* Usage Page (Generic Desktop) */
    0x09, 0x05,        /* Usage (Game Pad) */
    0xA1, 0x01,        /* Collection (Application) */
    0x85, 0x03,        /*   Report ID (3) */
    0x05, 0x09,        /*   Usage Page (Button) */
    0x19, 0x01,        /*   Usage Minimum (1) */
    0x29, 0x10,        /*   Usage Maximum (16) */
    0x15, 0x00,        /*   Logical Minimum (0) */
    0x25, 0x01,        /*   Logical Maximum (1) */
    0x95, 0x10,        /*   Report Count (16) */
    0x75, 0x01,        /*   Report Size (1) */
    0x81, 0x02,        /*   Input (Data,Var,Abs) -> 16 bits = 2 bytes + ID */
    0xC0               /* End Collection */
};

static const unsigned char RD_MOUSE[] = {
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,       /* Generic Desktop / Mouse */
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
    0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02, /* 3 buttons */
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
    0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02, /* X,Y */
    0xC0
};

static int parse_rd(const unsigned char *buf, int len, hid_report_info_t *out)
{
    int rc = hid_parse_report_descriptor(buf, len, out);
    g_input_items_total += out->input_items_seen;
    return rc;
}

static void test_report_descriptors(void)
{
    hid_report_info_t info;
    int rc;

    printf("[HID report descriptors]\n");

    memset(&info, 0xAB, sizeof(info));
    rc = parse_rd(RD_GAMEPAD_16BTN, (int)sizeof(RD_GAMEPAD_16BTN), &info);
    CHECK(rc == HID_PARSE_OK, "rd1: parses");
    CHECK(info.report_bytes == 2, "rd1: 16 buttons -> 2 report bytes");
    CHECK(info.is_gamepad == 1, "rd1: looks like a gamepad");
    CHECK(info.button_page_seen == 1, "rd1: Button page seen");
    CHECK(info.gamepad_usage_seen == 1, "rd1: Usage (Game Pad) seen");
    CHECK(info.input_items_seen == 1, "rd1: 1 Input item");

    memset(&info, 0xAB, sizeof(info));
    rc = parse_rd(RD_GAMEPAD_AXES, (int)sizeof(RD_GAMEPAD_AXES), &info);
    CHECK(rc == HID_PARSE_OK, "rd2: parses");
    CHECK(info.report_bytes == 3, "rd2: 8 buttons + 2 axes -> 3 report bytes");
    CHECK(info.is_gamepad == 1, "rd2: looks like a gamepad");
    CHECK(info.input_items_seen == 2, "rd2: 2 Input items");

    memset(&info, 0xAB, sizeof(info));
    rc = parse_rd(RD_MOUSE, (int)sizeof(RD_MOUSE), &info);
    CHECK(rc == HID_PARSE_OK, "rd3: mouse parses");
    CHECK(info.is_gamepad == 0, "rd3: a mouse is NOT a gamepad");
    CHECK(info.button_page_seen == 1, "rd3: mouse has a Button page too");

    /* A gamepad that declares a Report ID: the declared size must include the
     * ID prefix byte, and report_id_seen must be set so the caller knows the
     * offset.  If this were 2 the mapper would be handed a length one byte too
     * small and would read the ID as buttons. */
    memset(&info, 0xAB, sizeof(info));
    rc = parse_rd(RD_GAMEPAD_REPORTID, (int)sizeof(RD_GAMEPAD_REPORTID), &info);
    CHECK(rc == HID_PARSE_OK, "rd6: report-ID gamepad parses");
    CHECK(info.report_id_seen == 1, "rd6: Report ID was seen");
    CHECK(info.report_bytes == 3, "rd6: 16 buttons + Report ID -> 3 report bytes (incl. ID)");
    CHECK(info.is_gamepad == 1, "rd6: still looks like a gamepad");
    CHECK(info.input_items_seen == 1, "rd6: 1 Input item");

    /* Truncated: Usage Page (bSize=2) with only one data byte present. */
    {
        static const unsigned char rd_bad[] = { 0x05, 0x01, 0x06, 0x01 };
        memset(&info, 0xAB, sizeof(info));
        rc = parse_rd(rd_bad, (int)sizeof(rd_bad), &info);
        CHECK(rc == HID_PARSE_ERR_TRUNCATED, "rd4: truncated item rejected");
    }

    /* Empty. */
    memset(&info, 0xAB, sizeof(info));
    rc = parse_rd(0, 0, &info);
    CHECK(rc == HID_PARSE_ERR_TOO_SHORT, "rd5: empty report descriptor rejected");
}

/* ------------------------------------------------------------- mapping cases */

static void map_case(const char *what, const unsigned char *rep, int len,
                     int bytes, int offset, uint8_t expect)
{
    uint8_t got = nes_buttons_from_report(rep, len, bytes, offset);
    if (got != 0) { g_nonzero_btn_cases++; }
    CHECK(got == expect, what);
    if (got != expect) {
        printf("        expected 0x%02X, got 0x%02X\n", expect, got);
    }
}

static void test_button_mapping(void)
{
    static const unsigned char all_on[2]   = { 0xFF, 0xFF };
    static const unsigned char all_off[2]  = { 0x00, 0x00 };
    static const unsigned char a_only[2]   = { 0x01, 0x00 };
    static const unsigned char b_only[2]   = { 0x02, 0x00 };
    static const unsigned char sel_only[2] = { 0x00, 0x01 };
    static const unsigned char sta_only[2] = { 0x00, 0x02 };
    static const unsigned char up_only[2]  = { 0x00, 0x10 };
    static const unsigned char dn_only[2]  = { 0x00, 0x20 };
    static const unsigned char lf_only[2]  = { 0x00, 0x40 };
    static const unsigned char rt_only[2]  = { 0x00, 0x80 };
    static const unsigned char a_right[2]  = { 0x01, 0x80 };
    static const unsigned char junk[2]     = { 0xFC, 0x0C }; /* only unused bits */
    static const unsigned char one_byte[1] = { 0x03 };
    static const unsigned char one_byte_pad[2] = { 0x03, 0xFF };

    /* Report-ID cases: report[0] is the ID, so the buttons start at [1].  The
     * ID bytes below are chosen so that a mapper which ignores the offset reads
     * a WRONG button (or none) from report[0]/report[1]; the expected value can
     * therefore only be produced by honouring the offset.  This is the case
     * that fails against a version of nes_buttons_from_report() that reads
     * report[0] as the first button byte. */
    static const unsigned char rid_id_only[3] = { 0x03, 0x00, 0x00 }; /* ID=3, nothing pressed */
    static const unsigned char rid_a[3]       = { 0x03, 0x01, 0x00 }; /* ID=3, A */
    static const unsigned char rid_b[3]       = { 0x03, 0x02, 0x00 }; /* ID=3, B */
    static const unsigned char rid_sel[3]     = { 0x05, 0x00, 0x01 }; /* ID=5 (aliases A), Select */
    static const unsigned char rid_up[3]      = { 0x07, 0x00, 0x10 }; /* ID=7 (aliases A/B), Up */
    static const unsigned char rid_all[3]     = { 0x01, 0xFF, 0xFF };
    static const unsigned char rid_short[2]   = { 0x03, 0x02 };       /* ID + only 1 button byte */
    uint8_t got;

    printf("[report -> NES buttons]\n");

    map_case("every button pressed -> 0xFF", all_on, 2, 2, 0, 0xFF);
    map_case("no button pressed -> 0x00", all_off, 2, 2, 0, 0x00);
    map_case("only A -> 0x01", a_only, 2, 2, 0, NES_BTN_A);
    map_case("only B -> 0x02", b_only, 2, 2, 0, NES_BTN_B);
    map_case("only Select -> 0x04", sel_only, 2, 2, 0, NES_BTN_SELECT);
    map_case("only Start -> 0x08", sta_only, 2, 2, 0, NES_BTN_START);
    map_case("only Up -> 0x10", up_only, 2, 2, 0, NES_BTN_UP);
    map_case("only Down -> 0x20", dn_only, 2, 2, 0, NES_BTN_DOWN);
    map_case("only Left -> 0x40", lf_only, 2, 2, 0, NES_BTN_LEFT);
    map_case("only Right -> 0x80", rt_only, 2, 2, 0, NES_BTN_RIGHT);
    map_case("A + Right -> 0x81", a_right, 2, 2, 0, NES_BTN_A | NES_BTN_RIGHT);
    map_case("unused bits only -> 0x00", junk, 2, 2, 0, 0x00);

    /* A one-byte report can only ever set A/B. */
    map_case("1-byte report 0x03 -> A|B", one_byte, 1, 1, 0, NES_BTN_A | NES_BTN_B);

    /* The parser says report_bytes == 1, so the trailing 0xFF must be ignored:
     * this proves the mapping honours the report size, not just the buffer. */
    got = nes_buttons_from_report(one_byte_pad, 2, 1, 0);
    if (got != 0) { g_nonzero_btn_cases++; }
    CHECK(got == (NES_BTN_A | NES_BTN_B), "report_bytes==1 ignores byte 1");

    /* --- report-ID cases: the offset must be honoured ----------------------- */
    map_case("report-ID: nothing (ID=3) -> 0x00", rid_id_only, 3, 3, 1, 0x00);
    map_case("report-ID: A after ID=3 -> 0x01", rid_a, 3, 3, 1, NES_BTN_A);
    map_case("report-ID: B after ID=3 -> 0x02", rid_b, 3, 3, 1, NES_BTN_B);
    map_case("report-ID: Select, ID=5 aliases A -> 0x04", rid_sel, 3, 3, 1, NES_BTN_SELECT);
    map_case("report-ID: Up, ID=7 aliases A/B -> 0x10", rid_up, 3, 3, 1, NES_BTN_UP);
    map_case("report-ID: every button -> 0xFF", rid_all, 3, 3, 1, 0xFF);
    /* Only 1 button byte arrived (the ID plus one): offset 1 leaves usable==1,
     * so only A/B can be set and byte [2] is never read. */
    map_case("report-ID: 1 button byte only -> B", rid_short, 2, 3, 1, NES_BTN_B);

    /* An offset past the available bytes must yield no buttons, never an
     * out-of-range read. */
    CHECK(nes_buttons_from_report(rid_a, 3, 3, 3) == 0x00,
          "report-ID: offset past the end -> 0x00");
    CHECK(nes_buttons_from_report(rid_a, 3, 3, -1) == 0x00,
          "report-ID: negative offset -> 0x00");
}

/* ------------------------------------------------------------------- main */

int main(void)
{
    printf("=== host test: usb_hid (pure USB gamepad parsing) ===\n");

    test_config_descriptors();
    test_report_descriptors();
    test_button_mapping();

    printf("\n[non-vacuity counters]\n");
    printf("  checks                = %d\n", g_checks);
    printf("  endpoints_seen_total  = %d\n", g_endpoints_seen_total);
    printf("  input_items_total     = %d\n", g_input_items_total);
    printf("  nonzero_btn_cases     = %d\n", g_nonzero_btn_cases);

    /* The parser must actually have reached the endpoint-finding code. */
    CHECK(g_endpoints_seen_total > 0, "endpoint search was reached (non-vacuous)");
    CHECK(g_input_items_total > 0, "report-descriptor Input items were reached");
    CHECK(g_nonzero_btn_cases > 0, "at least one non-zero button pattern was produced");

    printf("\n%s: %d checks, %d failure(s)\n",
           (g_failures == 0) ? "PASS" : "FAIL", g_checks, g_failures);
    return (g_failures == 0) ? 0 : 1;
}
