vlib work
vlog -sv ../../rtl/nes_core/cpu/nes_cpu6502.v ../../rtl/nes_core/ppu/nes_ppu2c02.v ../../rtl/nes_core/system/nes_system_v0.v tb_nes_system_v0.v
vsim -voptargs=+acc work.tb_nes_system_v0
run -all
quit -f
