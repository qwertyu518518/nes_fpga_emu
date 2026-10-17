# run_sdk.ps1 -- build the FSBL and application with xsct, then assemble
# BOOT.bin with bootgen.  Run after build_ps.tcl has written out/ps_nes.hdf
# and out/ps_nes.bit.
#
#   xsct   : Xilinx software command line (SDK 2018.3).  SDK's Eclipse GUI is
#            incomplete in this install; the whole flow is command line.
#   bootgen: turns boot.bif into the boot image.
#
# This is a separate process from Vivado; it never touches the PL design.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$xsct    = 'D:\Vivado\SDK\2018.3\bin\xsct.bat'
$bootgen = 'D:\Vivado\SDK\2018.3\bin\bootgen.bat'

foreach ($t in @($xsct, $bootgen)) {
    if (-not (Test-Path -LiteralPath $t)) { Write-Error "not found: $t"; exit 1 }
}

if (-not (Test-Path -LiteralPath (Join-Path $root 'out\ps_nes.hdf'))) {
    Write-Error 'out/ps_nes.hdf missing -- run run_build.ps1 -Mode full first.'
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $root 'out\ps_nes.bit'))) {
    Write-Error 'out/ps_nes.bit missing -- run run_build.ps1 -Mode full first.'
    exit 1
}

Write-Output '==== xsct: FSBL + application ===='
$xsctLog = Join-Path $root 'sdk_stdout.log'
$p = Start-Process -FilePath $xsct -ArgumentList 'sdk_flow.tcl' `
    -WorkingDirectory $root `
    -RedirectStandardOutput $xsctLog `
    -RedirectStandardError  (Join-Path $root 'sdk_stderr.log') -PassThru
$p.WaitForExit()

$fsblElf = Join-Path $root 'sdk_ws\fsbl\Debug\fsbl.elf'
$appElf  = Join-Path $root 'sdk_ws\loader_app\Debug\loader_app.elf'
foreach ($e in @($fsblElf, $appElf)) {
    if (-not (Test-Path -LiteralPath $e)) {
        Write-Output "SDK_MISSING_ELF $e"
        Get-Content -LiteralPath $xsctLog -ErrorAction SilentlyContinue | Select-Object -Last 30
        exit 1
    }
    Write-Output "SDK_ELF $e $((Get-Item $e).Length) bytes"
}

Write-Output '==== bootgen: BOOT.bin ===='
$bgLog = Join-Path $root 'bootgen_stdout.log'
$p2 = Start-Process -FilePath $bootgen `
    -ArgumentList '-image','boot.bif','-arch','zynq','-o','BOOT.bin','-w','on' `
    -WorkingDirectory $root `
    -RedirectStandardOutput $bgLog `
    -RedirectStandardError  (Join-Path $root 'bootgen_stderr.log') -PassThru
$p2.WaitForExit()

$boot = Join-Path $root 'BOOT.bin'
if (Test-Path -LiteralPath $boot) {
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $boot).Hash
    Write-Output "BOOT_BIN $boot $((Get-Item $boot).Length) bytes SHA256=$h"
} else {
    Write-Output 'BOOT_BIN missing'
    exit 1
}
Write-Output 'SDK_RUN_OK'
exit 0
