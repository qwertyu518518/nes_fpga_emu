# =============================================================================
# run_host_test.ps1 -- build and run the pure-logic USB gamepad test on the host.
#
# The test (test_usb_hid.c) plus the module under test (../app/usb_hid.c) have
# no Xilinx and no hardware dependency, so they build with an ordinary host C
# compiler and run on this machine.  This script finds one and does that.
#
# It prefers MSVC cl.exe (found through vcvars64.bat / vcvarsall.bat) because
# that is what is present in this environment; if a host gcc is on PATH it uses
# that instead.  Nothing here touches Vivado or the ARM toolchain.
#
#   .\tools\ps\host_test\run_host_test.ps1
#
# Exit code is the test's: 0 = PASS, non-zero = FAIL (or no compiler found).
# =============================================================================

[CmdletBinding()]
param(
    # Override the compiler path (cl.exe or gcc.exe).
    [string]$Compiler = '',
    # Override the Visual Studio environment setup script.
    [string]$VcVars = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root   = $PSScriptRoot
$appDir = [IO.Path]::GetFullPath((Join-Path $root '..\app'))
$src    = Join-Path $root 'test_usb_hid.c'
$unit   = Join-Path $appDir 'usb_hid.c'
$outDir = Join-Path $root 'out'
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
$exe = Join-Path $outDir 'test_usb_hid.exe'

foreach ($f in @($src, $unit)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Error "missing source: $f"; exit 2 }
}

function Find-VcVars {
    if ($VcVars -ne '') {
        if (Test-Path -LiteralPath $VcVars) { return $VcVars }
        Write-Error "VcVars not found: $VcVars"; exit 2
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $p = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                        -property installationPath 2>$null
        if ($p) {
            $c = Join-Path $p 'VC\Auxiliary\Build\vcvars64.bat'
            if (Test-Path -LiteralPath $c) { return $c }
        }
    }
    $guesses = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat')
    )
    foreach ($g in $guesses) { if (Test-Path -LiteralPath $g) { return $g } }
    return $null
}

$gcc = if ($Compiler -ne '') { $null } else { (Get-Command gcc -ErrorAction SilentlyContinue) }

if ($gcc) {
    Write-Output "HOST_TEST compiler: gcc ($($gcc.Source))"
    & $gcc.Source -std=c99 -Wall -Wextra -I $appDir -o $exe $src $unit
    if ($LASTEXITCODE -ne 0) { Write-Error "gcc build failed"; exit 2 }
}
else {
    $vc = Find-VcVars
    if ($null -eq $vc) {
        Write-Error 'No host C compiler found (looked for gcc on PATH and vcvars64.bat).'
        exit 2
    }
    Write-Output "HOST_TEST vcvars: $vc"
    $cl = if ($Compiler -ne '') { $Compiler } else { 'cl.exe' }
    $log = Join-Path $outDir 'build.log'
    # Build with the CWD inside out\ so cl drops its .obj files there, next to
    # the executable, instead of wherever this script was launched from.
    $cmd = 'call "' + $vc + '" >nul 2>&1 && cd /d "' + $outDir + '" && cl /nologo /W4 /I "' +
           $appDir + '" "' + $src + '" "' + $unit + '" /Fe:"' + $exe + '"'
    & cmd /c $cmd 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) {
        Write-Error "cl build failed (see $log)"
        exit 2
    }
}

Write-Output 'HOST_TEST running...'
& $exe
$rc = $LASTEXITCODE
Write-Output "HOST_TEST exit=$rc"
exit $rc
