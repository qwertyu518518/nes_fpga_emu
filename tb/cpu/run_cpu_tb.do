vlib work
vlog -sv ../../rtl/nes_core/cpu/nes_cpu6502.v tb_nes_cpu6502.v
vsim -voptargs=+acc work.tb_nes_cpu6502
run -all
vsim -voptargs=+acc work.tb_nes_cpu6502_bus
run -all
vsim -voptargs=+acc work.tb_nes_cpu6502_inc
run -all
quit -f
