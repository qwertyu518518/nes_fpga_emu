vlib work
vlog -sv ../../rtl/nes_core/ppu/nes_ppu2c02.v tb_nes_ppu2c02.v
vsim -voptargs=+acc work.tb_nes_ppu2c02
run -all
quit -f
