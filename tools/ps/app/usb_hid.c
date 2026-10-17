/*
 * usb_hid.c -- the pure half of the USB gamepad path.  See usb_hid.h.
 *
 * No Xilinx header, no hardware, no allocation: this file is a function of its
 * byte arguments and is asserted on the host by tools/ps/host_test.
 */

#include <string.h>

#include "usb_hid.h"

/* ------------------------------------------------------------------------- */
/* configuration descriptor walk                                              */
/* ------------------------------------------------------------------------- */

static void zero_loc(usb_hid_loc_t *out)
{
    if (out != 0) {
        memset(out, 0, sizeof(*out));
    }
}

int usb_parse_config_descriptor(const uint8_t *buf, int len, usb_hid_loc_t *out)
{
    int pos;
    int total;
    int saw_hid_interface = 0;
    int cur_is_hid = 0;
    uint8_t cur_iface = 0;
    int found = 0;

    zero_loc(out);

    if (buf == 0 || len < 9) {
        return USB_PARSE_ERR_TOO_SHORT;
    }
    if (buf[1] != USB_DT_CONFIG) {
        return USB_PARSE_ERR_NOT_CONFIG;
    }

    /* wTotalLength is the size of the whole configuration block.  The caller's
     * buffer may be larger (a 64-byte read of a shorter descriptor), so the
     * walk is bounded by the smaller of the two. */
    total = (int)buf[2] | ((int)buf[3] << 8);
    if (total > len) {
        return USB_PARSE_ERR_TRUNCATED;
    }
    if (total < 9) {
        return USB_PARSE_ERR_BAD_LENGTH;
    }

    /* Step over the configuration descriptor itself.  buf[0] is its bLength and
     * must be at least the fixed 9 bytes. */
    pos = (int)buf[0];
    if (pos < 9) {
        return USB_PARSE_ERR_BAD_LENGTH;
    }

    while (pos + 2 <= total) {
        int blen = (int)buf[pos];
        int btype = (int)buf[pos + 1];

        if (blen < 2) {
            return USB_PARSE_ERR_BAD_LENGTH;
        }
        if (pos + blen > total) {
            return USB_PARSE_ERR_TRUNCATED;
        }

        if (btype == (int)USB_DT_INTERFACE) {
            if (blen < 9) {
                return USB_PARSE_ERR_BAD_LENGTH;
            }
            cur_iface = buf[pos + 2];
            cur_is_hid = (buf[pos + 5] == (uint8_t)USB_CLASS_HID);
            if (out != 0) {
                out->interfaces_seen++;
                if (cur_is_hid) {
                    out->hid_interfaces_seen++;
                }
            }
            if (cur_is_hid) {
                saw_hid_interface = 1;
            }
        } else if (btype == (int)USB_DT_ENDPOINT) {
            if (blen < 7) {
                return USB_PARSE_ERR_BAD_LENGTH;
            }
            if (out != 0) {
                out->endpoints_seen++;
            }
            /* Only the FIRST interrupt IN endpoint on the HID interface is
             * wanted; later ones are ignored, not an error. */
            if (cur_is_hid && !found) {
                uint8_t addr = buf[pos + 2];
                uint8_t attr = buf[pos + 3];
                int is_in    = ((addr & 0x80u) != 0u);
                int is_intr  = ((attr & 0x03u) == (uint8_t)USB_XFER_INTERRUPT);
                if (is_in && is_intr) {
                    found = 1;
                    if (out != 0) {
                        out->hid_interface   = cur_iface;
                        out->ep_address      = addr;
                        out->max_packet_size = (uint16_t)buf[pos + 4] |
                                               ((uint16_t)buf[pos + 5] << 8);
                        out->interval        = buf[pos + 6];
                    }
                }
            }
        } else if (btype == (int)USB_DT_HID) {
            /* The HID descriptor lives inside a HID interface and carries the
             * report descriptor length at offset 7 (wDescriptorLength). */
            if (cur_is_hid && blen >= 9 && out != 0) {
                out->report_desc_len   = (uint16_t)buf[pos + 7] |
                                         ((uint16_t)buf[pos + 8] << 8);
                out->report_desc_iface = cur_iface;
            }
        }

        pos += blen;
    }

    if (!saw_hid_interface) {
        return USB_PARSE_ERR_NO_HID;
    }
    if (!found) {
        return USB_PARSE_ERR_NO_INT_IN;
    }
    return USB_PARSE_OK;
}

const char *usb_parse_strerror(int rc)
{
    switch (rc) {
    case USB_PARSE_OK:              return "ok";
    case USB_PARSE_ERR_TOO_SHORT:   return "buffer too short for a configuration descriptor";
    case USB_PARSE_ERR_NOT_CONFIG:  return "first descriptor is not CONFIGURATION";
    case USB_PARSE_ERR_BAD_LENGTH:  return "descriptor bLength is zero or below its fixed size";
    case USB_PARSE_ERR_TRUNCATED:   return "descriptor runs past wTotalLength";
    case USB_PARSE_ERR_NO_HID:      return "no HID interface (bInterfaceClass == 3)";
    case USB_PARSE_ERR_NO_INT_IN:   return "HID interface has no interrupt IN endpoint";
    default:                        return "unknown parse error";
    }
}

/* ------------------------------------------------------------------------- */
/* HID report descriptor walk                                                 */
/* ------------------------------------------------------------------------- */

/* A local-usage list only needs to survive until the next Main item, and the
 * descriptors that matter here have a handful of usages per Input, so a fixed
 * array is enough and keeps this file allocation-free. */
#define HID_MAX_PENDING_USAGES 64

int hid_parse_report_descriptor(const uint8_t *buf, int len, hid_report_info_t *out)
{
    int pos = 0;
    uint32_t pending[HID_MAX_PENDING_USAGES];
    int npending = 0;
    uint32_t usage_page = 0;
    long report_count = 0;
    long report_size = 0;
    long bits = 0;

    if (out != 0) {
        memset(out, 0, sizeof(*out));
    }
    if (buf == 0 || len <= 0) {
        return HID_PARSE_ERR_TOO_SHORT;
    }

    while (pos < len) {
        uint8_t prefix = buf[pos];
        int bsize = (int)(prefix & 0x03u);
        int btype = (int)((prefix >> 2) & 0x03u);
        int btag  = (int)((prefix >> 4) & 0x0Fu);
        int dlen  = (bsize == 3) ? 4 : bsize;
        uint32_t data = 0;
        int i;

        if (pos + 1 + dlen > len) {
            return HID_PARSE_ERR_TRUNCATED;
        }
        for (i = 0; i < dlen; i++) {
            data |= (uint32_t)buf[pos + 1 + i] << (8 * i);
        }

        if (btype == 1) {
            /* Global item */
            switch (btag) {
            case 0x0:  /* Usage Page */
                usage_page = data;
                if (out != 0) { out->usage_page_seen++; }
                break;
            case 0x7:  /* Report Size (bits) */
                report_size = (long)data;
                break;
            case 0x8:  /* Report ID */
                if (out != 0) { out->report_id_seen = 1; }
                break;
            case 0x9:  /* Report Count */
                report_count = (long)data;
                if (out != 0) { out->report_count_seen++; }
                break;
            default:
                break;
            }
        } else if (btype == 2) {
            /* Local item.  Usage (0x0), Usage Minimum (0x1) and Usage Maximum
             * (0x2) all name usages on the current page; a button range is
             * normally written as a Usage Minimum/Maximum pair, so all three
             * are collected or a button array is invisible.  The page qualifies
             * the usage, so the fully-qualified 32-bit value is built here. */
            if (btag == 0x0 || btag == 0x1 || btag == 0x2) {
                uint32_t full = (usage_page << 16) | (data & 0xFFFFu);
                if (npending < HID_MAX_PENDING_USAGES) {
                    pending[npending++] = full;
                }
            }
        } else if (btype == 0) {
            /* Main item.  Scan the local usages that have accumulated since the
             * last Main item for the two facts this project needs: is there a
             * Button page (0x09), and is there a Generic Desktop Game Pad or
             * Joystick usage.  Both Collection and Input are scanned, because a
             * gamepad's Game Pad usage is on the Collection and its button
             * range is on the Input. */
            for (i = 0; i < npending; i++) {
                uint32_t page = pending[i] >> 16;
                uint32_t usage = pending[i] & 0xFFFFu;
                if (out != 0) {
                    if (page == 0x09u) {
                        out->button_page_seen = 1;
                    } else if (page == 0x01u) {
                        out->generic_desktop_seen = 1;
                        if ((usage == 0x04u) || (usage == 0x05u)) {
                            out->gamepad_usage_seen = 1;
                        }
                        if ((usage == 0x02u) || (usage == 0x06u)) {
                            out->mouse_or_keyboard_seen = 1;
                        }
                    }
                }
            }

            if (btag == 0x8) {
                /* Input: this project only totals the input report size. */
                if (out != 0) { out->input_items_seen++; }
                bits += report_count * report_size;
                /* Belt and braces: a Button-page input with no explicit usage
                 * is still button data. */
                if (usage_page == 0x09u && out != 0) {
                    out->button_page_seen = 1;
                }
            }

            /* Every Main item consumes the local items (HID 1.11 6.2.2.8). */
            npending = 0;
            if (btag == 0xA) {   /* Collection: reset the report state too */
                report_count = 0;
                report_size = 0;
            }
        }

        pos += 1 + dlen;
    }

    if (out != 0) {
        out->report_bytes = (int)((bits + 7) / 8) + (out->report_id_seen ? 1 : 0);
        /* A device looks like a gamepad if it declares the Generic Desktop Game
         * Pad (0x05) or Joystick (0x04) usage, or carries a Button page and is
         * not a mouse/keyboard.  A mouse has a Button page too, which is why
         * mouse_or_keyboard_seen exists. */
        out->is_gamepad = (out->gamepad_usage_seen ||
                           (out->button_page_seen && !out->mouse_or_keyboard_seen))
                          ? 1 : 0;
    }

    return HID_PARSE_OK;
}

const char *hid_parse_strerror(int rc)
{
    switch (rc) {
    case HID_PARSE_OK:            return "ok";
    case HID_PARSE_ERR_TOO_SHORT: return "report descriptor is empty";
    case HID_PARSE_ERR_TRUNCATED: return "report descriptor item runs past the end";
    default:                      return "unknown report-descriptor error";
    }
}

/* ------------------------------------------------------------------------- */
/* report -> NES buttons                                                      */
/* ------------------------------------------------------------------------- */

uint8_t nes_buttons_from_report(const uint8_t *report, int report_len, int report_bytes)
{
    uint8_t b = 0;
    int usable;

    if (report == 0) {
        return 0;
    }

    /* Never read past either the caller's buffer or the report size the HID
     * descriptor implied. */
    usable = report_len;
    if (report_bytes < usable) {
        usable = report_bytes;
    }

    if (usable >= 1) {
        if ((report[0] & 0x01u) != 0u) { b |= NES_BTN_A; }
        if ((report[0] & 0x02u) != 0u) { b |= NES_BTN_B; }
    }
    if (usable >= 2) {
        if ((report[1] & 0x01u) != 0u) { b |= NES_BTN_SELECT; }
        if ((report[1] & 0x02u) != 0u) { b |= NES_BTN_START; }
        if ((report[1] & 0x10u) != 0u) { b |= NES_BTN_UP; }
        if ((report[1] & 0x20u) != 0u) { b |= NES_BTN_DOWN; }
        if ((report[1] & 0x40u) != 0u) { b |= NES_BTN_LEFT; }
        if ((report[1] & 0x80u) != 0u) { b |= NES_BTN_RIGHT; }
    }

    return b;
}
