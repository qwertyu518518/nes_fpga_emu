# PS-driven cartridge loading (`axi_lite_regs` + `nes_cart_load_bridge` + `nes_cart_rom` load port)

This is the PL half of "load the cartridge from the TF card at runtime instead of
baking it into the bitstream". The PS software half (block design, FSBL, bare-metal
app, BOOT.bin) is a separate task; this half is small, self-contained RTL and it is
verifiable entirely in simulation, so it carries its own gate targets.

## What is here

| File | Role |
| --- | --- |
| `rtl/platform/zynq/axi_lite_regs.v` | hand-written AXI4-Lite slave; the PS register bank and the source of cartridge-load requests |
| `rtl/nes_core/cart/nes_cart_load_bridge.v` | carries one load byte from the AXI/PS clock domain into the core clock domain |
| `rtl/nes_core/cart/nes_cart_rom.v` | gains an inert-by-default load port on both arrays |
| `rtl/nes_core/system/nes_system_v6.v` | forwards the PRG load port to its internal `nes_cart_rom` (CHR is a board-level instance) |

The AXI slave was written from the ARM AMBA AXI4-Lite specification; it is not
adapted from any vendor source file. A Xilinx `axi_protocol_converter` (AXI3 to
AXI4-Lite) is still required in front of it because the PS `M_AXI_GP0` is AXI3, but
that is a primitive instantiated in the block design, not vendor reference code.

## Register map

Base address 0x4120_0000, 32-bit words, offset = `addr[4:2]`.

| Offset | Register | Access | Meaning |
| --- | --- | --- | --- |
| 0x00 | CTRL | RW | bit0 LOAD_EN, bit1 HOLD |
| 0x04 | SCRATCH | RW | free scratch; read back to prove the link |
| 0x08 | STATUS | RO | `{24'b0, pl_status_in[7:0]}` |
| 0x0C | ID | RO | 0x4E455301 |
| 0x10 | PRG_ADDR | RW | byte address into PRG; auto-increments by 4 per data word |
| 0x14 | PRG_DATA | WO | one word of PRG bytes, WSTRB per lane |
| 0x18 | CHR_ADDR | RW | byte address into CHR |
| 0x1C | CHR_DATA | WO | one word of CHR bytes, WSTRB per lane |

## The load path, and why the arrays stay byte-wide

The cartridge arrays are 8 bits wide. A 32-bit load port into a byte-wide block RAM
is not a shape the primitive can take, so one `PRG_DATA`/`CHR_DATA` write is
expanded in `axi_lite_regs` into up to four byte writes, one per set WSTRB lane, one
byte per core clock, each handed across the clock domain by the bridge. Lane k
writes array address `(ADDR + k)`; `ADDR` advances by 4 when the last strobed byte
has been accepted. A full word streams four bytes per AXI transaction.

The hand-off is a valid/ready handshake: `PRG_DATA` is not acknowledged with BVALID
until every strobed byte has been accepted, and `awready`/`wready` are held low while
a word is in flight, so the single-outstanding write can never outrun the load.

## Inert unless enabled, and why a partial image cannot run

`ctrl[0]` (LOAD_EN) gates the load three times: the slave only turns a load-data
write into a request when LOAD_EN is set; the bridge only forwards while the
synchronised enable is high; and the cartridge only writes while its load enable is
high. With LOAD_EN clear a `PRG_DATA`/`CHR_DATA` write is acknowledged and dropped --
nothing reaches either array. Every pre-existing instance leaves the load ports
unconnected, and an unconnected input is `z`, which the load gate reads as "not
selected", so the 69-target gate passes with the RTL unmodified.

`pl_console_hold = ctrl[1] | ctrl[0]`: LOAD_EN implies HOLD, so the same bit that
lets bytes reach the arrays also holds the CPU and PPU in reset for the whole load.
The only way to release the console is to clear LOAD_EN, which can only be a
deliberate "image complete" write. A partially-loaded image therefore cannot be
executed by construction, because execution requires the very bit whose presence
permits writes.

## The clock crossing

The AXI slave runs on the PS `FCLK_CLK0` (50 MHz); the arrays run on
`mmcm_core_clk` (21.477272727 MHz). `nes_cart_load_bridge` is the crossing: a
bundled-data toggle handshake. The host latches target/address/data and flips a
request toggle; the core side synchronises the toggle, presents one byte to the
cartridge, and echoes an acknowledge toggle. The bundle is stable from the request
edge until the echo returns, so the core always samples stable data. This is the
safe way to cross a multi-bit load into a RAM write; a raw per-bit crossing is what
the project's CDC discipline forbids.

The bridge's `core_reset` is the CLOCK DOMAIN's reset, not the console hold. Wiring
the console hold into it would deadlock the load, because the hold is asserted
precisely while the load must proceed.

## Memory inference: the writing of the CHR load path matters

The CHR array shares its existing single write port between the mapper and the load
through a **single muxed write statement**. This is not cosmetic. An if/else that
names the array twice is read by Vivado as two write ports; it cannot map to a
simple-dual-port RAM and silently falls back to distributed RAM. Measured on a
throwaway synthesis of the whole top with the load path live:

| formulation | Block RAM Tile | RAMB18 | LUT-as-Memory | DistributedRAM |
| --- | ---: | ---: | ---: | ---: |
| pristine (pre-change) | 82 | 0 | 2 | 0 |
| if/else on the array (rejected) | 80 | 0 | 3074 | 1024 |
| single muxed write (this design) | 82 | 0 | 2 | 0 |

The rejected shape moved the 8 KiB CHR array out of block RAM and into 1024 LUT
RAMs -- the silent BRAM-to-LUTRAM regression this project has been bitten by before.
With the muxed write the design is byte-for-byte the pre-change inference: 82 block
RAM tiles (16 PRG + 2 CHR + 32 LCD frame memory + 32 HDMI frame memory), RAMB18 = 0,
LUT-as-Memory = 2. The live load path adds +28 LUT / +1 FF over the pre-change
baseline (41,345 -> 41,373 LUT, 39,613 -> 39,614 FF). These are synthesis readbacks;
memory primitive selection happens at synthesis mapping, and routing does not change
it.

## Gate targets

| id | what | group | Run |
| --- | --- | --- | --- |
| `axi-lite-regs-core` | `axi_lite_regs` elaboration | platform | no |
| `axi-lite-regs-tb` | five-channel handshake, WSTRB, OKAY responses, load transactions, inert gate | platform | yes |
| `cart-load-core` | `nes_cart_load_bridge` elaboration | cart | no |
| `cart-rom-load-tb` | AXI -> bridge -> PRG/CHR arrays; core executes the loaded image | cart | yes |

Both benches are non-vacuous: they were run against a constant-returning slave stub
and a no-op bridge stub and failed, and the load bench additionally requires every
loaded byte to differ from the committed placeholder and the core's own `pc_reg` to
reach a loaded reset vector that the placeholder never reaches.
