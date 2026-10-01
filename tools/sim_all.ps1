[CmdletBinding()]
param(
    [ValidateSet(
        'all',
        'cpu', 'ppu', 'apu', 'bus', 'mapper', 'controller', 'cart', 'video', 'system', 'platform', 'peripheral',
        'cpu-core', 'cpu-integration', 'cpu-bus', 'cpu-inc',
        'ppu-core', 'ppu-sprite', 'ppu-oam-dma', 'ppu-integration', 'chr-feasibility-tb',
        'chr-fetch-core', 'chr-fetch-tb', 'ppu-ext-chr-tb',
        'sprite-fetch-core', 'sprite-fetch-tb',
        'apu-core', 'apu-tb',
        'bus-tb',
        'mapper-nrom', 'mapper-combined', 'mapper-mmc1', 'mapper-mmc3',
        'controller-tb',
        'cart-ines-tb', 'cart-rom-tb',
        'video-core', 'video-tb', 'line-buffer-core', 'line-buffer-tb', 'vga-timing-core', 'vga-timing-tb',
        'video800-tb', 'video800-dc-tb',
        'system-core', 'system-v0', 'system-v0-nmi', 'system-v1-audio', 'system-v2', 'system-v3', 'system-v4', 'system-v5', 'system-v6', 'system-v6-uxrom-prg',
        'platform-core', 'platform-tb', 'qsf-if-core',
        'zynq-clk-tb', 'zynq-top-tb',
        'peripheral-core', 'peripheral-i2c', 'sd-spi-cmd-core', 'sd-spi-cmd-tb',
        'touch-input-tb',
        'cdc-fifo-core', 'cdc-fifo-tb',
        'i2s-shifter-core', 'i2s-shifter-tb',
        'audio-i2s-core', 'audio-i2s-tb'
    )]
    [string]$Mode = 'all'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
    Write-Error -Message 'TEMP is not defined; a temporary directory is required.' -ErrorAction Continue
    exit 1
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$iverilogPath = 'C:\iverilog\bin\iverilog.exe'
$vvpPath = 'C:\iverilog\bin\vvp.exe'
$tempRoot = Join-Path $env:TEMP 'op_fpga_emu'

foreach ($toolPath in @($iverilogPath, $vvpPath)) {
    if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
        Write-Error -Message "Required Icarus Verilog executable not found: $toolPath. Install Icarus Verilog with iverilog.exe and vvp.exe under C:\iverilog\bin; this script does not install tools." -ErrorAction Continue
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $env:TEMP -PathType Container)) {
    Write-Error -Message "Temporary directory not found: $env:TEMP" -ErrorAction Continue
    exit 1
}

if (-not (Test-Path -LiteralPath $tempRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
}

function Invoke-SimulationTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Executable @Arguments | Out-Host
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($null -eq $exitCode) {
        return 1
    }
    return $exitCode
}

$cpuRtl = Join-Path $repoRoot 'rtl\nes_core\cpu\nes_cpu6502.v'

$ppuRtl = Join-Path $repoRoot 'rtl\nes_core\ppu\nes_ppu2c02.v'
$ppuSpriteRtl = Join-Path $repoRoot 'rtl\nes_core\ppu\nes_ppu_sprite.v'
$oamDmaRtl = Join-Path $repoRoot 'rtl\nes_core\ppu\nes_oam_dma.v'
$chrFetchUnitRtl = Join-Path $repoRoot 'rtl\nes_core\ppu\nes_chr_fetch_unit.v'
$spriteChrFetchRtl = Join-Path $repoRoot 'rtl\nes_core\ppu\nes_sprite_chr_fetch.v'

$apuLengthLutRtl = Join-Path $repoRoot 'rtl\nes_core\apu\nes_apu_length_lut.v'
$apuPulseRtl = Join-Path $repoRoot 'rtl\nes_core\apu\nes_apu_pulse.v'
$apuTriangleRtl = Join-Path $repoRoot 'rtl\nes_core\apu\nes_apu_triangle.v'
$apuNoiseRtl = Join-Path $repoRoot 'rtl\nes_core\apu\nes_apu_noise.v'
$apuDmcRtl = Join-Path $repoRoot 'rtl\nes_core\apu\nes_apu_dmc.v'
$apuRtl = Join-Path $repoRoot 'rtl\nes_core\apu\nes_apu2a03.v'

$busRtl = Join-Path $repoRoot 'rtl\nes_core\bus\nes_cpu_bus.v'
$controllerRtl = Join-Path $repoRoot 'rtl\nes_core\controller\nes_controller.v'
$cartParserRtl = Join-Path $repoRoot 'rtl\nes_core\cart\ines_header_parser.v'
$cartRomRtl = Join-Path $repoRoot 'rtl\nes_core\cart\nes_cart_rom.v'

$mapperNromRtl = Join-Path $repoRoot 'rtl\nes_core\mapper\nes_mapper_nrom.v'
$mapperCnromRtl = Join-Path $repoRoot 'rtl\nes_core\mapper\nes_mapper_cnrom.v'
$mapperUxromRtl = Join-Path $repoRoot 'rtl\nes_core\mapper\nes_mapper_uxrom.v'
$mapperMmc1Rtl = Join-Path $repoRoot 'rtl\nes_core\mapper\nes_mapper_mmc1.v'
$mapperMmc3Rtl = Join-Path $repoRoot 'rtl\nes_core\mapper\nes_mapper_mmc3.v'
$mapperRtl = Join-Path $repoRoot 'rtl\nes_core\mapper\nes_mapper.v'

$videoScalerRtl = Join-Path $repoRoot 'rtl\nes_core\video\nes_video_scaler.v'
$lineBufferVgaRtl = Join-Path $repoRoot 'rtl\nes_core\video\nes_line_buffer_vga.v'
$vgaTimingRtl = Join-Path $repoRoot 'rtl\nes_core\video\nes_vga_timing.v'
$video800Rtl = Join-Path $repoRoot 'rtl\nes_core\video\nes_video_800x480.v'
$video800DcRtl = Join-Path $repoRoot 'tb\video\tb_nes_video_800x480_dc.v'

$systemV0Rtl = Join-Path $repoRoot 'rtl\nes_core\system\nes_system_v0.v'
$systemV1Rtl = Join-Path $repoRoot 'rtl\nes_core\system\nes_system_v1.v'
$systemV2Rtl = Join-Path $repoRoot 'rtl\nes_core\system\nes_system_v2.v'
$systemV3Rtl = Join-Path $repoRoot 'rtl\nes_core\system\nes_system_v3.v'
$systemV4Rtl = Join-Path $repoRoot 'rtl\nes_core\system\nes_system_v4.v'
$systemV5Rtl = Join-Path $repoRoot 'rtl\nes_core\system\nes_system_v5.v'
$systemV6Rtl = Join-Path $repoRoot 'rtl\nes_core\system\nes_system_v6.v'

$zynqClkRtl = Join-Path $repoRoot 'rtl\platform\zynq\nes_zynq_clk.v'

$platformTopRtl = Join-Path $repoRoot 'rtl\platform\ep4ce10\nes_ep4ce10_top.v'
$platformPllRtl = Join-Path $repoRoot 'rtl\platform\ep4ce10\nes_ep4ce10_pll_stub.v'
$platformQsfIfRtl = Join-Path $repoRoot 'rtl\platform\ep4ce10\nes_ep4ce10_qsf_if.v'

$wm8978I2cRtl = Join-Path $repoRoot 'rtl\nes_core\peripheral\wm8978_i2c.v'
$sdSpiCmdRtl = Join-Path $repoRoot 'rtl\nes_core\peripheral\sd_spi_cmd.v'
$cdcFifoRtl = Join-Path $repoRoot 'rtl\nes_core\peripheral\nes_cdc_fifo.v'
$i2sShifterRtl = Join-Path $repoRoot 'rtl\nes_core\peripheral\nes_i2s_shifter.v'
$audioI2sRtl = Join-Path $repoRoot 'rtl\nes_core\peripheral\nes_audio_i2s.v'
$touchInputRtl = Join-Path $repoRoot 'rtl\nes_core\peripheral\nes_touch_input.v'
$zynqTopRtl = Join-Path $repoRoot 'rtl\platform\zynq\nes_zynq_top.v'
$zynqTopTbRtl = Join-Path $repoRoot 'tb\platform\tb_nes_zynq_top.v'
$zynqClkTbRtl = Join-Path $repoRoot 'tb\platform\tb_nes_zynq_clk.v'

$cpuSources = @($cpuRtl)
$ppuSources = @($ppuSpriteRtl, $ppuRtl, $chrFetchUnitRtl, $spriteChrFetchRtl)
$ppuSpriteSources = @($ppuSpriteRtl)
$oamDmaSources = @($oamDmaRtl)
$chrFetchUnitSources = @($chrFetchUnitRtl)
$spriteChrFetchSources = @($spriteChrFetchRtl)
$apuSources = @($apuLengthLutRtl, $apuPulseRtl, $apuTriangleRtl, $apuNoiseRtl, $apuDmcRtl, $apuRtl)
$busSources = @($busRtl)
$controllerSources = @($controllerRtl)
$cartSources = @($cartParserRtl)
$cartRomSources = @($cartRomRtl)
$mapperSources = @($mapperNromRtl, $mapperCnromRtl, $mapperUxromRtl, $mapperMmc1Rtl, $mapperMmc3Rtl, $mapperRtl)
$videoSources = @($videoScalerRtl)
$lineBufferVgaSources = @($lineBufferVgaRtl)
$vgaTimingSources = @($vgaTimingRtl)
$video800Sources = @($video800Rtl)
$video800DcSources = @($video800Rtl, $video800DcRtl)
$systemV0Sources = @($systemV0Rtl) + $ppuSources + $cpuSources
$systemV1Sources = @($systemV1Rtl) + $ppuSources + $apuSources + $cpuSources
$systemV2Sources = @($systemV2Rtl) + $ppuSources + $apuSources + $busSources + $cpuSources
$systemV3Sources = @($systemV3Rtl) + $ppuSources + $apuSources + $busSources + $oamDmaSources + $cpuSources
$systemV4Sources = @($systemV4Rtl) + $ppuSources + $apuSources + $busSources + $oamDmaSources + $controllerSources + $cpuSources
$systemV5Sources = @($systemV5Rtl) + $ppuSources + $apuSources + $busSources + $oamDmaSources + $controllerSources + $mapperSources + $cpuSources
# nes_system_v6 instantiates nes_cart_rom for its PRG half, so the cart module is
# a compile dependency of every target that elaborates the v6 core.  CHR_ENABLE is
# 0 in that instance, so only the PRG hex is read and only the 8-bit PRG port
# reaches this target's source list.
$systemV6Sources = @($systemV6Rtl) + $ppuSources + $apuSources + $busSources + $oamDmaSources + $controllerSources + $mapperSources + $cpuSources + @($cartRomRtl, $systemV5Rtl)
$platformSources = @($platformTopRtl, $platformPllRtl, $platformQsfIfRtl)
$platformElabSources = $platformSources + $systemV4Sources + $lineBufferVgaSources + $vgaTimingSources
$peripheralSources = @($wm8978I2cRtl)
$sdSpiCmdSources = @($sdSpiCmdRtl)
$cdcFifoSources = @($cdcFifoRtl)
$i2sShifterSources = @($i2sShifterRtl)
$audioI2sSources = @($cdcFifoRtl, $i2sShifterRtl, $audioI2sRtl)
$touchInputSources = @($touchInputRtl)
# The CHR fetch units are already in $systemV6Sources via $ppuSources; listing
# them again here makes iverilog reject the whole target as a duplicate module.
$zynqTopSources = @($zynqTopRtl, $zynqClkRtl, $touchInputRtl, $video800Rtl,
                    $zynqClkTbRtl) + $systemV6Sources
$zynqTopTbSources = $zynqTopSources + @($zynqTopTbRtl)
$zynqClkSources = @($zynqClkRtl)

$allTargets = @(
    [pscustomobject]@{
        Id          = 'cpu-core'
        Group       = 'cpu'
        Label       = 'CPU core (elaboration)'
        Top         = 'nes_cpu6502'
        Sources     = $cpuSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'cpu-integration'
        Group       = 'cpu'
        Label       = 'CPU integration tb'
        Top         = 'tb_nes_cpu6502'
        Sources     = $cpuSources + (Join-Path $repoRoot 'tb\cpu\tb_nes_cpu6502.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'cpu-bus'
        Group       = 'cpu'
        Label       = 'CPU bus tb'
        Top         = 'tb_nes_cpu6502_bus'
        Sources     = $cpuSources + (Join-Path $repoRoot 'tb\cpu\tb_nes_cpu6502_bus.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'cpu-inc'
        Group       = 'cpu'
        Label       = 'CPU INC/RMW addressing tb'
        Top         = 'tb_nes_cpu6502_inc'
        Sources     = $cpuSources + (Join-Path $repoRoot 'tb\cpu\tb_nes_cpu6502_inc.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'ppu-core'
        Group       = 'ppu'
        Label       = 'PPU core (elaboration)'
        Top         = 'nes_ppu2c02'
        Sources     = $ppuSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'ppu-sprite'
        Group       = 'ppu'
        Label       = 'PPU sprite unit tb'
        Top         = 'tb_nes_ppu_sprite'
        Sources     = $ppuSpriteSources + (Join-Path $repoRoot 'tb\ppu\tb_nes_ppu_sprite.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'ppu-oam-dma'
        Group       = 'ppu'
        Label       = 'PPU OAM DMA tb'
        Top         = 'tb_nes_oam_dma'
        Sources     = $oamDmaSources + (Join-Path $repoRoot 'tb\ppu\tb_nes_oam_dma.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'ppu-integration'
        Group       = 'ppu'
        Label       = 'PPU integration tb'
        Top         = 'tb_nes_ppu2c02'
        Sources     = $ppuSources + (Join-Path $repoRoot 'tb\ppu\tb_nes_ppu2c02.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'chr-feasibility-tb'
        Group       = 'ppu'
        Label       = 'PPU CHR fetch feasibility measurement tb'
        Top         = 'tb_chr_fetch_feasibility'
        Sources     = $ppuSources + (Join-Path $repoRoot 'tb\ppu\tb_chr_fetch_feasibility.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'chr-fetch-core'
        Group       = 'ppu'
        Label       = 'CHR fetch unit (elaboration)'
        Top         = 'nes_chr_fetch_unit'
        Sources     = $chrFetchUnitSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'chr-fetch-tb'
        Group       = 'ppu'
        Label       = 'CHR fetch unit tb'
        Top         = 'tb_nes_chr_fetch_unit'
        Sources     = $chrFetchUnitSources + (Join-Path $repoRoot 'tb\ppu\tb_nes_chr_fetch_unit.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'ppu-ext-chr-tb'
        Group       = 'ppu'
        Label       = 'PPU external CHR A/B pixel-equivalence tb'
        Top         = 'tb_nes_ppu2c02_ext_chr'
           Sources     = $ppuSources + (Join-Path $repoRoot 'tb\ppu\tb_nes_ppu2c02_ext_chr.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'sprite-fetch-core'
        Group       = 'ppu'
        Label       = 'Sprite CHR fetch unit (elaboration)'
        Top         = 'nes_sprite_chr_fetch'
        Sources     = $spriteChrFetchSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'sprite-fetch-tb'
        Group       = 'ppu'
        Label       = 'Sprite CHR fetch unit tb'
        Top         = 'tb_nes_sprite_chr_fetch'
        Sources     = $spriteChrFetchSources + (Join-Path $repoRoot 'tb\ppu\tb_nes_sprite_chr_fetch.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'apu-core'
        Group       = 'apu'
        Label       = 'APU core (elaboration)'
        Top         = 'nes_apu2a03'
        Sources     = $apuSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'apu-tb'
        Group       = 'apu'
        Label       = 'APU full tb'
        Top         = 'tb_nes_apu2a03'
        Sources     = $apuSources + (Join-Path $repoRoot 'tb\apu\tb_nes_apu2a03.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'bus-tb'
        Group       = 'bus'
        Label       = 'CPU bus arbiter tb'
        Top         = 'tb_nes_cpu_bus'
        Sources     = $busSources + (Join-Path $repoRoot 'tb\bus\tb_nes_cpu_bus.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'mapper-nrom'
        Group       = 'mapper'
        Label       = 'Mapper NROM tb'
        Top         = 'tb_nes_mapper_nrom128'
        Sources     = $mapperSources + (Join-Path $repoRoot 'tb\mapper\tb_nes_mapper_nrom128.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'mapper-combined'
        Group       = 'mapper'
        Label       = 'Mapper combined (UxROM/CNROM) tb'
        Top         = 'tb_nes_mapper'
        Sources     = $mapperSources + (Join-Path $repoRoot 'tb\mapper\tb_nes_mapper.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'mapper-mmc1'
        Group       = 'mapper'
        Label       = 'Mapper MMC1 tb'
        Top         = 'tb_nes_mapper_mmc1'
        Sources     = $mapperSources + (Join-Path $repoRoot 'tb\mapper\tb_nes_mapper_mmc1.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'mapper-mmc3'
        Group       = 'mapper'
        Label       = 'Mapper MMC3 tb'
        Top         = 'tb_nes_mapper_mmc3'
        Sources     = $mapperSources + (Join-Path $repoRoot 'tb\mapper\tb_nes_mapper_mmc3.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'controller-tb'
        Group       = 'controller'
        Label       = 'Controller tb'
        Top         = 'tb_nes_controller'
        Sources     = $controllerSources + (Join-Path $repoRoot 'tb\controller\tb_nes_controller.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'cart-ines-tb'
        Group       = 'cart'
        Label       = 'iNES header parser tb'
        Top         = 'tb_ines_header_parser'
        Sources     = $cartSources + (Join-Path $repoRoot 'tb\cart\tb_ines_header_parser.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'cart-rom-tb'
        Group       = 'cart'
        Label       = 'Cartridge PRG/CHR block RAM tb'
        Top         = 'tb_nes_cart_rom'
        Sources     = $cartRomSources + (Join-Path $repoRoot 'tb\cart\tb_nes_cart_rom.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'video-core'
        Group       = 'video'
        Label       = 'Video scaler (elaboration)'
        Top         = 'nes_video_scaler'
        Sources     = $videoSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'video-tb'
        Group       = 'video'
        Label       = 'Video scaler tb'
        Top         = 'tb_nes_video_scaler'
        Sources     = $videoSources + (Join-Path $repoRoot 'tb\video\tb_nes_video_scaler.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'line-buffer-core'
        Group       = 'video'
        Label       = 'VGA line buffer (elaboration)'
        Top         = 'nes_line_buffer_vga'
        Sources     = $lineBufferVgaSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'line-buffer-tb'
        Group       = 'video'
        Label       = 'VGA line buffer tb'
        Top         = 'tb_nes_line_buffer_vga'
        Sources     = $lineBufferVgaSources + (Join-Path $repoRoot 'tb\video\tb_nes_line_buffer_vga.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'vga-timing-core'
        Group       = 'video'
        Label       = 'VGA timing generator (elaboration)'
        Top         = 'nes_vga_timing'
        Sources     = $vgaTimingSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'vga-timing-tb'
        Group       = 'video'
        Label       = 'VGA timing generator tb'
        Top         = 'tb_nes_vga_timing'
        Sources     = $vgaTimingSources + (Join-Path $repoRoot 'tb\video\tb_nes_vga_timing.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'video800-tb'
        Group       = 'video'
        Label       = '800x480 LCD video output tb'
        Top         = 'tb_nes_video_800x480'
        Sources     = $video800Sources + (Join-Path $repoRoot 'tb\video\tb_nes_video_800x480.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'video800-dc-tb'
        Group       = 'video'
        Label       = '800x480 LCD dual-clock video output tb'
        Top         = 'tb_nes_video_800x480_dc'
        Sources     = $video800DcSources
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'system-core'
        Group       = 'system'
        Label       = 'System core (elaboration)'
        Top         = 'nes_system_v0'
        Sources     = $systemV0Sources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'system-v0'
        Group       = 'system'
        Label       = 'System v0 integration tb'
        Top         = 'tb_nes_system_v0'
        Sources     = $systemV0Sources + (Join-Path $repoRoot 'tb\system\tb_nes_system_v0.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'system-v0-nmi'
        Group       = 'system'
        Label       = 'System v0 NMI tb'
        Top         = 'tb_nes_system_v0_nmi'
        Sources     = $systemV0Sources + (Join-Path $repoRoot 'tb\system\tb_nes_system_v0_nmi.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'system-v1-audio'
        Group       = 'system'
        Label       = 'System v1 audio tb'
        Top         = 'tb_nes_system_audio'
        Sources     = $systemV1Sources + (Join-Path $repoRoot 'tb\system\tb_nes_system_audio.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'system-v2'
        Group       = 'system'
        Label       = 'System v2 bus tb'
        Top         = 'tb_nes_system_v2'
        Sources     = $systemV2Sources + (Join-Path $repoRoot 'tb\system\tb_nes_system_v2.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'system-v3'
        Group       = 'system'
        Label       = 'System v3 OAM DMA/DMC tb'
        Top         = 'tb_nes_system_v3'
        Sources     = $systemV3Sources + (Join-Path $repoRoot 'tb\system\tb_nes_system_v3.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'system-v4'
        Group       = 'system'
        Label       = 'System v4 controller tb'
        Top         = 'tb_nes_system_v4'
        Sources     = $systemV4Sources + (Join-Path $repoRoot 'tb\system\tb_nes_system_v4.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'system-v5'
        Group       = 'system'
        Label       = 'System v5 mapper tb'
        Top         = 'tb_nes_system_v5'
        Sources     = $systemV5Sources + (Join-Path $repoRoot 'tb\system\tb_nes_system_v5.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'system-v6'
        Group       = 'system'
        Label       = 'System v6 external CHR tb'
        Top         = 'tb_nes_system_v6'
        Sources     = $systemV6Sources + (Join-Path $repoRoot 'tb\system\tb_nes_system_v6.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'system-v6-uxrom-prg'
        Group       = 'system'
        Label       = 'System v6 UxROM bus-conflict vs registered PRG tb'
        Top         = 'tb_nes_system_v6_uxrom_prg'
        Sources     = $systemV6Sources + (Join-Path $repoRoot 'tb\system\tb_nes_system_v6_uxrom_prg.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'platform-core'
        Group       = 'platform'
        Label       = 'EP4CE10 platform top (elaboration)'
        Top         = 'nes_ep4ce10_top'
        Sources     = $platformElabSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'platform-tb'
        Group       = 'platform'
        Label       = 'EP4CE10 platform top tb'
        Top         = 'tb_nes_ep4ce10_top'
        Sources     = $platformElabSources + (Join-Path $repoRoot 'tb\platform\tb_nes_ep4ce10_top.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'qsf-if-core'
        Group       = 'platform'
        Label       = 'EP4CE10 QSF pin-wrapper (elaboration)'
        Top         = 'nes_ep4ce10_qsf_if'
        Sources     = $platformElabSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'peripheral-core'
        Group       = 'peripheral'
        Label       = 'WM8978 I2C master (elaboration)'
        Top         = 'wm8978_i2c'
        Sources     = $peripheralSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'peripheral-i2c'
        Group       = 'peripheral'
        Label       = 'WM8978 I2C master tb'
        Top         = 'tb_wm8978_i2c'
        Sources     = $peripheralSources + (Join-Path $repoRoot 'tb\peripheral\tb_wm8978_i2c.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'sd-spi-cmd-core'
        Group       = 'peripheral'
        Label       = 'SD SPI command frame transmitter (elaboration)'
        Top         = 'sd_spi_cmd'
        Sources     = $sdSpiCmdSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'sd-spi-cmd-tb'
        Group       = 'peripheral'
        Label       = 'SD SPI command frame transmitter tb'
        Top         = 'tb_sd_spi_cmd'
        Sources     = $sdSpiCmdSources + (Join-Path $repoRoot 'tb\peripheral\tb_sd_spi_cmd.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'cdc-fifo-core'
        Group       = 'peripheral'
        Label       = 'Asynchronous CDC FIFO (elaboration)'
        Top         = 'nes_cdc_fifo'
        Sources     = $cdcFifoSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'cdc-fifo-tb'
        Group       = 'peripheral'
        Label       = 'Asynchronous CDC FIFO tb'
        Top         = 'tb_nes_cdc_fifo'
        Sources     = $cdcFifoSources + (Join-Path $repoRoot 'tb\peripheral\tb_nes_cdc_fifo.v')
        Standard    = '2001'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'i2s-shifter-core'
        Group       = 'peripheral'
        Label       = 'I2S bit serialiser (elaboration)'
        Top         = 'nes_i2s_shifter'
        Sources     = $i2sShifterSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'i2s-shifter-tb'
        Group       = 'peripheral'
        Label       = 'I2S bit serialiser tb'
        Top         = 'tb_nes_i2s_shifter'
        Sources     = $i2sShifterSources + (Join-Path $repoRoot 'tb\peripheral\tb_nes_i2s_shifter.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'audio-i2s-core'
        Group       = 'peripheral'
        Label       = 'I2S assembly layer (elaboration)'
        Top         = 'nes_audio_i2s'
        Sources     = $audioI2sSources
        Standard    = '2001'
        Run         = $false
    },
    [pscustomobject]@{
        Id          = 'audio-i2s-tb'
        Group       = 'peripheral'
        Label       = 'I2S assembly layer tb'
        Top         = 'tb_nes_audio_i2s'
        Sources     = $audioI2sSources + (Join-Path $repoRoot 'tb\peripheral\tb_nes_audio_i2s.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'touch-input-tb'
        Group       = 'peripheral'
        Label       = 'Capacitive touch screen NES input tb'
        Top         = 'tb_nes_touch_input'
        Sources     = $touchInputSources + (Join-Path $repoRoot 'tb\peripheral\tb_nes_touch_input.v')
        Standard    = '2001'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'zynq-clk-tb'
        Group       = 'platform'
        Label       = 'Zynq-7020 MMCM clock generator tb'
        Top         = 'tb_nes_zynq_clk'
        Sources     = $zynqClkSources + (Join-Path $repoRoot 'tb\platform\tb_nes_zynq_clk.v')
        Standard    = '2012'
        Run         = $true
    },
    [pscustomobject]@{
        Id          = 'zynq-top-tb'
        Group       = 'platform'
        Label       = 'Zynq-7020 platform top tb'
        Top         = 'tb_nes_zynq_top'
        Sources     = $zynqTopTbSources
        Standard    = '2012'
        Run         = $true
    }
)

switch ($Mode) {
    'all' { $selected = $allTargets }
    'cpu' { $selected = $allTargets | Where-Object { $_.Group -eq 'cpu' } }
    'ppu' { $selected = $allTargets | Where-Object { $_.Group -eq 'ppu' } }
    'apu' { $selected = $allTargets | Where-Object { $_.Group -eq 'apu' } }
    'bus' { $selected = $allTargets | Where-Object { $_.Group -eq 'bus' } }
    'mapper' { $selected = $allTargets | Where-Object { $_.Group -eq 'mapper' } }
    'controller' { $selected = $allTargets | Where-Object { $_.Group -eq 'controller' } }
    'cart' { $selected = $allTargets | Where-Object { $_.Group -eq 'cart' } }
    'video' { $selected = $allTargets | Where-Object { $_.Group -eq 'video' } }
    'system' { $selected = $allTargets | Where-Object { $_.Group -eq 'system' } }
    'platform' { $selected = $allTargets | Where-Object { $_.Group -eq 'platform' } }
    'peripheral' { $selected = $allTargets | Where-Object { $_.Group -eq 'peripheral' } }
    default { $selected = $allTargets | Where-Object { $_.Id -eq $Mode } }
}

$missingSource = @()
foreach ($source in ($selected | ForEach-Object { $_.Sources })) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        $missingSource += $source
    }
}
if ($missingSource.Count -gt 0) {
    foreach ($source in $missingSource) {
        Write-Error -Message "Required source file not found: $source" -ErrorAction Continue
    }
    exit 1
}

Write-Output ("Mode: {0}  Targets: {1}  Temp: {2}" -f $Mode, @($selected).Count, $tempRoot)
Write-Output ''

$results = @()

# rtl\nes_core\cart\nes_cart_rom.v carries its PRG and CHR content in two hex
# files named relative to the repository root, and both Icarus and Vivado
# resolve a relative $readmemh path against the WORKING DIRECTORY, not against
# the source file's own directory.  Pinning the working directory for the run is
# what makes a clean checkout elaborate; the previous location is restored on
# every normal exit path below.
Push-Location -LiteralPath $repoRoot

foreach ($target in $selected) {
    $outputPath = Join-Path $tempRoot ("{0}.vvp" -f $target.Id)
    if (Test-Path -LiteralPath $outputPath) {
        Remove-Item -LiteralPath $outputPath -Force
    }

    $stage = 'compile'
    $status = 'PASS'
    $detail = ''
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Output ("=== {0} [{1}]" -f $target.Label, $target.Id)
    Write-Output ("--- iverilog -{0} -s {1} -o {2}" -f ('g' + $target.Standard), $target.Top, $outputPath)

    $iverilogArguments = @(('-g' + $target.Standard), '-s', $target.Top, '-o', $outputPath) + @($target.Sources)
    $compileExitCode = Invoke-SimulationTool -Executable $iverilogPath -Arguments $iverilogArguments
    if ($compileExitCode -ne 0) {
        $status = 'FAIL'
        $detail = "iverilog exit $compileExitCode"
    }

    if ($status -eq 'PASS' -and $target.Run) {
        $stage = 'simulate'
        Write-Output ("--- vvp {0}" -f $outputPath)
        $simulateExitCode = Invoke-SimulationTool -Executable $vvpPath -Arguments @($outputPath)
        if ($simulateExitCode -ne 0) {
            $status = 'FAIL'
            $detail = "vvp exit $simulateExitCode"
        }
    }

    $stopwatch.Stop()

    $results += [pscustomobject]@{
        Id      = $target.Id
        Stage   = $stage
        Status  = $status
        Seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        Detail  = $detail
    }
}

Pop-Location

Write-Output ''
Write-Output '=== summary'
$results | Format-Table -AutoSize | Out-String | Write-Output

$failed = @($results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) {
    Write-Output ("FAILED targets: {0}" -f (($failed | ForEach-Object { $_.Id }) -join ', '))
    Write-Output ("Result: FAIL ({0} of {1})" -f $failed.Count, $results.Count)
    exit 1
}

Write-Output ("Result: PASS ({0} of {1})" -f $results.Count, $results.Count)
exit 0
