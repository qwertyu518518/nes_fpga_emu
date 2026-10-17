# init_diff.ps1 -- differential of the inferred RAMB INIT/INITP between the
# committed PS build (out/ps_bram_init.txt) and a control re-synthesis of the
# identical tree with the two $readmemh files' first byte flipped
# (out/ps_bram_init_ph.txt).  Both dumps are produced by tools/ps/init_diff.tcl.
#
# This is the check the tile count cannot make: 82 block RAM tiles appear
# whether the array holds the committed placeholder or any other image.  Keys
# on the LABEL (INIT_00..) so an empty readback cannot be mistaken for a
# missing field or a zero.
param(
    [string]$Committed = (Join-Path $PSScriptRoot 'out\ps_bram_init.txt'),
    [string]$Control   = (Join-Path $PSScriptRoot 'out\ps_bram_init_ph.txt')
)

$ErrorActionPreference = 'Stop'

function Read-Dump([string]$path) {
    $map = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line.StartsWith('#') -or $line.Trim() -eq '') { continue }
        $tok = $line -split ' '
        $name = $tok[0]; $ref = $tok[1]
        $fields = [ordered]@{}
        foreach ($t in $tok) {
            if ($t -match '^((?:INIT|INITP)_[0-9A-F]{2})=(.*)$') { $fields[$Matches[1]] = $Matches[2] }
        }
        $map[$name] = [pscustomobject]@{ Ref = $ref; Fields = $fields }
    }
    return $map
}

function Get-Array([string]$n) {
    if ($n -match 'frame_mem_reg') { 'FRAME' }
    elseif ($n -match 'prg_rom_reg') { 'PRG' }
    elseif ($n -match 'chr_rom_reg') { 'CHR' }
    else { 'OTHER' }
}

if (-not (Test-Path -LiteralPath $Committed)) { Write-Error "missing $Committed"; exit 1 }
if (-not (Test-Path -LiteralPath $Control))   { Write-Error "missing $Control"; exit 1 }

$a = Read-Dump $Committed
$b = Read-Dump $Control
"cells: committed=$($a.Count)  control=$($b.Count)"
$onlyA = @($a.Keys | Where-Object { -not $b.Contains($_) })
$onlyB = @($b.Keys | Where-Object { -not $a.Contains($_) })
"cells only in committed dump : $($onlyA.Count) $($onlyA -join ',')"
"cells only in control dump   : $($onlyB.Count) $($onlyB -join ',')"

$diffCells = @()
$initDiffTotal = 0
$initPDiffTotal = 0
$perArray = @{}
$perCell = @()
$labelMiss = 0

foreach ($name in $a.Keys) {
    if (-not $b.Contains($name)) { continue }
    $fa = $a[$name].Fields; $fb = $b[$name].Fields
    $labels = @($fa.Keys) + @($fb.Keys | Where-Object { -not $fa.Contains($_) }) | Sort-Object -Unique
    $di = 0; $dip = 0
    foreach ($l in $labels) {
        $va = if ($fa.Contains($l)) { $fa[$l] } else { $labelMiss++; '<no-label>' }
        $vb = if ($fb.Contains($l)) { $fb[$l] } else { $labelMiss++; '<no-label>' }
        if ($va -ne $vb) {
            if ($l -like 'INITP_*') { $dip++ } else { $di++ }
        }
    }
    $arr = Get-Array $name
    if (-not $perArray.ContainsKey($arr)) { $perArray[$arr] = [ordered]@{ cells = 0; diffCells = 0; init = 0; initp = 0 } }
    $perArray[$arr].cells++
    $initDiffTotal += $di
    $initPDiffTotal += $dip
    if ($di -ne 0 -or $dip -ne 0) {
        $perArray[$arr].diffCells++
        $perArray[$arr].init += $di
        $perArray[$arr].initp += $dip
        $diffCells += [pscustomobject]@{ Cell = $name; Array = $arr; InitDiff = $di; InitPDiff = $dip }
    }
    $perCell += [pscustomobject]@{ Cell = $name; Array = $arr; InitDiff = $di; InitPDiff = $dip }
}

''
'=== per-array summary ==='
'{0,-8} {1,6} {2,11} {3,10} {4,10}' -f 'ARRAY', 'CELLS', 'DIFFCELLS', 'INITDIFF', 'INITPDIFF'
foreach ($k in @('PRG','CHR','FRAME','OTHER')) {
    if ($perArray.ContainsKey($k)) {
        $v = $perArray[$k]
        '{0,-8} {1,6} {2,11} {3,10} {4,10}' -f $k, $v.cells, $v.diffCells, $v.init, $v.initp
    }
}
''
'=== TOTALS ==='
"cells with ANY difference : $($diffCells.Count) of $($a.Count)"
"INIT data words differing : $initDiffTotal"
"INITP parity words differing : $initPDiffTotal"
"label-count mismatches between the two dumps : $labelMiss"
''
'=== checks ==='
function Say($label, $ok, $detail) { if ($ok) { "PASS  $label  $detail" } else { "FAIL  $label  $detail" } }
$prg = if ($perArray.ContainsKey('PRG')) { $perArray['PRG'] } else { [ordered]@{diffCells=0} }
$chr = if ($perArray.ContainsKey('CHR')) { $perArray['CHR'] } else { [ordered]@{diffCells=0} }
$frm = if ($perArray.ContainsKey('FRAME')) { $perArray['FRAME'] } else { [ordered]@{diffCells=0} }
Say 'same set of RAMB cells in both dumps' (($onlyA.Count -eq 0) -and ($onlyB.Count -eq 0)) "onlyA=$($onlyA.Count) onlyB=$($onlyB.Count)"
Say 'control changed the cartridge arrays (non-vacuous)' (($prg.diffCells + $chr.diffCells) -gt 0) "prg diff=$($prg.diffCells) chr diff=$($chr.diffCells)"
Say 'the frame memories are identical (only the cartridge moved)' ($frm.diffCells -eq 0) "frame diff=$($frm.diffCells)"
Say 'committed build really holds an image (not empty)' ($initDiffTotal -gt 0) "INIT words differing = $initDiffTotal"

if ((($prg.diffCells + $chr.diffCells) -gt 0) -and ($frm.diffCells -eq 0)) {
    Write-Output 'INIT_DIFF_RESULT: PASS'
    exit 0
} else {
    Write-Output 'INIT_DIFF_RESULT: FAIL'
    exit 1
}
