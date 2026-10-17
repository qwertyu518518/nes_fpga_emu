/*
 * usb_gamepad.c -- USB HID gamepad on USB0 in host mode (the hardware half).
 *
 * Read the header of usb_gamepad.h first: none of this is testable here.  What
 * this file is careful about is the two things that ARE testable by inspection:
 *
 *   1. the descriptor bytes it produces are handed to the host-tested parser
 *      (usb_parse_config_descriptor / hid_parse_report_descriptor), so the only
 *      device-shaped logic lives in usb_hid.c and is asserted on the host; and
 *   2. every stage returns a DISTINCT usbgp_status_t, so the caller names the
 *      failing stage instead of stalling silently.
 *
 * WHAT USES THE DRIVER
 *   The BSP `xusbps` driver (D:\Vivado .../libsrc/usbps_v2_4) for controller
 *   init, the endpoint DMA/queue-head memory (XUsbPs_ConfigureDevice) and the
 *   control/interrupt transfers on EP0 and the HID interrupt endpoint.
 *
 * WHAT POKES REGISTERS DIRECTLY, AND WHY
 *   This xusbps version is a DEVICE-mode driver: it has XUsbPs_ConfigureDevice
 *   for the device role and no XUsbPs_ConfigureHost.  Its queue heads carry no
 *   device-address field, and XUsbPs_SetDeviceAddress() writes register 0x154,
 *   which in host mode is the periodic-frame-list base -- calling it in host
 *   mode is wrong.  So host mode is entered by writing the USB mode register
 *   and the root-port control/status register directly, exactly as the hardware
 *   requires, and the control transfers ride on the driver's EP0 buffers.  This
 *   is the part a board would have to confirm; see the "USB gamepad" section of
 *   tools/ps/README.md.
 */

#include <string.h>

#include "xparameters.h"
#include "xusbps.h"
#include "xusbps_hw.h"
#include "xil_cache.h"
#include "sleep.h"

#include "usb_hid.h"
#include "usb_gamepad.h"

#define USBGP_DEVICE_ID        XPAR_XUSBPS_0_DEVICE_ID
#define USBGP_DEVICE_ADDRESS   1u

/* wValue high byte carries the descriptor type for GET_DESCRIPTOR. */
#define USB_REQ_GET_DESCRIPTOR   0x06u
#define USB_REQ_SET_ADDRESS      0x05u
#define USB_REQ_SET_CONFIG       0x09u
#define USB_REQ_SET_IDLE         0x0Au

#define USB_REQTYPE_IN_STANDARD   0x80u
#define USB_REQTYPE_OUT_STANDARD  0x00u
#define USB_REQTYPE_OUT_CLASS_IF  0x21u
#define USB_REQTYPE_IN_CLASS_IF   0x81u

#define USBGP_CONFIG_VALUE        1u
#define USBGP_REPORT_MAX          256
#define USBGP_CTRL_TIMEOUT        100000
#define USBGP_CONNECT_TIMEOUT     200      /* 200 * 10 ms = 2 s              */

/* Controller-facing DMA/QH memory.  XUSBPS_dQH_BASE_ALIGN is 2048. */
#define USBGP_DMA_MEM_SIZE        16384
static u8 usbgp_dma_mem[USBGP_DMA_MEM_SIZE] __attribute__((aligned(XUSBPS_dQH_BASE_ALIGN)));

static XUsbPs             g_usb;
static usb_gamepad_info_t g_info;

const char *usbgp_strerror(int status)
{
    switch (status) {
    case USBGP_OK:                    return "ok";
    case USBGP_ERR_LOOKUP:            return "controller lookup failed";
    case USBGP_ERR_CFG_INIT:          return "controller init failed";
    case USBGP_ERR_DEV_CONFIG:        return "controller endpoint/DMA config failed";
    case USBGP_ERR_NO_DEVICE:         return "no device attached (port reset failed)";
    case USBGP_ERR_DEV_DESCRIPTOR:    return "device descriptor malformed";
    case USBGP_ERR_SET_ADDRESS:       return "SET_ADDRESS failed";
    case USBGP_ERR_CONFIG_DESCRIPTOR: return "configuration descriptor malformed";
    case USBGP_ERR_NO_HID:            return "no HID interface in the configuration";
    case USBGP_ERR_NO_INT_IN:         return "HID interface has no interrupt IN endpoint";
    case USBGP_ERR_SET_CONFIG:        return "SET_CONFIGURATION failed";
    case USBGP_ERR_SET_IDLE:          return "SET_IDLE failed";
    case USBGP_ERR_POLL:              return "interrupt endpoint poll failed";
    case USBGP_ERR_REPORT_DESCRIPTOR: return "HID report descriptor failed/malformed";
    case USBGP_ERR_NOT_GAMEPAD:       return "report descriptor is not a gamepad";
    default:                          return "unknown USB gamepad error";
    }
}

/* ------------------------------------------------------------------ control
 *
 * One USB control transfer.  The setup packet goes out on EP0; the data stage
 * is a receive (device -> host) or a send (host -> device); the status stage is
 * the opposite-direction zero-length packet the controller raises itself.
 * Returns USBGP_OK or USBGP_ERR_SET_ADDRESS/a transfer error.
 */
static int usbgp_ctrl(uint8_t bmRequestType, uint8_t bRequest,
                      uint16_t wValue, uint16_t wIndex,
                      uint8_t *data, uint16_t wLength)
{
    uint8_t setup[8];
    int timeout;

    setup[0] = bmRequestType;
    setup[1] = bRequest;
    setup[2] = (uint8_t)(wValue & 0xFFu);
    setup[3] = (uint8_t)((wValue >> 8) & 0xFFu);
    setup[4] = (uint8_t)(wIndex & 0xFFu);
    setup[5] = (uint8_t)((wIndex >> 8) & 0xFFu);
    setup[6] = (uint8_t)(wLength & 0xFFu);
    setup[7] = (uint8_t)((wLength >> 8) & 0xFFu);

    Xil_DCacheFlushRange((u32)setup, sizeof(setup));
    if (XUsbPs_EpBufferSend(&g_usb, 0, setup, 8) != XST_SUCCESS) {
        return USBGP_ERR_DEV_DESCRIPTOR;
    }

    if (wLength != 0u) {
        if ((bmRequestType & 0x80u) != 0u) {
            u32 done = 0u;
            timeout = 0;
            while (done < wLength) {
                u8 *rx_buf = 0;
                u32 rx_len = 0u;
                u32 handle = 0u;
                if (XUsbPs_EpBufferReceive(&g_usb, 0, &rx_buf, &rx_len, &handle) == XST_SUCCESS) {
                    u32 need = (u32)wLength - done;
                    u32 take = (rx_len < need) ? rx_len : need;
                    memcpy(data + done, rx_buf, take);
                    XUsbPs_EpBufferRelease(handle);
                    done += take;
                    timeout = 0;
                    if (take < 64u) { break; }      /* short packet ends it */
                } else if (++timeout > USBGP_CTRL_TIMEOUT) {
                    return USBGP_ERR_CONFIG_DESCRIPTOR;
                }
            }
        } else {
            Xil_DCacheFlushRange((u32)data, wLength);
            if (XUsbPs_EpBufferSend(&g_usb, 0, data, wLength) != XST_SUCCESS) {
                return USBGP_ERR_CONFIG_DESCRIPTOR;
            }
        }
    }
    return USBGP_OK;
}

/* ------------------------------------------------------------------- init */

int usb_gamepad_init(void)
{
    XUsbPs_Config        *cfg;
    XUsbPs_DeviceConfig   devcfg;
    u32 base;

    cfg = XUsbPs_LookupConfig((u16)USBGP_DEVICE_ID);
    if (cfg == 0) {
        return USBGP_ERR_LOOKUP;
    }
    if (XUsbPs_CfgInitialize(&g_usb, cfg, cfg->BaseAddress) != XST_SUCCESS) {
        return USBGP_ERR_CFG_INIT;
    }

    /* EP0 only: this driver instance is used for control transfers, the HID
     * interrupt endpoint is enabled later through the same driver. */
    memset(&devcfg, 0, sizeof(devcfg));
    devcfg.EpCfg[0].Out.Type          = XUSBPS_EP_TYPE_CONTROL;
    devcfg.EpCfg[0].Out.NumBufs       = 2;
    devcfg.EpCfg[0].Out.BufSize       = 64;
    devcfg.EpCfg[0].Out.MaxPacketSize = 64;
    devcfg.EpCfg[0].In.Type           = XUSBPS_EP_TYPE_CONTROL;
    devcfg.EpCfg[0].In.NumBufs        = 2;
    devcfg.EpCfg[0].In.MaxPacketSize  = 64;
    devcfg.NumEndpoints = 1;

    memset(usbgp_dma_mem, 0, sizeof(usbgp_dma_mem));
    Xil_DCacheFlushRange((u32)usbgp_dma_mem, sizeof(usbgp_dma_mem));
    devcfg.DMAMemPhys = (u32)usbgp_dma_mem;

    if (XUsbPs_ConfigureDevice(&g_usb, &devcfg) != XST_SUCCESS) {
        return USBGP_ERR_DEV_CONFIG;
    }

    base = g_usb.Config.BaseAddress;

    /* XUsbPs_ConfigureDevice leaves the controller in DEVICE mode; this is the
     * switch to HOST (XUSBPS_MODE_CM_HOST_MASK == 0x3). */
    XUsbPs_WriteReg(base, XUSBPS_MODE_OFFSET, XUSBPS_MODE_CM_HOST_MASK);

    /* Power the root port (the 4 Type-A ports only carry VBUS in host mode). */
    XUsbPs_SetBits(&g_usb, XUSBPS_PORTSCR1_OFFSET, XUSBPS_PORTSCR_PP_MASK);
    usleep(20000);

    XUsbPs_Start(&g_usb);
    usleep(20000);

    memset(&g_info, 0, sizeof(g_info));
    return USBGP_OK;
}

static int usbgp_wait_connect(void)
{
    int i;
    for (i = 0; i < USBGP_CONNECT_TIMEOUT; i++) {
        u32 scr = XUsbPs_ReadReg(g_usb.Config.BaseAddress, XUSBPS_PORTSCR1_OFFSET);
        if ((scr & XUSBPS_PORTSCR_CCS_MASK) != 0u) {
            return USBGP_OK;
        }
        usleep(10000);
    }
    return USBGP_ERR_NO_DEVICE;
}

static int usbgp_bus_reset(void)
{
    int i;
    u32 base = g_usb.Config.BaseAddress;

    XUsbPs_SetBits(&g_usb, XUSBPS_PORTSCR1_OFFSET, XUSBPS_PORTSCR_PR_MASK);
    usleep(50000);
    XUsbPs_ClrBits(&g_usb, XUSBPS_PORTSCR1_OFFSET, XUSBPS_PORTSCR_PR_MASK);
    usleep(20000);

    /* A 10 ms reset must leave the port enabled (PE set). */
    for (i = 0; i < USBGP_CONNECT_TIMEOUT; i++) {
        u32 scr = XUsbPs_ReadReg(base, XUSBPS_PORTSCR1_OFFSET);
        if ((scr & XUSBPS_PORTSCR_PE_MASK) != 0u) {
            return USBGP_OK;
        }
        usleep(10000);
    }
    return USBGP_ERR_NO_DEVICE;
}

/* ---------------------------------------------------------------- enumerate */

int usb_gamepad_enumerate(void)
{
    uint8_t  dev_desc[18];
    uint8_t  cfg_head[9];
    uint8_t  cfg_buf[256];
    uint8_t  report[USBGP_REPORT_MAX];
    int      rc;
    int      cfg_total;
    usb_hid_loc_t loc;
    hid_report_info_t rinfo;

    if (usbgp_wait_connect() != USBGP_OK) {
        return USBGP_ERR_NO_DEVICE;
    }
    if (usbgp_bus_reset() != USBGP_OK) {
        return USBGP_ERR_NO_DEVICE;
    }

    /* GET_DESCRIPTOR(DEVICE), first 8 bytes are always safe at any EP0 size. */
    memset(dev_desc, 0, sizeof(dev_desc));
    rc = usbgp_ctrl(USB_REQTYPE_IN_STANDARD, USB_REQ_GET_DESCRIPTOR,
                    0x0100u, 0u, dev_desc, 18u);
    if (rc != USBGP_OK || dev_desc[0] < 8u || dev_desc[1] != (uint8_t)USB_DT_DEVICE) {
        return USBGP_ERR_DEV_DESCRIPTOR;
    }

    /* SET_ADDRESS moves the device off address 0. */
    rc = usbgp_ctrl(USB_REQTYPE_OUT_STANDARD, USB_REQ_SET_ADDRESS,
                    (uint16_t)USBGP_DEVICE_ADDRESS, 0u, 0, 0u);
    if (rc != USBGP_OK) {
        return USBGP_ERR_SET_ADDRESS;
    }
    usleep(5000);

    /* GET_DESCRIPTOR(CONFIGURATION), header first for wTotalLength. */
    rc = usbgp_ctrl(USB_REQTYPE_IN_STANDARD, USB_REQ_GET_DESCRIPTOR,
                    0x0200u, 0u, cfg_head, 9u);
    if (rc != USBGP_OK || cfg_head[1] != (uint8_t)USB_DT_CONFIG) {
        return USBGP_ERR_CONFIG_DESCRIPTOR;
    }
    cfg_total = (int)cfg_head[2] | ((int)cfg_head[3] << 8);
    if (cfg_total < 9 || cfg_total > (int)sizeof(cfg_buf)) {
        return USBGP_ERR_CONFIG_DESCRIPTOR;
    }

    memset(cfg_buf, 0, sizeof(cfg_buf));
    rc = usbgp_ctrl(USB_REQTYPE_IN_STANDARD, USB_REQ_GET_DESCRIPTOR,
                    0x0200u, 0u, cfg_buf, (uint16_t)cfg_total);
    if (rc != USBGP_OK) {
        return USBGP_ERR_CONFIG_DESCRIPTOR;
    }

    /* The DEVICE-SHAPED decision is made by the host-tested parser. */
    memset(&loc, 0, sizeof(loc));
    rc = usb_parse_config_descriptor(cfg_buf, cfg_total, &loc);
    if (rc == USB_PARSE_ERR_NO_HID) {
        return USBGP_ERR_NO_HID;
    }
    if (rc == USB_PARSE_ERR_NO_INT_IN) {
        return USBGP_ERR_NO_INT_IN;
    }
    if (rc != USB_PARSE_OK) {
        return USBGP_ERR_CONFIG_DESCRIPTOR;
    }

    /* GET_DESCRIPTOR(HID REPORT) for the HID interface. */
    if (loc.report_desc_len == 0u) {
        return USBGP_ERR_REPORT_DESCRIPTOR;
    }
    {
        uint16_t want = loc.report_desc_len;
        if (want > (uint16_t)USBGP_REPORT_MAX) {
            want = (uint16_t)USBGP_REPORT_MAX;
        }
        memset(report, 0, sizeof(report));
        rc = usbgp_ctrl(USB_REQTYPE_IN_CLASS_IF, USB_REQ_GET_DESCRIPTOR,
                        (uint16_t)((uint16_t)USB_DT_REPORT << 8) | loc.hid_interface,
                        loc.hid_interface, report, want);
        if (rc != USBGP_OK) {
            return USBGP_ERR_REPORT_DESCRIPTOR;
        }
        memset(&rinfo, 0, sizeof(rinfo));
        rc = hid_parse_report_descriptor(report, (int)want, &rinfo);
        if (rc != HID_PARSE_OK) {
            return USBGP_ERR_REPORT_DESCRIPTOR;
        }
        if (!rinfo.is_gamepad) {
            return USBGP_ERR_NOT_GAMEPAD;
        }
    }

    /* SET_CONFIGURATION(config 1). */
    rc = usbgp_ctrl(USB_REQTYPE_OUT_STANDARD, USB_REQ_SET_CONFIG,
                    (uint16_t)USBGP_CONFIG_VALUE, 0u, 0, 0u);
    if (rc != USBGP_OK) {
        return USBGP_ERR_SET_CONFIG;
    }

    /* SET_IDLE(0) so the device reports on change rather than only on SOF. */
    rc = usbgp_ctrl(USB_REQTYPE_OUT_CLASS_IF, USB_REQ_SET_IDLE,
                    0x0000u, loc.hid_interface, 0, 0u);
    if (rc != USBGP_OK) {
        return USBGP_ERR_SET_IDLE;
    }

    /* Enable the interrupt IN endpoint and prime it for the first report. */
    XUsbPs_EpEnable(&g_usb, (loc.ep_address & 0x0Fu), XUSBPS_EP_DIRECTION_IN);

    g_info.hid_interface   = loc.hid_interface;
    g_info.ep_address      = loc.ep_address;
    g_info.max_packet_size = loc.max_packet_size;
    g_info.interval        = loc.interval;
    g_info.report_bytes    = (uint16_t)rinfo.report_bytes;
    g_info.report_id_seen  = rinfo.report_id_seen;
    g_info.is_gamepad      = rinfo.is_gamepad;
    g_info.interfaces_seen = loc.interfaces_seen;
    g_info.endpoints_seen  = loc.endpoints_seen;
    return USBGP_OK;
}

usb_gamepad_info_t usb_gamepad_info(void)
{
    return g_info;
}

/* ------------------------------------------------------------------- poll */

int usb_gamepad_poll(uint8_t *nes_buttons)
{
    u8 *rx_buf = 0;
    u32 rx_len = 0u;
    u32 handle = 0u;
    u8 ep = (u8)(g_info.ep_address & 0x0Fu);

    if (nes_buttons == 0) {
        return USBGP_ERR_POLL;
    }

    if (XUsbPs_EpBufferReceive(&g_usb, ep, &rx_buf, &rx_len, &handle) != XST_SUCCESS) {
        return USBGP_OK;   /* nothing arrived this poll; not an error */
    }

    /* report_id_seen is 0/1 and is exactly the leading byte count: 1 when the
     * report carries a Report ID, so the mapper starts after it and does not
     * read the ID byte as buttons. */
    *nes_buttons = nes_buttons_from_report(rx_buf, (int)rx_len,
                                           (int)g_info.report_bytes,
                                           g_info.report_id_seen);
    XUsbPs_EpBufferRelease(handle);
    return USBGP_OK;
}

void usb_gamepad_close(void)
{
    XUsbPs_Stop(&g_usb);
}
