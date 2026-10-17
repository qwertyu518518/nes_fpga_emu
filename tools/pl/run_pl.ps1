<#
.SYNOPSIS
    Reproduce the PL-only Zynq-7020 bitstream from this repository's own source.

.DESCRIPTION
    The primary bitstream this project ships (the zynq_bitstream_vN artefacts the
    hardware bring-up guide tells you to flash) is a PL-only build: the NES core
    and its platform adapter on the fabric, with no Zynq PS and no block design.
    The PS flow lives in ../ps/ and builds something else (a PS + block design
    image for runtime cartridge loading); see docs/00-overview/vivado-runbook.md
    for which flow to use when.

    This launcher reproduces the PL-only artefact from the in-repo scripts
    (build.tcl, finish.tcl, ph_build.tcl).  It stages a throwaway work tree
    outside the source, because the real cartridge has to be placed at the
    committed placeholder PATH for $readmemh to find it (synth_design -generic
    is broken on the 2018.3 command line), and that must not overwrite the
    tracked placeholder hex in the repository.

    The work tree contains: a copy of rtl/ (minus the EP4CE10 board tree), the
    PL wrapper nes_zynq_pl_top.v, the three .tcl files, a stash of the committed
    placeholder hex, and -- at rtl/nes_core/cart/*_placeholder.hex -- a copy of
    the real cartridge from build/rom/.  build/ is gitignored and the cartridge
    is never committed: you must supply it.

.PARAMETER Mode
    full      stages the cartridge, runs build.tcl then finish.tcl (default)
    build     stages the cartridge, runs build.tcl only (stops before the .bit)
    control   stages the committed placeholder, runs ph_build.tcl (provenance
              control; synthesis only)
    stageonly stages the work tree and stops

.PARAMETER WorkDir
    Throwaway directory to stage and build in.  Defaults to tools/pl/out, which
    is gitignored.  It is deleted and recreated on every run.

.PARAMETER Vivado
    Vivado 2018.3 launcher.  Defaults to D:\Vivado\Vivado\2018.3\bin\vivado.bat.

.EXAMPLE
    .\tools\pl\run_pl.ps1
    .\tools\pl\run_pl.ps1 -Mode control
#>

[CmdletBinding()]
param(
    [ValidateSet('full', 'build', 'control', 'stageonly')]
    [string]$Mode = 'full',

    [string]$WorkDir = (Join-Path $PSScriptRoot 'out'),

    [string]$Vivado = 'D:\Vivado\Vivado\2018.3\bin\vivado.bat',

    [int]$MaxAttempts = 4
)

$ErrorActionPreference = 'Stop'

# tools/pl -> tools -> repository root.
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path -LiteralPath (Join-Path $repo 'rtl\platform\zynq\nes_zynq_top.v'))) {
    Write-Error "repository root not found: expected $repo\rtl\platform\zynq\nes_zynq_top.v"
    exit 1
}

# ---- toolchain ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Vivado)) {
    Write-Error ("Vivado not found: '{0}'.  Pass -Vivado <path to vivado.bat>; the " -f $Vivado) -ErrorAction Continue
    Write-Error "repository's own docs record the current install at D:\Vivado\Vivado\2018.3\bin\vivado.bat (the older D:\Xilinx\Vivado\2018.3 path no longer exists)."
    exit 1
}

# ---- cartridge ------------------------------------------------------------
$prgSrc = Join-Path $repo 'build\rom\prg.hex'
$chrSrc = Join-Path $repo 'build\rom\chr.hex'
if ($Mode -ne 'control') {
    foreach ($pair in @(@($prgSrc, 393216), @($chrSrc, 24576))) {
        $path = $pair[0]; $want = $pair[1]
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Error ("the real cartridge is not in the repository: '{0}' is missing.  " -f $path) -ErrorAction Continue
            Write-Error "build/ is gitignored and the cartridge is never committed; place prg.hex (393216 bytes) and chr.hex (24576 bytes) in build/rom/ first."
            exit 1
        }
        $sz = (Get-Item -LiteralPath $path).Length
        if ($sz -ne $want) {
            Write-Error "cartridge file '{0}' is {1} bytes, expected {2}" -f $path, $sz, $want
            exit 1
        }
    }
}

# ---- stage the throwaway work tree ---------------------------------------
if (Test-Path -LiteralPath $WorkDir) {
    $full = [IO.Path]::GetFullPath($WorkDir).TrimEnd('\')
    $repoFull = [IO.Path]::GetFullPath($repo).TrimEnd('\')
    if ($repoFull -eq $full -or $repoFull.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "refusing to delete WorkDir '$WorkDir': it is the repository root or an ancestor of it"
        exit 1
    }
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Write-Output "PL_WORK staging '$WorkDir' (mode=$Mode)"

$workRtl   = Join-Path $WorkDir 'rtl'
$workPl    = Join-Path $WorkDir 'pl'
$workPhHex = Join-Path $WorkDir 'placeholder_hex'
New-Item -ItemType Directory -Force -Path $workPl, $workPhHex | Out-Null

# rtl/ minus the other board (EP4CE10) so build.tcl's `rtl/...` paths resolve
# exactly as they do when Vivado's CWD is this work tree.
Copy-Item -LiteralPath (Join-Path $repo 'rtl') -Destination $workRtl -Recurse -Force
Remove-Item -LiteralPath (Join-Path $workRtl 'platform\ep4ce10') -Recurse -Force -ErrorAction SilentlyContinue

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build.tcl')      -Destination $WorkDir -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'finish.tcl')     -Destination $WorkDir -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ph_build.tcl')   -Destination $WorkDir -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'nes_zynq_pl_top.v')       -Destination $workPl -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'nes_zynq_pl_top_extra.xdc') -Destination $workPl -Force

# The byte-verified stash of the committed placeholder, from the repository's own
# copy (which Copy-Item above already put at rtl/nes_core/cart/).
Copy-Item -LiteralPath (Join-Path $workRtl 'nes_core\cart\prg_placeholder.hex') -Destination $workPhHex -Force
Copy-Item -LiteralPath (Join-Path $workRtl 'nes_core\cart\chr_placeholder.hex') -Destination $workPhHex -Force

# Place the image at the committed placeholder PATH.  full/build use the real
# cartridge; control leaves the committed placeholder in place.
if ($Mode -ne 'control') {
    Copy-Item -LiteralPath $prgSrc -Destination (Join-Path $workRtl 'nes_core\cart\prg_placeholder.hex') -Force
    Copy-Item -LiteralPath $chrSrc -Destination (Join-Path $workRtl 'nes_core\cart\chr_placeholder.hex') -Force
    Write-Output "PL_WORK cartridge staged at rtl/nes_core/cart/*_placeholder.hex from build/rom/"
}

if ($Mode -eq 'stageonly') {
    Write-Output "PL_WORK stageonly done; work tree at $WorkDir"
    exit 0
}

# ---- run a Vivado batch stage, retrying the known XGUI helper-process flake -
# Progress goes to Write-Host, never Write-Output: this function's success-stream
# output IS its return value, so a Write-Output here would be captured by the
# caller's assignment and make "did the stage succeed" meaningless.  The marker
# is matched as a whole line, because Vivado echoes the sourced Tcl and the
# echoed form of a `puts "FINISH DONE"` is not a bare `FINISH DONE` line.
function Invoke-VivadoStage {
    param([string]$Tcl, [string]$Marker, [string]$Tag)

    $outLog = Join-Path $WorkDir "$Tag`_stdout.log"
    $errLog = Join-Path $WorkDir "$Tag`_stderr.log"
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        Write-Host ("==== {0} attempt {1} of {2} ====" -f $Tag, $i, $MaxAttempts)
        Remove-Item -Force $outLog, $errLog -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath $Vivado `
            -ArgumentList '-mode', 'batch', '-nolog', '-nojournal', '-source', $Tcl `
            -WorkingDirectory $WorkDir `
            -RedirectStandardOutput $outLog `
            -RedirectStandardError  $errLog `
            -PassThru
        $p.WaitForExit()
        $code = $p.ExitCode
        $log = ''
        if (Test-Path -LiteralPath $outLog) { $log = [IO.File]::ReadAllText($outLog) }
        $done = $false
        foreach ($line in ($log -split "`n")) {
            if ($line.Trim() -match $Marker) { $done = $true; break }
        }
        $flake = ($log -match "couldn't read file") -or ($log -match 'Error during customization')
        Write-Host ("  {0} attempt {1} exit={2} done={3} flake={4}" -f $Tag, $i, $code, $done, $flake)
        if ($done) { return $true }
        if (-not $flake) {
            Write-Host "  $Tag hard failure (not a known flake); see $outLog"
            return $false
        }
        Start-Sleep -Seconds 10
    }
    return $false
}

$ok = $true
switch ($Mode) {
    'control' {
        $ok = Invoke-VivadoStage -Tcl 'ph_build.tcl' -Marker '^PH BUILD DONE$' -Tag 'ph'
    }
    'build' {
        $ok = Invoke-VivadoStage -Tcl 'build.tcl' -Marker '^BUILD STAGE DONE' -Tag 'build'
    }
    'full' {
        $ok = Invoke-VivadoStage -Tcl 'build.tcl' -Marker '^BUILD STAGE DONE' -Tag 'build'
        if ($ok) { $ok = Invoke-VivadoStage -Tcl 'finish.tcl' -Marker '^FINISH DONE$' -Tag 'finish' }
    }
}

if (-not $ok) {
    Write-Output "RUN_FAILED mode=$Mode work=$WorkDir"
    exit 1
}

# ---- report the artefact --------------------------------------------------
$bit = Join-Path $WorkDir 'nes_zynq_pl_top.bit'
if (($Mode -eq 'full') -and (Test-Path -LiteralPath $bit)) {
    $item = Get-Item -LiteralPath $bit
    $sha  = (Get-FileHash -LiteralPath $bit -Algorithm SHA256).Hash
    Write-Output ("PL_BITSTREAM {0} bytes" -f $item.Length)
    Write-Output ("PL_SHA256 {0}" -f $sha)
}

Write-Output "RUN_OK mode=$Mode work=$WorkDir"
exit 0
