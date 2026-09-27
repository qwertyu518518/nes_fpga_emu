# NES 2A03 CPU testbenches

Three self-contained testbenches cover `rtl/nes_core/cpu/nes_cpu6502.v`. All build their own 64 KiB RAM, so none reads an external ROM or downloads a resource, and none needs a test ROM.

## Interface polarity contract

The module is driven with **logic-high active** control inputs, matching the existing integration contract. There is no inverting logic inside the core.

| Signal | Direction | Polarity / meaning |
| --- | --- | --- |
| `reset` | in | active **high**, asynchronous. Forces the reset state, `sp=$FD`, `p=$24`, then reads the vector at `$FFFC/$FFFD`. |
| `nmi_i` | in | active **high**, **edge** triggered. A rising edge while the core is busy latches `dbg_nmi_pending`; the NMI is recognised at an instruction fetch, or hijacks an in-flight `BRK` or `IRQ` sequence. The line may be held high and the pending event is still consumed once. |
| `irq_i` | in | active **high**, **level** sensitive, reported verbatim on `dbg_irq_pending`. It is only eligible for service when `p[2]` (the I flag) is clear. Reset value `p=$24` has I **set**, so a program must execute `CLI` before an IRQ is taken. |
| `ce` | in | active **high** clock enable. Low freezes the core and forces `bus_req` low. |
| `bus_hold` | in | active **high**. Freezes the core and forces `bus_req` low; the bus outputs must not change while it is asserted. |
| `bus_ready` | in | active **high**. A transfer completes only on a clock edge where `bus_ready` is high; the core holds its outputs stable until then. |
| `bus_req` / `bus_fire` | out | `bus_req` is the ownership request, `bus_fire = bus_req && bus_ready` marks a completed transfer. Every architectural bus cycle, including all dummy reads, is one `bus_fire`. |
| `dbg_illegal` | out | active **high**. Set when a fetched opcode is not in the official 6502 instruction set; the core then stops issuing bus transactions in `ST_TRAP`. |
| `dbg_nmi_pending` | out | active **high** latched NMI event. |
| `dbg_irq_pending` | out | mirrors `irq_i`. |

Every state in the core advances only on `bus_fire`. There is no internal path that advances without an accepted transfer.

## Stack address contract

Every stack access is checked against an **absolute** address, never only relative to its neighbours.

| Transaction kind | Absolute rule |
| --- | --- |
| push write (`PHA`, `PHP`, `JSR`, interrupt `PC`/`P`) | the write address is `$0100 + (SP - 1)`, computed **before** the decrement, and `SP` is decremented to that same value on the completing transfer |
| pull read (`PLA`, `PLP`, `RTS`, `RTI`) | the read address is `$0100 + SP`; the preceding dummy read repeats that same address, and `SP` is incremented only by the data read |

With the reset value `SP=$FD` this means the first push of any sequence lands on `$01FC`, never `$01FD`. Both testbenches run this as a continuous monitor over **every** `bus_fire` that lands in `$01xx`, and `tb_nes_cpu6502_bus.v` additionally pins the concrete addresses of every stack transaction of the interrupt, `JSR`/`RTS` and `PHA`/`PHP`/`PLA`/`PLP` scenarios.

The `PHA`/`PHP` opcode decode is the real 2A03 one: `$48` pushes the accumulator, `$08` pushes `P|0x30`, `$68` pulls into the accumulator and `$28` pulls `P` with bit 4 and bit 5 forced.

## NMI hijack sampling point

The hijack is evaluated at one fixed point: the transfer that completes the low byte of the pushed program counter (`ST_INT_PUSH_LO`), i.e. immediately before `P` is pushed and before either vector is fetched. If `dbg_nmi_pending` is set there and the running sequence is `IRQ` or `BRK`, the sequence switches to the NMI vector `$FFFA/$FFFB`; the pushed `P` keeps the rules of the *taken* interrupt, so a hijacked `BRK` has its `B` bit cleared and an `IRQ` (hijacked or not) pushes `B=0`.

This is a single-sampling-point approximation of the NESdev hijack window. Real 2A03 silicon decides the hijack from the state of the NMI input during the first cycles of the interrupt sequence, so a `BRK` whose NMI arrives later than that window is not hijacked there, and an NMI that arrives one cycle before the sample point is hijacked even though hardware would have missed it. The core models one sampling point rather than the per-microcycle NMI input decode; everything else about the hijacked sequence (push order, pushed PC, pushed `P`, vector fetch) is exact.

## `tb_nes_cpu6502.v` — integration program

`tb_nes_cpu6502.v` keeps the original integration program: immediate and zero-page loads/stores, indexed and indirect addressing, ADC/SBC, comparisons, branches, transfers, flag instructions, `PHA`/`PLP`, `JSR`/`RTS`, accumulator and memory RMW including DEC, JMP indirect, NMI, IRQ, `BRK`, and an injected ready stall. It prints every completed bus transaction and finishes with `$fatal` assertions on the reset sequence, stall behaviour, interrupt results, memory results, registers, and flags.

While the program runs, a continuous monitor `$fatal`s if a stack write is not at `$0100 + (SP-1)`, if `SP` does not become that value on the next transfer, if a stack read is not at `$0100 + SP`, or if the three pushes that precede any `$FFFA`/`$FFFE` vector fetch are not at `$01FC`, `$01FB`, `$01FA`. The same monitor also checks the pushed status byte: `B` set for the `BRK`, `B` clear for the NMI and the IRQ, and bit 5 always set.

The post-reset register check is sampled **one clock after** the transfer that completes the high byte of the reset vector, not on that transfer's own edge. On the completing edge the core's `PC`/`SP`/`P` registers still hold their asynchronous-reset values, so a check placed there can only ever observe `SP=$FD` and `P[5]=1` and can never fail. The deferred sample instead requires `PC=$8000` (the vector actually applied from `$FFFC/$FFFD`), `SP=$FD` and `P=$24`, so a core that never applies the vector, or that clears the wrong flags, is caught.

## `tb_nes_cpu6502_bus.v` — bus cycle conformance

`tb_nes_cpu6502_bus.v` is a per-instruction bus-cycle checker. It records every `bus_fire` into a transaction log (address, direction, write data, read data) and then asserts the exact expected transaction sequence for each scenario. Every check uses `$fatal`; nothing is reported by printing alone. Each scenario is a fresh `reset`, so trace index 7 is always the first opcode fetch after the seven reset transfers.

| Scenario | What is asserted |
| --- | --- |
| `STA $05FF,X` (X=2) | 5 transfers: opcode, two operand bytes, a **dummy read at the un-fixed address `$0501`**, then exactly **one write** at `$0601`. `$0501` is never written. A `bus_hold` window and a `bus_ready` stall are injected around the dummy read. |
| `STA ($30),Y` (Y=5) | 6 transfers including a dummy read at the un-fixed `$0504` and one write at `$0604`; `$0504` is never written. |
| `LDA ($30),Y` (Y=5) | the dummy read data at `$0504` is discarded and `A` takes the data from the fixed address `$0604`. |
| `INC $0600,X` (X=1, no page cross) | 7 transfers: dummy read, data read, old-value write, new-value write, all at the effective address; exactly 2 reads and 2 writes, no writes during the fetch/read window. |
| `INC $05FF,X` (X=1, page cross) | dummy read at `$0500` returning `$EE` is **discarded**; the RMW data comes from the read at `$0600` (`$7F`), then `$7F` is written and then `$80`. `$0500` is never written. A `bus_ready` stall is injected on the data read. |
| `STA $05FF,Y` (Y=1) | the Y-indexed store path also does a dummy read at the un-fixed address and one single write. |
| `STA ($FE),X` (X=3) | 6 transfers; the pointer dummy read is at the **un-indexed** `$00FE`, the low/high bytes come from the wrapped pointer `$0001/$0002`, and the single write lands at the assembled address. |
| `RTS` | all 6 transfers are reads. The `JSR` pushes `$0404` at `$01FC` and `$0402` at `$01FB` (absolute), with its stack dummy read at `$0100+SP` = `$01FD`. The `RTS` dummy read and its low-byte pull are both at `$01FB` and the high-byte pull is at `$01FC`; the **last** transfer is a dummy read at the pulled PC `$0402` and the next transfer is the opcode fetch at `$0403`. A stall is injected on that dummy read. |
| `RTI` | the six `RTI` transfers are pinned one by one: the opcode dummy read at `$0404`, the stack dummy read at `$01F9`, the `P` pull at `$01F9`, the `PCL` pull at `$01FA`, the `PCH` pull at `$01FB`, and the last transfer, a read at the pulled PC `$0405`. The seed stack is reached through `TXS` so the slots are `$0100+SP` for `SP=$F9` and not the reset slot. `SP` is checked at every one of those transactions (`$F9/$F9/$FA/$FB/$FC`: only the data reads increment it), a one-shot probe samples `PC`/`P`/`SP` on the first fetch after the return and requires `PC=$0405`, `P=$2C` from the seeded `$1C` (`B` forced clear, bit 5 forced set) and `SP=$FC`, and the pulled PC is *not* incremented (`LDA #$42` at `$0405` runs, a spurious `+1` would execute the operand byte `$42`, which traps). `$01F8`/`$01FC` are never touched, and the stack slots are read-only. A `bus_hold` window covers the `P` pull and a stall is injected on the `PCL` pull. |
| IRQ | the interrupt is taken at the fetch of `$040F`; the **second dummy read is at the current PC `$040F`**, not `$0410`; the pushed PC is `$040F`, written at `$01FC` (high) and `$01FB` (low); the pushed P is exactly `$20` at `$01FA`, B clear and bit 5 set; the vector is read from `$FFFE/$FFFF`. |
| NMI | same dummy-address, pushed-PC and absolute-push-slot checks, vector `$FFFA/$FFFB`, and `dbg_nmi_pending` returns low. |
| `BRK` + NMI hijack | `BRK` uses its own padding state: the opcode is fetched at `$0402` and its padding read is at `$0403` (PC+1), not the current PC. An NMI arriving during the BRK hijacks the sequence: the pushes still land at `$01FC`/`$01FB`/`$01FA`, the pushed P is exactly `$24` with B **cleared**, the vector read is `$FFFA/$FFFB`, `$FFFE/$FFFF` is never read, and the IRQ-vector handler never runs. |
| IRQ + NMI hijack | the program executes `CLI` and the IRQ is taken at the fetch of `$040F`. The NMI is injected one transfer before the hijack sample point, on the `$01FC` push. The pushes still land at `$01FC`/`$01FB`/`$01FA`, the pushed P is exactly `$20` (I clear because `CLI` ran, B clear), the vector read is `$FFFA/$FFFB` rather than `$FFFE/$FFFF`, `dbg_nmi_pending` returns low, and the `$0600` IRQ handler never runs. |
| `PHA`/`PHP`/`PLA`/`PLP` | two push/pull pairs. `PHA` writes `$01FC` then `PHP` writes `$01FB`; `PLA` then re-reads `$01FB` for its dummy and its data, and `PLP` re-reads `$01FC` the same way. The pulled values are checked byte-exactly (`$34` into A, `$5A` into P, then `$78` into A, `$7E` into P), `$01FD`/`$01FA` are never written, and the final `A`/`P`/`SP` prove the data read (not the discarded dummy) was the one used. |
| `$1A`, `$3A`, `$5A`, `$7A`, `$B2` | the opcode is fetched, `dbg_illegal` is set, the core issues **no further bus transactions**, PC does not advance, and A/X/Y/SP/P are bit-for-bit unchanged. The store placed after the illegal opcode is never executed. |

The testbench also runs continuous monitors that `$fatal` if `bus_addr`, `bus_we`, or `bus_dout` change while `bus_req` is high with `bus_ready` low, or while `bus_hold` is asserted, and a third monitor that applies the absolute stack slot rule from the section above to every `bus_fire` in `$01xx` in every scenario. Every logged transfer also records the `SP` visible on that transfer (`tr_sp[]`), so a scenario can assert the stack pointer progression across a pull sequence and not only the addresses.

## `tb_nes_cpu6502_inc.v` — addressing-mode self-check for the RMW opcodes

A deliberately small third testbench that pins the `decode_mode` table for `INC`/`DEC`/`ASL`/`LSR`/`ROL`/`ROR`. It asserts the individual bus transactions of each instruction, not only the final memory content, so an opcode that decodes to the wrong addressing mode fails on the transaction it got wrong. Every check is a `$fatal`; nothing is reported by printing alone. Each scenario is a fresh `reset`.

| Scenario | Program | What is asserted |
| --- | --- | --- |
| `INC $1234` | `EE 34 12` | 6 transfers: the opcode fetch at `$0400`, the two operand bytes at `$0401`/`$0402`, a read at **`$1234`** returning `$7F`, a **write of the old value `$7F`**, a **write of the new value `$80`**, then the next opcode fetch at `$0403`. The four fetch/read transfers are asserted to be reads, `$1234` is touched by exactly 1 read and 2 writes, `$0034` is never touched at all, the final memory holds `$80`, `P` is `$A4` (`N` set by the new value, `Z` clear), the final `PC` is `$0406` sampled at the marker write and again one transfer later, and the seeded `$0034` sentinel is unchanged. |
| `INC $34` | `E6 34` | 5 transfers: opcode fetch, one operand byte, a read at **`$0034`** returning `$56`, an **old-value write `$56`**, a **new-value write `$57`**, then the next opcode fetch. This is the ZP/ABS boundary case: `$E6` is officially `INC` zero page, so it must take 5 transfers, must not read a second operand byte, and must not touch `$1234` at all. `P` is `$24` and the final `PC` is `$0405`. |
| `LDX $1234,Y` | `A0 02 / BE 34 12` | Y-indexed absolute load, the addressing mode of `$BE`, which is absent from neither `decode_class` nor `decode_mode`: the operand bytes are both consumed and the data is read at the fixed address `$1236` (no dummy read), `X` ends up `$77`, and the seeded `$1234` and `$1236` are otherwise untouched. |

The trace index of the first opcode fetch is discovered at run time and the reset prefix in front of it is asserted (all reads, all at `$0000`, then `$FFFC`, then `$FFFD`), so the exact index arithmetic is checked without hard-coding the reset length. The scenario marker is the `STA $7FF0` at the end of each program, and `PC`/`P` are sampled on the completing edge of that write and again on the next transfer, because on the marker's own edge the register read can only observe pre-edge values.

## Remaining micro-cycle deviations

These are known and **not** covered by any assertion in the two testbenches:

| Deviation | Detail |
| --- | --- |
| `PLA`/`PLP` cycle 4 | the 2A03 spends the fourth cycle on a dummy read at PC+1. The core instead spends it on the discarded `$0100+SP` dummy read, so the transfer count is right but the cycle-4 address is `$01xx` instead of PC+1. The data read of cycle 3 is at the correct `$0100+SP`. |
| `JSR` cycle 3 | the real 2A03 reads the stack in that "internal operation" cycle at `$0100+SP`; the core does the same, so this one matches, but the core does not model the RDY-sensitive read-during-write or the exact internal cycle in which the RDY line is sampled. |
| NMI/IRQ hijack window | one sample point only, see the section above; the per-microcycle NMI input decode of real silicon is not modelled. |
| Interrupt dummy cycles | both interrupt dummy reads use the current PC (`ST_INT_DUMMY2` and the interrupt entry) rather than PC+1; the `BRK` padding read is at PC+1. This matches the behaviour the bus testbench pins, and no `IRQ`/`NMI` cycle ever advances PC before the push, so it is unobservable in this design. |
| Cycle-level RMW | `RMW` writes the old value then the new value at consecutive transfers, which is the right shape, but the core does not insert the 2A03's extra write-cycle behaviour for `read-modify-write` when `RDY` is asserted. |
| Illegal opcodes | unknown opcodes halt in `ST_TRAP` with `dbg_illegal` set; the core does not implement the unstable JMP/JAM opcodes. |

## Running

With Icarus Verilog (this is what is available on this machine):

```text
iverilog -g2012 -o cpu_tb.vvp ../../rtl/nes_core/cpu/nes_cpu6502.v tb_nes_cpu6502.v
vvp cpu_tb.vvp
iverilog -g2012 -o cpu_bus_tb.vvp ../../rtl/nes_core/cpu/nes_cpu6502.v tb_nes_cpu6502_bus.v
vvp cpu_bus_tb.vvp
iverilog -g2012 -o cpu_inc_tb.vvp ../../rtl/nes_core/cpu/nes_cpu6502.v tb_nes_cpu6502_inc.v
vvp cpu_inc_tb.vvp
```

`-g2012` is needed because the testbenches drive `reg`/`wire` testbench signals and use `$fatal`. The core itself is plain Verilog-2001 and elaborates cleanly with `iverilog -g2001`.

With ModelSim/Questa from this directory:

```text
vlib work
vlog -sv ../../rtl/nes_core/cpu/nes_cpu6502.v tb_nes_cpu6502.v
vsim -voptargs=+acc work.tb_nes_cpu6502
run -all
```

The included script performs the same sequence:

```text
vsim -c -do run_cpu_tb.do
```

## Debug outputs

`bus_req` is the CPU ownership request, `bus_fire` is the completed transfer, and `cpu_cycle_phase` is a four-bit transaction phase counter. `dbg_state` exposes the 7-bit internal state encoding; the bus testbench deliberately does not depend on those encodings and only checks observable bus behaviour. The CPU module itself contains no RAM, PPU, APU, mapper, or DMA state.
