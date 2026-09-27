vlib work
vlog -sv ../../rtl/nes_core/apu/nes_apu_length_lut.v ../../rtl/nes_core/apu/nes_apu_pulse.v ../../rtl/nes_core/apu/nes_apu_triangle.v ../../rtl/nes_core/apu/nes_apu_noise.v ../../rtl/nes_core/apu/nes_apu_dmc.v ../../rtl/nes_core/apu/nes_apu2a03.v tb_nes_apu2a03.v
vsim -voptargs=+acc work.tb_nes_apu2a03
run -all
quit -f
