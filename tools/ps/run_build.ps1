# run_build.ps1 -- launcher for tools/ps/build_ps.tcl.
#
# Sets the CWD to this directory (project-mode synthesis resolves the cartridge
# hex against the run directory, which build_ps.tcl stages explicitly; the
# launcher keeps every repo-relative path in the script predictable), runs
# Vivado 2018.3 in batch mode, and retries the documented transient XGUI /
# unimacro helper-process race.
#
#   -Mode bdonly     build + validate the block design only (fast integration)
#   -Mode synthonly  synth + reports, no implementation
#   -Mode full       synth + place + route + bitstream + .hdf (default)

param([string]$Mode = "full")

$ErrorActionPreference = 'Stop'

$root   = $PSScriptRoot
$vivado = 'D:\Vivado\Vivado\2018.3\bin\vivado.bat'
$max    = 4

if (-not (Test-Path -LiteralPath $vivado)) {
    Write-Error "Vivado not found: $vivado"
    exit 1
}

$marker = 'PS_BUILD_DONE'
if ($Mode -eq 'bdonly')    { $marker = 'BD_ONLY_EXIT' }
if ($Mode -eq 'synthonly') { $marker = 'SYNTH_ONLY_EXIT' }

$outLog = Join-Path $root 'ps_stdout.log'
$errLog = Join-Path $root 'ps_stderr.log'

for ($i = 1; $i -le $max; $i++) {
    Write-Output "==== ATTEMPT $i of $max (mode=$Mode) ===="
    if ($Mode -eq 'full') {
        Remove-Item -Recurse -Force (Join-Path $root 'proj') -ErrorAction SilentlyContinue
    }
    Remove-Item -Force $outLog, $errLog -ErrorAction SilentlyContinue

    $env:PS_MODE = $Mode
    $p = Start-Process -FilePath $vivado `
        -ArgumentList '-mode','batch','-nolog','-nojournal','-source','build_ps.tcl' `
        -WorkingDirectory $root `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError  $errLog `
        -PassThru
    $p.WaitForExit()
    $code = $p.ExitCode

    $log = ''
    if (Test-Path -LiteralPath $outLog) { $log = [IO.File]::ReadAllText($outLog) }
    $done  = $log.Contains($marker)
    $flake = ($log -match "couldn't read file") -or ($log -match 'Error during customization')
    Write-Output "attempt $i exit=$code done=$done flake=$flake"

    if ($done) { Write-Output "RUN_OK on attempt $i"; exit 0 }
    if (-not $flake) { Write-Output "RUN_HARD_FAIL attempt $i (not a known flake)" }
    Start-Sleep -Seconds 10
}

Write-Output 'RUN_ALL_ATTEMPTS_FAILED'
exit 1
