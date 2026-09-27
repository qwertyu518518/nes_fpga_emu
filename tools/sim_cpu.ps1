[CmdletBinding()]
param(
    [ValidateSet('rtl', 'pure', 'integration', 'bus', 'all')]
    [string]$Mode = 'integration'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
    throw 'TEMP is not defined; a temporary directory is required.'
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$iverilogPath = 'C:\iverilog\bin\iverilog.exe'
$vvpPath = 'C:\iverilog\bin\vvp.exe'
$tempRoot = Join-Path $env:TEMP 'op_fpga_emu'
$cpuRtlPath = Join-Path $repoRoot 'rtl\nes_core\cpu\nes_cpu6502.v'
$integrationTbPath = Join-Path $repoRoot 'tb\cpu\tb_nes_cpu6502.v'
$busTbPath = Join-Path $repoRoot 'tb\cpu\tb_nes_cpu6502_bus.v'

foreach ($toolPath in @($iverilogPath, $vvpPath)) {
    if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
        throw "Required Icarus Verilog executable not found: $toolPath. Install Icarus Verilog with iverilog.exe and vvp.exe under C:\iverilog\bin; this script does not install tools."
    }
}

foreach ($sourcePath in @($cpuRtlPath, $integrationTbPath, $busTbPath)) {
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required source file not found: $sourcePath"
    }
}

if (-not (Test-Path -LiteralPath $env:TEMP -PathType Container)) {
    throw "Temporary directory not found: $env:TEMP"
}

if (-not (Test-Path -LiteralPath $tempRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
}

function Invoke-CpuSimulation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Top,
        [Parameter(Mandatory = $true)]
        [string[]]$Sources
    )

    $outputPath = Join-Path $tempRoot ("{0}.vvp" -f $Name)
    if (Test-Path -LiteralPath $outputPath) {
        Remove-Item -LiteralPath $outputPath -Force
    }

    $iverilogArguments = @('-g2012', '-s', $Top, '-o', $outputPath) + $Sources
    Write-Output ("[{0}] Compiling {1}" -f $Name, $Top)
    & $iverilogPath @iverilogArguments
    if ($LASTEXITCODE -ne 0) {
        throw ("iverilog failed for {0} with exit code {1}." -f $Name, $LASTEXITCODE)
    }

    Write-Output ("[{0}] Running {1}" -f $Name, $outputPath)
    & $vvpPath $outputPath
    if ($LASTEXITCODE -ne 0) {
        throw ("vvp failed for {0} with exit code {1}." -f $Name, $LASTEXITCODE)
    }

    Write-Output ("[{0}] PASS" -f $Name)
}

switch ($Mode) {
    'rtl' {
        Invoke-CpuSimulation -Name 'rtl' -Top 'nes_cpu6502' -Sources @($cpuRtlPath)
    }
    'pure' {
        Invoke-CpuSimulation -Name 'pure' -Top 'nes_cpu6502' -Sources @($cpuRtlPath)
    }
    'integration' {
        Invoke-CpuSimulation -Name 'integration' -Top 'tb_nes_cpu6502' -Sources @($cpuRtlPath, $integrationTbPath)
    }
    'bus' {
        Invoke-CpuSimulation -Name 'bus' -Top 'tb_nes_cpu6502_bus' -Sources @($cpuRtlPath, $busTbPath)
    }
    'all' {
        Invoke-CpuSimulation -Name 'rtl' -Top 'nes_cpu6502' -Sources @($cpuRtlPath)
        Invoke-CpuSimulation -Name 'integration' -Top 'tb_nes_cpu6502' -Sources @($cpuRtlPath, $integrationTbPath)
        Invoke-CpuSimulation -Name 'bus' -Top 'tb_nes_cpu6502_bus' -Sources @($cpuRtlPath, $busTbPath)
    }
}
