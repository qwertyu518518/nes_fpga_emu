/*
 * main.c -- Zynq PS bare-metal cartridge loader for the NES FPGA emulator.
 *
 * WHAT IT DOES
 *   Reads an iNES cartridge image from the SD card, parses its 16-byte header,
 *   and streams the PRG and CHR bytes into the PL through the hand-written
 *   AXI4-Lite register bank at 0x4120_0000 (rtl/platform/zynq/axi_lite_regs.v,
 *   wired to the PS by tools/ps/build_ps.tcl).  The register bank holds the
 *   console in reset for the whole load and only the deliberate clear of
 *   LOAD_EN releases it, so a partially loaded image cannot be executed.
 *
 * THE PATH
 *   SD card -> FatFs (xilffs, SD0 on MIO 40..45) -> this app -> M_AXI_GP0 ->
 *   axi_protocol_converter -> axi_lite_regs -> (PRG_DATA/CHR_DATA writes) ->
 *   nes_cart_load_bridge -> the PRG and CHR arrays inside nes_zynq_top.
 *
 * REGISTER MAP (word addressed)
 *   0x00 CTRL      RW  bit0 LOAD_EN, bit1 HOLD (LOAD_EN implies HOLD)
 *   0x04 SCRATCH   RW  write/read-back proof
 *   0x08 STATUS    RO  {24'b0, pl_status_in[7:0]}
 *   0x0C ID        RO  0x4E455301
 *   0x10 PRG_ADDR  RW  byte address, auto-increments by 4 per data word
 *   0x14 PRG_DATA  WO  one word, byte lanes selected by WSTRB
 *   0x18 CHR_ADDR  RW  byte address, auto-increments by 4 per data word
 *   0x1C CHR_DATA  WO  one word, byte lanes selected by WSTRB
 *
 * FAILURE POLICY
 *   Each failure is reported distinctly over UART0 and the console is NOT
 *   released: link check failed, no card / unreadable filesystem, file not
 *   found, bad iNES header, short read.  Only a fully streamed image clears
 *   LOAD_EN.
 *
 * USB GAMEPAD (added after the loader is unchanged)
 *   When the console has been released this app brings USB0 up in host mode,
 *   enumerates one HID gamepad, and polls its interrupt IN endpoint, mapping
 *   each report to the NES button byte and writing it into the low byte of the
 *   existing SCRATCH register (0x04).  The loader runs FIRST and completes
 *   before any USB work starts, so nothing in the load path changes and the
 *   SCRATCH link check is never raced.  See usb_gamepad.c and the "USB gamepad"
 *   section of tools/ps/README.md.
 *
 *   NOTE ON THE REGISTER: the register bank is used to CARRY the buttons, but
 *   it does not yet deliver them to the controller -- nes_zynq_top.v feeds
 *   nes_system_v6.buttons1 from the touch panel only, and no AXI register
 *   reaches it.  Writing SCRATCH is real and read-back-verifiable, but a
 *   one-wire PL change (sample reg_scratch[7:0] into buttons1) is required
 *   before a button press can reach the NES.  That change is deliberately NOT
 *   made: this task must not edit rtl/.  See the finding in tools/ps/README.md.
 */

#include <string.h>

#include "xil_io.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "sleep.h"
#include "ff.h"

#include "usb_gamepad.h"

#define AXI_REG_BASE   0x41200000u
#define REG_CTRL       (AXI_REG_BASE + 0x00u)
#define REG_SCRATCH    (AXI_REG_BASE + 0x04u)
#define REG_STATUS     (AXI_REG_BASE + 0x08u)
#define REG_ID         (AXI_REG_BASE + 0x0Cu)
#define REG_PRG_ADDR   (AXI_REG_BASE + 0x10u)
#define REG_PRG_DATA   (AXI_REG_BASE + 0x14u)
#define REG_CHR_ADDR   (AXI_REG_BASE + 0x18u)
#define REG_CHR_DATA   (AXI_REG_BASE + 0x1Cu)

#define AXI_REG_ID_EXPECTED  0x4E455301u

#define CTRL_LOAD_EN   0x00000001u
#define CTRL_HOLD      0x00000002u

/* The cartridge is read from this path on the FAT filesystem.  It is a fixed
 * name so the bring-up is deterministic; renaming means editing this one line. */
#define CARTRIDGE_PATH "0:/game.nes"

/* The PRG array is up to 128 KiB (17-bit load address), the CHR array 8 KiB
 * (13-bit load address), matching nes_cart_rom.v and axi_lite_regs.v. */
#define PRG_MAX_BYTES  131072u
#define CHR_MAX_BYTES  8192u

#define CHUNK_BYTES    1024u

static FATFS g_fatfs;
static FIL   g_file;
static u8    g_chunk[CHUNK_BYTES];

static int link_check(void)
{
    u32 patterns[4] = { 0x00000000u, 0xFFFFFFFFu, 0xA5A55A5Au, 0x12345678u };
    u32 id;
    int i;

    for (i = 0; i < 4; i++) {
        Xil_Out32(REG_SCRATCH, patterns[i]);
        if (Xil_In32(REG_SCRATCH) != patterns[i]) {
            xil_printf("LINK: SCRATCH read-back mismatch (wrote 0x%08x, read 0x%08x)\r\n",
                       (unsigned)patterns[i], (unsigned)Xil_In32(REG_SCRATCH));
            return -1;
        }
    }
    xil_printf("LINK: SCRATCH round-trip OK\r\n");

    id = Xil_In32(REG_ID);
    if (id != AXI_REG_ID_EXPECTED) {
        xil_printf("LINK: ID read 0x%08x, expected 0x%08x -- not this slave\r\n",
                   (unsigned)id, (unsigned)AXI_REG_ID_EXPECTED);
        return -1;
    }
    xil_printf("LINK: ID = 0x%08x OK\r\n", (unsigned)id);
    return 0;
}

/* Stream n bytes at p into a data register whose address counterpart has been
 * set to the region start and auto-increments by 4 per word.  The word is packed
 * little-endian so byte 0 of the file lands in lane 0 (address + 0).  A trailing
 * group shorter than four bytes is zero-filled: this reg file cannot represent a
 * partial lane group as one strobed write (the CPU has no three-byte store and
 * the address increments by four per accepted word), and every iNES region size
 * is a multiple of 8192, so the path is defensive only. */
static void stream_bytes(const u8 *p, u32 n, u32 data_reg)
{
    while (n >= 4u) {
        u32 w = ((u32)p[0]) | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
        Xil_Out32(data_reg, w);
        p += 4;
        n -= 4u;
    }
    if (n != 0u) {
        u32 w = 0;
        u32 i;
        for (i = 0; i < n; i++) { w |= ((u32)p[i]) << (8u * i); }
        Xil_Out32(data_reg, w);
    }
}

/* Read exactly n bytes from the current file position.  Returns the number of
 * bytes actually read; the caller treats a value below n as a short read. */
static u32 read_region(u32 n, u32 data_reg)
{
    u32 total = 0;
    UINT br = 0;
    FRESULT fr;

    while (total < n) {
        u32 want = n - total;
        if (want > CHUNK_BYTES) { want = CHUNK_BYTES; }
        fr = f_read(&g_file, g_chunk, want, &br);
        if (fr != FR_OK) {
            xil_printf("READ: f_read failed, FRESULT=%d\r\n", (int)fr);
            return total;
        }
        if (br == 0u) { break; }
        stream_bytes(g_chunk, (u32)br, data_reg);
        total += (u32)br;
    }
    return total;
}

/* Bring up the USB gamepad and then poll it forever, writing the mapped NES
 * button byte into SCRATCH[7:0].  Called only after the console has been
 * released, so the loader has already finished and SCRATCH is free.  Every
 * failure below prints a stage name; there is no silent stall. */
static void run_gamepad(void)
{
    int st;
    u8 buttons = 0;
    u8 prev = 0xFFu;   /* differs from any real report, so the first write lands */

    xil_printf("\r\nUSB: bringing USB0 up in host mode\r\n");
    st = usb_gamepad_init();
    if (st != USBGP_OK) {
        xil_printf("RESULT: FAIL (USB controller init: %s)\r\n", usbgp_strerror(st));
        for (;;) { }
    }
    xil_printf("USB: controller up (host mode, root port powered)\r\n");

    for (;;) {
        st = usb_gamepad_enumerate();
        if (st == USBGP_OK) { break; }
        xil_printf("USB: enumerate failed: %s\r\n", usbgp_strerror(st));
        usleep(1000000);   /* retry; a pad can be plugged in later */
    }

    {
        usb_gamepad_info_t info = usb_gamepad_info();
        xil_printf("USB: enumerated -- HID interface %u, interrupt IN EP 0x%02x, "
                   "wMaxPacketSize %u, bInterval %u, report %u B, gamepad %d\r\n",
                   (unsigned)info.hid_interface, (unsigned)info.ep_address,
                   (unsigned)info.max_packet_size, (unsigned)info.interval,
                   (unsigned)info.report_bytes, info.is_gamepad);
    }
    xil_printf("PAD: polling; buttons -> SCRATCH[7:0] @ 0x%08x\r\n",
               (unsigned)REG_SCRATCH);

    for (;;) {
        st = usb_gamepad_poll(&buttons);
        if (st != USBGP_OK) {
            xil_printf("PAD: poll error: %s -- re-enumerating\r\n", usbgp_strerror(st));
            (void)usb_gamepad_enumerate();
            prev = 0xFFu;
            continue;
        }
        if (buttons != prev) {
            Xil_Out32(REG_SCRATCH, (u32)buttons);
            prev = buttons;
        }
    }
}

int main(void)
{
    FRESULT fr;
    u8 header[16];
    UINT br = 0;
    u32 prg_len;
    u32 chr_len;
    u32 trainer_len;
    u32 got;
    u8 flags6;
    u8 flags7;
    u8 prg_banks;
    u8 chr_banks;

    xil_printf("\r\n=== op_fpga_emu PS cartridge loader ===\r\n");
    xil_printf("AXI register bank @ 0x%08x\r\n", (unsigned)AXI_REG_BASE);

    /* ---- 1. Prove the PS<->PL link before trusting anything downstream. ---- */
    if (link_check() != 0) {
        xil_printf("RESULT: FAIL (PL link check) -- console left on the baked image\r\n");
        for (;;) { }
    }

    /* ---- 2. Bring up the card through FatFs (initialises the SD controller). */
    fr = f_mount(&g_fatfs, "0:/", 1);
    if (fr != FR_OK) {
        xil_printf("RESULT: FAIL (no card or unreadable filesystem), f_mount FRESULT=%d\r\n", (int)fr);
        for (;;) { }
    }
    xil_printf("SD: filesystem mounted\r\n");

    fr = f_open(&g_file, CARTRIDGE_PATH, FA_READ);
    if (fr != FR_OK) {
        xil_printf("RESULT: FAIL (file not found / unreadable: %s), f_open FRESULT=%d\r\n",
                   CARTRIDGE_PATH, (int)fr);
        for (;;) { }
    }
    xil_printf("SD: opened %s (%u bytes)\r\n", CARTRIDGE_PATH, (unsigned)f_size(&g_file));

    /* ---- 3. Parse the iNES header. ---------------------------------------- */
    fr = f_read(&g_file, header, 16u, &br);
    if ((fr != FR_OK) || (br != 16u)) {
        xil_printf("RESULT: FAIL (short read on iNES header: %u bytes)\r\n", (unsigned)br);
        for (;;) { }
    }
    if (!((header[0] == 0x4Eu) && (header[1] == 0x45u) &&
          (header[2] == 0x53u) && (header[3] == 0x1Au))) {
        xil_printf("RESULT: FAIL (bad iNES magic %02x %02x %02x %02x)\r\n",
                   header[0], header[1], header[2], header[3]);
        for (;;) { }
    }

    prg_banks  = header[4];
    chr_banks  = header[5];
    flags6     = header[6];
    flags7     = header[7];
    trainer_len = ((flags6 & 0x04u) != 0u) ? 512u : 0u;
    prg_len = ((u32)prg_banks) * 16384u;
    chr_len = ((u32)chr_banks) * 8192u;

    xil_printf("INES: PRG %u x 16KiB = %u B, CHR %u x 8KiB = %u B, trainer %u, f6=0x%02x f7=0x%02x\r\n",
               prg_banks, (unsigned)prg_len, chr_banks, (unsigned)chr_len,
               (unsigned)trainer_len, flags6, flags7);

    if (prg_len == 0u) {
        xil_printf("RESULT: FAIL (header declares no PRG ROM)\r\n");
        for (;;) { }
    }
    if (prg_len > PRG_MAX_BYTES) {
        xil_printf("RESULT: FAIL (PRG %u B exceeds the %u B array)\r\n",
                   (unsigned)prg_len, (unsigned)PRG_MAX_BYTES);
        for (;;) { }
    }
    if (chr_len > CHR_MAX_BYTES) {
        xil_printf("NOTE: CHR %u B exceeds the %u B array; the top %u B fold away\r\n",
                   (unsigned)chr_len, (unsigned)CHR_MAX_BYTES,
                   (unsigned)(chr_len - CHR_MAX_BYTES));
        chr_len = CHR_MAX_BYTES;
    }

    /* Skip a trainer if present; it is cartridge RAM, not ROM. */
    if (trainer_len != 0u) {
        fr = f_lseek(&g_file, f_tell(&g_file) + trainer_len);
        if (fr != FR_OK) {
            xil_printf("RESULT: FAIL (cannot skip trainer), f_lseek FRESULT=%d\r\n", (int)fr);
            for (;;) { }
        }
    }

    /* ---- 4. Hold the console and stream the image. --------------------------
     * LOAD_EN implies HOLD: asserting it holds the CPU and PPU for the whole
     * load.  It is left asserted on every failure below, so a partial image is
     * never released. */
    Xil_Out32(REG_PRG_ADDR, 0u);
    Xil_Out32(REG_CHR_ADDR, 0u);
    Xil_Out32(REG_CTRL, CTRL_LOAD_EN);
    xil_printf("LOAD: console held (CTRL=LOAD_EN)\r\n");

    got = read_region(prg_len, REG_PRG_DATA);
    if (got != prg_len) {
        xil_printf("RESULT: FAIL (short read on PRG: got %u of %u bytes)\r\n",
                   (unsigned)got, (unsigned)prg_len);
        for (;;) { }
    }
    xil_printf("LOAD: PRG %u bytes streamed\r\n", (unsigned)got);

    got = read_region(chr_len, REG_CHR_DATA);
    if (got != chr_len) {
        xil_printf("RESULT: FAIL (short read on CHR: got %u of %u bytes)\r\n",
                   (unsigned)got, (unsigned)chr_len);
        for (;;) { }
    }
    xil_printf("LOAD: CHR %u bytes streamed\r\n", (unsigned)got);

    /* ---- 5. The image is complete: release the console. -------------------- */
    Xil_Out32(REG_CTRL, 0u);
    xil_printf("LOAD: console released (CTRL=0)\r\n");

    f_close(&g_file);
    xil_printf("RESULT: PASS (cartridge loaded, console running)\r\n");

    /* The loader is done and the console is running; now the gamepad. */
    run_gamepad();

    for (;;) { }
    return 0;
}
