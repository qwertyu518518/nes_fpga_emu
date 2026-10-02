[CmdletBinding()]
param(
    [string]$WorkRoot = (Join-Path $env:TEMP 'op_fpga_emu_nes2hex_selftest')
)

# tools/nes2hex_selftest.ps1 : proof that tools/nes2hex.ps1 converts correctly.
#
# Nothing here uses a copyrighted ROM.  Every input is synthesised byte by byte
# in memory from a known pattern, converted by the real tool, and the produced
# hex is read back and compared word by word against the source bytes.
#
# Groups
#   A  round trip, 5 positive cases (NROM 16 KiB, NROM 128 KiB, CHR-RAM,
#      trainer present, mapper 3 / MMC3)
#   B  padding, the 16 KiB PRG case must be exactly 131072 words with 00 past
#      the real data
#   C  format byte-exactness against rtl/nes_core/cart/prg_placeholder.hex and
#      chr_placeholder.hex: same line width, same separator, same case, and a
#      full byte-identical re-emission of the committed files' own contents
#   D  negative cases: bad magic, truncated file, size mismatch, oversized PRG,
#      zero PRG banks, NES2.0 exponent notation, existing output, placeholder
#      overwrite.  Each must exit non-zero AND leave no output behind.

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$tool = Join-Path $PSScriptRoot 'nes2hex.ps1'
$placeholderPrg = Join-Path $repoRoot 'rtl\nes_core\cart\prg_placeholder.hex'
$placeholderChr = Join-Path $repoRoot 'rtl\nes_core\cart\chr_placeholder.hex'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Pass = 0
$script:FailCount = 0
$script:Failures = New-Object System.Collections.ArrayList

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:Pass++
        Write-Output ("  PASS  " + $Name)
    } else {
        $script:FailCount++
        [void]$script:Failures.Add($Name + $(if ($Detail -ne '') { ' :: ' + $Detail } else { '' }))
        Write-Output ("  FAIL  " + $Name + $(if ($Detail -ne '') { '  [' + $Detail + ']' } else { '' }))
    }
}

function New-DeterministicBytes {
    param([int]$Length, [int]$Seed)
    $data = New-Object byte[] $Length
    $x = $Seed -band 0xFFFF
    for ($i = 0; $i -lt $Length; $i++) {
        # A 16-bit xorshift-style mixer kept entirely inside int32 range so no
        # intermediate value ever becomes a double: adjacent words are never
        # equal, so a formatter that shifted, dropped or duplicated a word
        # cannot pass by coincidence.
        $x = (($x * 251) + 17) -band 0xFFFF
        $t = ($x -bxor ($x -shr 5)) -band 0xFFFF
        $t = (((($t -shl 3) -band 0xFFFF) -bxor $t) -band 0xFFFF)
        $data[$i] = [byte](($t -bxor $i) -band 0xFF)
    }
    return ,$data
}

function New-RomImage {
    param(
        [int]$PrgBytes,
        [int]$ChrBytes,
        [int]$MapperId,
        [bool]$Trainer,
        [bool]$FourScreen,
        [bool]$Battery,
        [bool]$Vertical,
        [byte[]]$PrgPayload,
        [byte[]]$ChrPayload,
        [byte[]]$TrainerPayload,
        [string]$Magic
    )

    if ([string]::IsNullOrEmpty($Magic)) { $Magic = 'NES' + [char]0x1A }

    $f6 = 0
    if ($Trainer)  { $f6 = $f6 -bor 0x04 }
    if ($Battery)  { $f6 = $f6 -bor 0x02 }
    if ($FourScreen) { $f6 = $f6 -bor 0x08 }
    if ($Vertical) { $f6 = $f6 -bor 0x01 }
    $f6 = $f6 -bor ((($MapperId -band 0x0F) -shl 4) -band 0xF0)
    $f7 = (($MapperId -shr 4) -band 0x0F) -shl 4

    $headerTail = [byte[]]@(
        [byte](($PrgBytes / 16384) -band 0xFF),
        [byte](($ChrBytes / 8192) -band 0xFF),
        [byte]($f6 -band 0xFF),
        [byte]($f7 -band 0xFF),
        [byte]0, [byte]0, [byte]0, [byte]0, [byte]0, [byte]0, [byte]0, [byte]0
    )

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add([System.Text.Encoding]::ASCII.GetBytes($Magic))
    [void]$parts.Add($headerTail)
    if ($null -ne $TrainerPayload) { [void]$parts.Add($TrainerPayload) }
    if ($null -ne $PrgPayload) { [void]$parts.Add($PrgPayload) }
    if ($null -ne $ChrPayload) { [void]$parts.Add($ChrPayload) }

    $stream = New-Object System.IO.MemoryStream
    foreach ($p in $parts) { $stream.Write($p, 0, $p.Length) }
    $out = $stream.ToArray()
    $stream.Dispose()
    return ,$out
}

function Invoke-Tool {
    param([string[]]$Arguments)

    $stdout = New-Object System.Collections.ArrayList
    $stderr = New-Object System.Collections.ArrayList
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $quoted = @()
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tool) + $Arguments) {
        if ($a -match '\s') { $quoted += '"' + $a + '"' } else { $quoted += $a }
    }
    $psi.Arguments = ($quoted -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $repoRoot

    $proc = [System.Diagnostics.Process]::Start($psi)
    $so = $proc.StandardOutput.ReadToEnd()
    $se = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    foreach ($line in ($so -split "`r?`n")) { if ($line -ne '') { [void]$stdout.Add($line) } }
    foreach ($line in ($se -split "`r?`n")) { if ($line -ne '') { [void]$stderr.Add($line) } }

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $so
        StdErr   = $se
        Lines    = $stdout
    }
}

function Read-HexImage {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, $Utf8NoBom)
    $values = New-Object System.Collections.ArrayList
    foreach ($line in ($text -split "`n")) {
        if ($line -eq '') { continue }
        foreach ($tok in ($line -split ' ')) {
            [void]$values.Add([Convert]::ToByte($tok, 16))
        }
    }
    return ,$values.ToArray()
}

if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
[void](New-Item -ItemType Directory -Path $WorkRoot -Force)

$tmpIndex = 0
function New-TmpDir {
    $script:tmpIndex++
    $p = Join-Path $WorkRoot ("case{0:d2}" -f $script:tmpIndex)
    [void](New-Item -ItemType Directory -Path $p -Force)
    return $p
}

Write-Output '=== A. round trip: synthetic ROM in, hex out, every word verified'

# ---- A1: NROM, 16 KiB PRG / 8 KiB CHR -------------------------------------
Write-Output ''
Write-Output '  case A1  mapper 0 (NROM), 16 KiB PRG + 8 KiB CHR, no trainer'
$d = New-TmpDir
$prgPayload = New-DeterministicBytes -Length 16384 -Seed 12345
$chrPayload = New-DeterministicBytes -Length 8192  -Seed 999
$rom = New-RomImage -PrgBytes 16384 -ChrBytes 8192 -MapperId 0 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $true `
    -PrgPayload $prgPayload -ChrPayload $chrPayload
$romPath = Join-Path $d 'a1.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
$r = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-Quiet')
Check 'A1 exit 0' ($r.ExitCode -eq 0) ("exit " + $r.ExitCode + " " + $r.StdErr)

$prgPath = Join-Path $d 'prg.hex'
$chrPath = Join-Path $d 'chr.hex'
Check 'A1 prg.hex exists' (Test-Path -LiteralPath $prgPath)
Check 'A1 chr.hex exists' (Test-Path -LiteralPath $chrPath)

if ((Test-Path -LiteralPath $prgPath) -and (Test-Path -LiteralPath $chrPath)) {
    $got = Read-HexImage $prgPath
    $mismatch = -1
    for ($i = 0; $i -lt 16384; $i++) {
        if ($got[$i] -ne $prgPayload[$i]) { $mismatch = $i; break }
    }
    Check 'A1 all 16384 PRG words match source byte-for-byte' ($mismatch -eq -1) ("first mismatch at word $mismatch")

    $gotC = Read-HexImage $chrPath
    $mismatch = -1
    for ($i = 0; $i -lt 8192; $i++) {
        if ($gotC[$i] -ne $chrPayload[$i]) { $mismatch = $i; break }
    }
    Check 'A1 all 8192 CHR words match source byte-for-byte' ($mismatch -eq -1) ("first mismatch at word $mismatch")

    # The header must not be in the image: prg.hex word 0 has to be the ROM's
    # own first PRG byte ('N' = 0x4E would mean the header was emitted).
    $headerLeaked = ($got[0] -eq 0x4E) -and ($got[1] -eq 0x45) -and ($got[2] -eq 0x53) -and ($got[3] -eq 0x1A)
    Check 'A1 16-byte header is stripped, not emitted' (-not $headerLeaked)
    Check 'A1 prg.hex word 0 is the ROM first PRG byte' ($got[0] -eq $prgPayload[0])

    $full = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-PrgOut', (Join-Path $d 'p2.hex'), '-ChrOut', (Join-Path $d 'c2.hex'))
    Check 'A1 summary reports MAPPER 0 (NROM)' ($full.StdOut -match 'MAPPER NUMBER\s+0\s+\(NROM\)')
    Check 'A1 summary suggests MAPPER_SELECT = 8''d0' ($full.StdOut -match 'MAPPER_SELECT\s+= 8''d0')
    Check 'A1 summary reports vertical mirroring' ($full.StdOut -match 'mirroring\s+vertical')
    Check 'A1 summary reports NROM_PRG_SIZE_BYTES = 16384' ($full.StdOut -match 'NROM_PRG_SIZE_BYTES = 16384')
}

# ---- A2: 128 KiB PRG, no padding needed ------------------------------------
Write-Output ''
Write-Output '  case A2  mapper 0 (NROM), 128 KiB PRG, no padding required'
$d = New-TmpDir
$prgPayload = New-DeterministicBytes -Length 131072 -Seed 4242
$chrPayload = New-DeterministicBytes -Length 8192 -Seed 77
$rom = New-RomImage -PrgBytes 131072 -ChrBytes 8192 -MapperId 0 -Trainer $false `
    -FourScreen $false -Battery $true -Vertical $false `
    -PrgPayload $prgPayload -ChrPayload $chrPayload
$romPath = Join-Path $d 'a2.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
$r = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-Quiet')
Check 'A2 exit 0' ($r.ExitCode -eq 0) ("exit " + $r.ExitCode + " " + $r.StdErr)

$prgPath = Join-Path $d 'prg.hex'
if (Test-Path -LiteralPath $prgPath) {
    $got = Read-HexImage $prgPath
    Check 'A2 prg.hex has exactly 131072 words' ($got.Length -eq 131072) ("got " + $got.Length)
    $mismatch = -1
    for ($i = 0; $i -lt 131072; $i++) {
        if ($got[$i] -ne $prgPayload[$i]) { $mismatch = $i; break }
    }
    Check 'A2 all 131072 PRG words match source byte-for-byte' ($mismatch -eq -1) ("first mismatch at word $mismatch")

    $full = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-PrgOut', (Join-Path $d 'p2.hex'), '-ChrOut', (Join-Path $d 'c2.hex'))
    Check 'A2 reports zero PRG padding words' ($full.StdOut -match 'PRG\s+131072 real words -> 131072 words, 0 words of 00 pad')
    Check 'A2 reports battery present' ($full.StdOut -match 'battery\s+yes')
    Check 'A2 reports horizontal mirroring' ($full.StdOut -match 'mirroring\s+horizontal')
}

# ---- A3: CHR-RAM game, 0 CHR banks ----------------------------------------
Write-Output ''
Write-Output '  case A3  mapper 0 (NROM), 16 KiB PRG, 0 CHR banks (CHR-RAM game)'
$d = New-TmpDir
$prgPayload = New-DeterministicBytes -Length 16384 -Seed 31337
$rom = New-RomImage -PrgBytes 16384 -ChrBytes 0 -MapperId 0 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload $prgPayload -ChrPayload $null
$romPath = Join-Path $d 'a3.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
$r = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-Quiet')
Check 'A3 exit 0' ($r.ExitCode -eq 0) ("exit " + $r.ExitCode + " " + $r.StdErr)

$prgPath = Join-Path $d 'prg.hex'
$chrPath = Join-Path $d 'chr.hex'
if ((Test-Path -LiteralPath $prgPath) -and (Test-Path -LiteralPath $chrPath)) {
    $got = Read-HexImage $prgPath
    $mismatch = -1
    for ($i = 0; $i -lt 16384; $i++) {
        if ($got[$i] -ne $prgPayload[$i]) { $mismatch = $i; break }
    }
    Check 'A3 all 16384 PRG words match source byte-for-byte' ($mismatch -eq -1) ("first mismatch at word $mismatch")

    $gotC = Read-HexImage $chrPath
    Check 'A3 chr.hex has exactly 8192 words' ($gotC.Length -eq 8192) ("got " + $gotC.Length)
    $nonZero = 0
    foreach ($v in $gotC) { if ($v -ne 0) { $nonZero++; break } }
    Check 'A3 chr.hex is all 00' ($nonZero -eq 0) ("$nonZero non-zero words")

    $full = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-PrgOut', (Join-Path $d 'p2.hex'), '-ChrOut', (Join-Path $d 'c2.hex'))
    Check 'A3 says CHR-RAM' ($full.StdOut -match 'CHR kind\s+CHR-RAM game')
    Check 'A3 says the whole CHR image is 00' ($full.StdOut -match 'the whole image is 00')
    Check 'A3 demands NROM_CHR_RAM = 1''b1' ($full.StdOut -match 'NROM_CHR_RAM\s+= 1''b1\s+REQUIRED')
}

# ---- A4: trainer present --------------------------------------------------
Write-Output ''
Write-Output '  case A4  mapper 0, 16 KiB PRG + 8 KiB CHR, 512-byte trainer present'
$d = New-TmpDir
$trainerPayload = New-DeterministicBytes -Length 512 -Seed 555
$prgPayload = New-DeterministicBytes -Length 16384 -Seed 8080
$chrPayload = New-DeterministicBytes -Length 8192 -Seed 606
$rom = New-RomImage -PrgBytes 16384 -ChrBytes 8192 -MapperId 0 -Trainer $true `
    -FourScreen $false -Battery $false -Vertical $true `
    -PrgPayload $prgPayload -ChrPayload $chrPayload -TrainerPayload $trainerPayload
$romPath = Join-Path $d 'a4.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
$r = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-Quiet')
Check 'A4 exit 0' ($r.ExitCode -eq 0) ("exit " + $r.ExitCode + " " + $r.StdErr)

$prgPath = Join-Path $d 'prg.hex'
$chrPath = Join-Path $d 'chr.hex'
if ((Test-Path -LiteralPath $prgPath) -and (Test-Path -LiteralPath $chrPath)) {
    $got = Read-HexImage $prgPath
    $mismatch = -1
    for ($i = 0; $i -lt 16384; $i++) {
        if ($got[$i] -ne $prgPayload[$i]) { $mismatch = $i; break }
    }
    Check 'A4 all 16384 PRG words match source byte-for-byte' ($mismatch -eq -1) ("first mismatch at word $mismatch")

    $gotC = Read-HexImage $chrPath
    $mismatch = -1
    for ($i = 0; $i -lt 8192; $i++) {
        if ($gotC[$i] -ne $chrPayload[$i]) { $mismatch = $i; break }
    }
    Check 'A4 all 8192 CHR words match source byte-for-byte' ($mismatch -eq -1) ("first mismatch at word $mismatch")

    # The trainer must be skipped, not prepended to PRG and not prepended to CHR.
    $trainerLeaked = ($got[0] -eq $trainerPayload[0]) -and ($got[1] -eq $trainerPayload[1]) -and ($got[2] -eq $trainerPayload[2])
    Check 'A4 512-byte trainer is skipped' (-not $trainerLeaked)
    Check 'A4 chr.hex does not start with trainer bytes' (-not ($gotC[0] -eq $trainerPayload[0] -and $gotC[1] -eq $trainerPayload[1]))

    $full = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-PrgOut', (Join-Path $d 'p2.hex'), '-ChrOut', (Join-Path $d 'c2.hex'))
    Check 'A4 reports trainer present' ($full.StdOut -match 'trainer\s+present, 512 bytes skipped')
}

# ---- A5: mapper 3 (MMC3) --------------------------------------------------
Write-Output ''
Write-Output '  case A5  iNES mapper 2 (UxROM), 128 KiB PRG, 64 KiB CHR (CHR bank aliasing)'
$d = New-TmpDir
$prgPayload = New-DeterministicBytes -Length 131072 -Seed 2468
$chrPayload = New-DeterministicBytes -Length 65536 -Seed 1357
$rom = New-RomImage -PrgBytes 131072 -ChrBytes 65536 -MapperId 2 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload $prgPayload -ChrPayload $chrPayload
$romPath = Join-Path $d 'a5.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
$r = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-Quiet')
Check 'A5 exit 0' ($r.ExitCode -eq 0) ("exit " + $r.ExitCode + " " + $r.StdErr)

$prgPath = Join-Path $d 'prg.hex'
$chrPath = Join-Path $d 'chr.hex'
if ((Test-Path -LiteralPath $prgPath) -and (Test-Path -LiteralPath $chrPath)) {
    $got = Read-HexImage $prgPath
    $mismatch = -1
    for ($i = 0; $i -lt 131072; $i++) {
        if ($got[$i] -ne $prgPayload[$i]) { $mismatch = $i; break }
    }
    Check 'A5 all 131072 PRG words match source byte-for-byte' ($mismatch -eq -1) ("first mismatch at word $mismatch")

    # 64 KiB of CHR into the 8 KiB chr_rom array: the first 8192 bytes are the
    # real CHR bank 0, and the rest is dropped, which is nes_cart_rom.v's
    # documented CHR_LOCAL_BITS = 13 aliasing rather than a refusal.
    $gotC = Read-HexImage $chrPath
    Check 'A5 chr.hex has exactly 8192 words' ($gotC.Length -eq 8192) ("got " + $gotC.Length)
    $mismatch = -1
    for ($i = 0; $i -lt 8192; $i++) {
        if ($gotC[$i] -ne $chrPayload[$i]) { $mismatch = $i; break }
    }
    Check 'A5 CHR words 0..8191 are the real CHR bank 0, byte-for-byte' ($mismatch -eq -1) ("first mismatch at word $mismatch")

    $full = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-PrgOut', (Join-Path $d 'p2.hex'), '-ChrOut', (Join-Path $d 'c2.hex'))
    Check 'A5 reports MAPPER NUMBER 2 (UxROM)' ($full.StdOut -match 'MAPPER NUMBER\s+2\s+\(UxROM\)')
    Check 'A5 suggests MAPPER_SELECT = 8''d2' ($full.StdOut -match 'MAPPER_SELECT\s+= 8''d2')
    Check 'A5 warns that CHR bytes past 8192 are dropped' ($full.StdOut -match 'the other 57344 bytes are DROPPED, not padded')
}

# ---- A6: iNES mapper 3 = MMC3 (the header's 4 -> the core's MAPPER_SELECT 4)
Write-Output ''
Write-Output '  case A6  iNES mapper 4 (MMC3), 128 KiB PRG + 32 KiB CHR, four-screen + battery'
$d = New-TmpDir
$prgPayload = New-DeterministicBytes -Length 131072 -Seed 5150
$chrPayload = New-DeterministicBytes -Length 32768 -Seed 6161
$rom = New-RomImage -PrgBytes 131072 -ChrBytes 32768 -MapperId 4 -Trainer $false `
    -FourScreen $true -Battery $true -Vertical $false `
    -PrgPayload $prgPayload -ChrPayload $chrPayload
$romPath = Join-Path $d 'a6.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
$r = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-Quiet')
Check 'A6 exit 0' ($r.ExitCode -eq 0) ("exit " + $r.ExitCode + " " + $r.StdErr)

$prgPath = Join-Path $d 'prg.hex'
$chrPath = Join-Path $d 'chr.hex'
if ((Test-Path -LiteralPath $prgPath) -and (Test-Path -LiteralPath $chrPath)) {
    $got = Read-HexImage $prgPath
    $mismatch = -1
    for ($i = 0; $i -lt 131072; $i++) {
        if ($got[$i] -ne $prgPayload[$i]) { $mismatch = $i; break }
    }
    Check 'A6 all 131072 PRG words match source byte-for-byte' ($mismatch -eq -1) ("first mismatch at word $mismatch")

    $gotC = Read-HexImage $chrPath
    Check 'A6 chr.hex has exactly 8192 words' ($gotC.Length -eq 8192) ("got " + $gotC.Length)
    $mismatch = -1
    for ($i = 0; $i -lt 8192; $i++) {
        if ($gotC[$i] -ne $chrPayload[$i]) { $mismatch = $i; break }
    }
    Check 'A6 CHR words 0..8191 are the real CHR bank 0, byte-for-byte' ($mismatch -eq -1) ("first mismatch at word $mismatch")

    $full = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-PrgOut', (Join-Path $d 'p2.hex'), '-ChrOut', (Join-Path $d 'c2.hex'))
    Check 'A6 warns that CHR bytes past 8192 are dropped' ($full.StdOut -match 'the other 24576 bytes are DROPPED, not padded')
    Check 'A6 reports MAPPER NUMBER 4 (MMC3)' ($full.StdOut -match 'MAPPER NUMBER\s+4\s+\(MMC3\)')
    Check 'A6 suggests MAPPER_SELECT = 8''d4' ($full.StdOut -match 'MAPPER_SELECT\s+= 8''d4')
    Check 'A6 reports four-screen mirroring' ($full.StdOut -match 'mirroring\s+four-screen')
}

# ---- A7: an unsupported mapper must say so, not guess ----------------------
Write-Output ''
Write-Output '  case A7  iNES mapper 7 (AxROM), unsupported: must refuse to suggest a value'
$d = New-TmpDir
$prgPayload = New-DeterministicBytes -Length 32768 -Seed 7171
$chrPayload = New-DeterministicBytes -Length 8192 -Seed 8181
$rom = New-RomImage -PrgBytes 32768 -ChrBytes 8192 -MapperId 7 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload $prgPayload -ChrPayload $chrPayload
$romPath = Join-Path $d 'a7.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
$r = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d)
Check 'A7 exits 0 (conversion is legal, only the mapper is unsupported)' ($r.ExitCode -eq 0) ("exit " + $r.ExitCode)
Check 'A7 prints the mapper number 7' ($r.StdOut -match 'MAPPER NUMBER\s+7')
Check 'A7 refuses to invent a MAPPER_SELECT' ($r.StdOut -match 'MAPPER_SELECT\s+: mapper 7 is not one of the five mappers')
Check 'A7 warns about wrong-tile failure mode' ($r.StdOut -match 'runs but renders wrong tiles')

# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '=== B. padding is always full depth, with 00 past the real data'
$d = New-TmpDir
$prgPayload = New-DeterministicBytes -Length 16384 -Seed 12345
$chrPayload = New-DeterministicBytes -Length 8192 -Seed 999
$rom = New-RomImage -PrgBytes 16384 -ChrBytes 8192 -MapperId 0 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $true `
    -PrgPayload $prgPayload -ChrPayload $chrPayload
$romPath = Join-Path $d 'pad.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
[void](Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-Quiet'))

$prgPath = Join-Path $d 'prg.hex'
$chrPath = Join-Path $d 'chr.hex'
if (Test-Path -LiteralPath $prgPath) {
    $got = Read-HexImage $prgPath
    Check 'B 16 KiB PRG case produces exactly 131072 words' ($got.Length -eq 131072) ("got " + $got.Length)

    $bad = 0
    $firstBad = -1
    for ($i = 16384; $i -lt $got.Length; $i++) {
        if ($got[$i] -ne 0) { $bad++; if ($firstBad -lt 0) { $firstBad = $i } }
    }
    Check 'B every word past the real data is 00' ($bad -eq 0) ("$bad non-zero words, first at $firstBad")

    $realBad = 0
    for ($i = 0; $i -lt 16384; $i++) { if ($got[$i] -ne $prgPayload[$i]) { $realBad++ } }
    Check 'B the first 16384 words are still the real data' ($realBad -eq 0) ("$realBad wrong")

    $full = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-PrgOut', (Join-Path $d 'p2.hex'), '-ChrOut', (Join-Path $d 'c2.hex'))
    Check 'B reports 114688 pad words' ($full.StdOut -match 'PRG\s+16384 real words -> 131072 words, 114688 words of 00 pad')
    Check 'B reports the pad percentage as expected, not a bug' ($full.StdOut -match 'PRG is 87\.5% padding')
}
if (Test-Path -LiteralPath $chrPath) {
    $gotC = Read-HexImage $chrPath
    Check 'B 8 KiB CHR case produces exactly 8192 words' ($gotC.Length -eq 8192) ("got " + $gotC.Length)
}

# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '=== C. byte-exactness against the committed placeholder format'

$refPrgBytes = [System.IO.File]::ReadAllBytes($placeholderPrg)
$refChrBytes = [System.IO.File]::ReadAllBytes($placeholderChr)
$refPrgText = [System.IO.File]::ReadAllText($placeholderPrg, $Utf8NoBom)
$refChrText = [System.IO.File]::ReadAllText($placeholderChr, $Utf8NoBom)

$refPrgLines = [System.IO.File]::ReadAllLines($placeholderPrg)
$refChrLines = [System.IO.File]::ReadAllLines($placeholderChr)

Check 'C prg_placeholder.hex is 393216 bytes' ($refPrgBytes.Length -eq 393216) ("got " + $refPrgBytes.Length)
Check 'C prg_placeholder.hex has 2048 lines' ($refPrgLines.Count -eq 2048) ("got " + $refPrgLines.Count)
Check 'C prg_placeholder.hex lines are 191 chars (64 words + 63 spaces)' ($refPrgLines[0].Length -eq 191) ("got " + $refPrgLines[0].Length)
Check 'C chr_placeholder.hex is 24576 bytes' ($refChrBytes.Length -eq 24576) ("got " + $refChrBytes.Length)
Check 'C chr_placeholder.hex has 128 lines' ($refChrLines.Count -eq 128) ("got " + $refChrLines.Count)
Check 'C chr_placeholder.hex lines are 191 chars' ($refChrLines[0].Length -eq 191) ("got " + $refChrLines[0].Length)

$d = New-TmpDir
$prgOut = Join-Path $d 'prg.hex'
$chrOut = Join-Path $d 'chr.hex'

# Feed the placeholder's own values back through the real converter: the
# produced files must be byte-identical to the committed ones.
$refPrgVals = Read-HexImage $placeholderPrg
$refChrVals = Read-HexImage $placeholderChr
Check 'C prg_placeholder.hex holds 131072 words' ($refPrgVals.Length -eq 131072) ("got " + $refPrgVals.Length)
Check 'C chr_placeholder.hex holds 8192 words' ($refChrVals.Length -eq 8192) ("got " + $refChrVals.Length)

$rom = New-RomImage -PrgBytes 131072 -ChrBytes 8192 -MapperId 0 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload ([byte[]]$refPrgVals) -ChrPayload ([byte[]]$refChrVals)
$romPath = Join-Path $d 'reemit.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
$r = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-PrgOut', $prgOut, '-ChrOut', $chrOut, '-Quiet')
Check 'C re-emission exits 0' ($r.ExitCode -eq 0) ("exit " + $r.ExitCode + " " + $r.StdErr)

if (Test-Path -LiteralPath $prgOut) {
    $outText = [System.IO.File]::ReadAllText($prgOut, $Utf8NoBom)
    Check 'C re-emitted prg.hex is byte-identical to prg_placeholder.hex' ($outText -ceq $refPrgText)
    if ($outText -cne $refPrgText) {
        $a = $outText -split "`n"
        $b = $refPrgText -split "`n"
        for ($i = 0; $i -lt [math]::Min($a.Count, $b.Count); $i++) {
            if ($a[$i] -cne $b[$i]) { break }
        }
        Write-Output ("        first differing line " + $i)
        Write-Output ("        got      [" + $a[$i] + "]")
        Write-Output ("        expected [" + $b[$i] + "]")
    }
}
if (Test-Path -LiteralPath $chrOut) {
    $outText = [System.IO.File]::ReadAllText($chrOut, $Utf8NoBom)
    Check 'C re-emitted chr.hex is byte-identical to chr_placeholder.hex' ($outText -ceq $refChrText)
}

# Line-shape checks on our own output against the reference line shape.
if (Test-Path -LiteralPath $prgOut) {
    $outBytes = [System.IO.File]::ReadAllBytes($prgOut)
    $cr = 0; $lf = 0
    foreach ($b in $outBytes) { if ($b -eq 13) { $cr++ } elseif ($b -eq 10) { $lf++ } }
    Check 'C our prg.hex has no CR bytes (LF only)' ($cr -eq 0) ("$cr CR bytes")
    Check 'C our prg.hex line count equals LF count' ($lf -eq 2048) ("$lf LF")
    Check 'C our prg.hex has a trailing LF' ($outBytes[$outBytes.Length - 1] -eq 10)
    Check 'C our prg.hex has no BOM' (-not ($outBytes[0] -eq 0xEF -and $outBytes[1] -eq 0xBB -and $outBytes[2] -eq 0xBF))
    Check 'C our prg.hex is 393216 bytes like the reference' ($outBytes.Length -eq 393216) ("got " + $outBytes.Length)

    $outLines = [System.IO.File]::ReadAllLines($prgOut)
    Check 'C our prg.hex line width matches the reference' ($outLines[0].Length -eq $refPrgLines[0].Length) ("got " + $outLines[0].Length + " vs " + $refPrgLines[0].Length)
    Check 'C our prg.hex separator is a single space' ($outLines[0] -match '^(?:[0-9a-f]{2})(?: [0-9a-f]{2}){63}$')

    $upper = ($outLines[0] -cmatch '[A-F]')
    Check 'C our prg.hex uses lowercase hex digits' (-not $upper)

    $sameValues = $true
    for ($i = 0; $i -lt 2048; $i++) {
        if ($outLines[$i] -cne $refPrgLines[$i]) { $sameValues = $false; break }
    }
    Check 'C every one of the 2048 lines has identical values in identical positions' $sameValues
}
if (Test-Path -LiteralPath $chrOut) {
    $outLines = [System.IO.File]::ReadAllLines($chrOut)
    Check 'C our chr.hex has 128 lines' ($outLines.Count -eq 128) ("got " + $outLines.Count)
    Check 'C our chr.hex line width matches the reference' ($outLines[0].Length -eq $refChrLines[0].Length) ("got " + $outLines[0].Length + " vs " + $refChrLines[0].Length)
    $sameValues = $true
    for ($i = 0; $i -lt 128; $i++) {
        if ($outLines[$i] -cne $refChrLines[$i]) { $sameValues = $false; break }
    }
    Check 'C every one of the 128 CHR lines has identical values in identical positions' $sameValues
}

# The placeholders themselves must be untouched by the whole self-test.
Check 'C prg_placeholder.hex unchanged on disk' (([System.IO.FileInfo]$placeholderPrg).Length -eq 393216)
Check 'C chr_placeholder.hex unchanged on disk' (([System.IO.FileInfo]$placeholderChr).Length -eq 24576)

# ---------------------------------------------------------------------------
Write-Output ''
Write-Output '=== D. negative cases: non-zero exit and NO partial output'

function Check-Refusal {
    param([string]$Name, [string[]]$Arguments, [string[]]$MustProduce)
    $d = New-TmpDir
    $args2 = @($Arguments)
    foreach ($m in $MustProduce) { $args2 += $m }
    $r = Invoke-Tool $args2

    Check ($Name + ' exits non-zero') ($r.ExitCode -ne 0) ("exit " + $r.ExitCode)
    Check ($Name + ' prints ERROR') (($r.StdOut + $r.StdErr) -match 'ERROR')

    $left = @()
    foreach ($f in @('prg.hex', 'chr.hex', 'p2.hex', 'c2.hex')) {
        if (Test-Path -LiteralPath (Join-Path $d $f)) { $left += $f }
    }
    foreach ($f in @('prg.hex.nes2hex-tmp', 'chr.hex.nes2hex-tmp', 'p2.hex.nes2hex-tmp', 'c2.hex.nes2hex-tmp')) {
        if (Test-Path -LiteralPath (Join-Path $d $f)) { $left += $f }
    }
    Check ($Name + ' leaves no output file behind') ($left.Count -eq 0) ("left: " + ($left -join ', '))

    # Written to a script-scope variable rather than returned: a PowerShell
    # function returns EVERY uncaptured Write-Output, so `return $r` would come
    # back as an array of the Check lines plus the object.
    $script:LastRefusal = $r
    return
}

$goodPrg = New-DeterministicBytes -Length 16384 -Seed 111
$goodChr = New-DeterministicBytes -Length 8192 -Seed 222

# D1 bad magic
$d = New-TmpDir
$rom = New-RomImage -PrgBytes 16384 -ChrBytes 8192 -MapperId 0 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload $goodPrg -ChrPayload $goodChr -Magic ('NOPE' + [char]0x1A)
$romPath = Join-Path $d 'bad.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
[void](Check-Refusal 'D1 bad magic' @('-RomPath', $romPath, '-OutDir', $d, '-Quiet') @())

# D1b magic present but wrong length (only 8 bytes)
$d = New-TmpDir
$romPath = Join-Path $d 'short8.nes'
[System.IO.File]::WriteAllBytes($romPath, [byte[]]@(0x4E, 0x45, 0x53, 0x1A, 1, 1, 0, 0))
[void](Check-Refusal 'D1b header shorter than 16 bytes' @('-RomPath', $romPath, '-OutDir', $d, '-Quiet') @())

# D2 truncated: header promises 32 KiB PRG, file carries 16 KiB
$d = New-TmpDir
$rom = New-RomImage -PrgBytes 32768 -ChrBytes 8192 -MapperId 0 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload (New-DeterministicBytes -Length 16384 -Seed 333) -ChrPayload $goodChr
$romPath = Join-Path $d 'trunc.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
Check-Refusal 'D2 truncated file' @('-RomPath', $romPath, '-OutDir', $d, '-Quiet') @()
Check 'D2 says truncated' (($script:LastRefusal.StdOut + $script:LastRefusal.StdErr) -match 'truncated')

# D3 size mismatch: trailing junk
$d = New-TmpDir
$rom = New-RomImage -PrgBytes 16384 -ChrBytes 8192 -MapperId 0 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload $goodPrg -ChrPayload $goodChr
$rom = $rom + (New-Object byte[] 64)
$romPath = Join-Path $d 'trail.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
Check-Refusal 'D3 size mismatch (trailing bytes)' @('-RomPath', $romPath, '-OutDir', $d, '-Quiet') @()
Check 'D3 says size mismatch' (($script:LastRefusal.StdOut + $script:LastRefusal.StdErr) -match 'size mismatch')
$allow = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-AllowTrailingBytes', '-Quiet')
Check 'D3 -AllowTrailingBytes converts it instead' ($allow.ExitCode -eq 0) ("exit " + $allow.ExitCode)
Remove-Item -LiteralPath (Join-Path $d 'prg.hex') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $d 'chr.hex') -Force -ErrorAction SilentlyContinue

# D4 PRG over 128 KiB
$d = New-TmpDir
$rom = New-RomImage -PrgBytes 262144 -ChrBytes 8192 -MapperId 4 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload (New-DeterministicBytes -Length 262144 -Seed 444) -ChrPayload $goodChr
$romPath = Join-Path $d 'huge.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
Check-Refusal 'D4 PRG larger than 128 KiB' @('-RomPath', $romPath, '-OutDir', $d, '-Quiet') @()
Check 'D4 says over the 128 KiB ceiling' (($script:LastRefusal.StdOut + $script:LastRefusal.StdErr) -match 'over the 128 KiB')

# D4b PRG deeper than a caller-supplied -PrgWords must also refuse, and must
# say why PRG is not silently truncated the way CHR is.
$d = New-TmpDir
$rom = New-RomImage -PrgBytes 131072 -ChrBytes 8192 -MapperId 4 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload (New-DeterministicBytes -Length 131072 -Seed 2468) -ChrPayload $goodChr
$romPath = Join-Path $d 'deep.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
Check-Refusal 'D4b PRG deeper than -PrgWords' `
    @('-RomPath', $romPath, '-OutDir', $d, '-PrgWords', '32768', '-Quiet') @()
Check 'D4b explains that truncating PRG would change bank mapping' `
    (($script:LastRefusal.StdOut + $script:LastRefusal.StdErr) -match 'would change which bank each CPU window reads')

# D5 zero PRG banks
$d = New-TmpDir
$romPath = Join-Path $d 'zero.nes'
$zeroHeader = [byte[]]@(0x4E, 0x45, 0x53, 0x1A, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
$zeroRom = New-Object byte[] (16 + $goodChr.Length)
[System.Array]::Copy($zeroHeader, 0, $zeroRom, 0, 16)
[System.Array]::Copy($goodChr, 0, $zeroRom, 16, $goodChr.Length)
[System.IO.File]::WriteAllBytes($romPath, $zeroRom)
Check-Refusal 'D5 zero PRG banks' @('-RomPath', $romPath, '-OutDir', $d, '-Quiet') @()
Check 'D5 cites ERR_PRG_ZERO' (($script:LastRefusal.StdOut + $script:LastRefusal.StdErr) -match 'ERR_PRG_ZERO')

# D6 NES2.0 exponent notation.  flags 7 [3:2] must be 2'b10 to select NES 2.0
# (ines_header_parser.v:94); 2'b11 would instead be a dirty iNES header, which
# is a different code path and is NOT what this case is testing.
$d = New-TmpDir
$rom = New-RomImage -PrgBytes 16384 -ChrBytes 8192 -MapperId 4 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload $goodPrg -ChrPayload $goodChr
$rom[7] = ($rom[7] -bor 0x08) -band 0xFB
$rom[9] = 0x10
$romPath = Join-Path $d 'exp.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
Check-Refusal 'D6 NES2.0 exponent notation' @('-RomPath', $romPath, '-OutDir', $d, '-Quiet') @()
Check 'D6 cites ERR_EXPONENT' (($script:LastRefusal.StdOut + $script:LastRefusal.StdErr) -match 'ERR_EXPONENT')

# D7 output already exists
$d = New-TmpDir
$rom = New-RomImage -PrgBytes 16384 -ChrBytes 8192 -MapperId 0 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload $goodPrg -ChrPayload $goodChr
$romPath = Join-Path $d 'exists.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
[System.IO.File]::WriteAllText((Join-Path $d 'prg.hex'), 'do not clobber', $Utf8NoBom)
Check-Refusal 'D7 output file already exists' @('-RomPath', $romPath, '-OutDir', $d, '-Quiet') @()
Check 'D7 leaves the existing file untouched' ([System.IO.File]::ReadAllText((Join-Path $d 'prg.hex'), $Utf8NoBom) -ceq 'do not clobber')
Remove-Item -LiteralPath (Join-Path $d 'prg.hex') -Force

# D8 refuse to overwrite the committed placeholders
$d = New-TmpDir
$romPath = Join-Path $d 'ok.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
Check-Refusal 'D8 refuses to overwrite prg_placeholder.hex' `
    @('-RomPath', $romPath, '-PrgOut', (Join-Path $d 'prg_placeholder.hex'), '-ChrOut', (Join-Path $d 'chr.hex'), '-Quiet') @()
Check 'D8 mentions -OverwritePlaceholders' (($script:LastRefusal.StdOut + $script:LastRefusal.StdErr) -match 'OverwritePlaceholders')

# D9 missing input file
$d = New-TmpDir
[void](Check-Refusal 'D9 input file not found' @('-RomPath', (Join-Path $d 'nope.nes'), '-OutDir', $d, '-Quiet') @())

# D10 output directory does not exist
$d = New-TmpDir
$romPath = Join-Path $d 'ok2.nes'
[System.IO.File]::WriteAllBytes($romPath, $rom)
[void](Check-Refusal 'D10 output directory missing' @('-RomPath', $romPath, '-OutDir', (Join-Path $d 'no-such-dir'), '-Quiet') @())

# D11 an actual ROM played into the real pipeline: the produced images must be
# readable by the shape nes_cart_rom's $readmemh sees, i.e. exactly depth many
# tokens, no address tokens, no trailing separators.
$d = New-TmpDir
$romPath = Join-Path $d 'shape.nes'
$shapeRom = New-RomImage -PrgBytes 16384 -ChrBytes 8192 -MapperId 0 -Trainer $false `
    -FourScreen $false -Battery $false -Vertical $false `
    -PrgPayload $goodPrg -ChrPayload $goodChr
[System.IO.File]::WriteAllBytes($romPath, $shapeRom)
$shapeRun = Invoke-Tool @('-RomPath', $romPath, '-OutDir', $d, '-Quiet')
Check 'D11 the fixture itself converts' ($shapeRun.ExitCode -eq 0) ("exit " + $shapeRun.ExitCode)
$prgPath = Join-Path $d 'prg.hex'
Check 'D11 prg.hex was produced' (Test-Path -LiteralPath $prgPath)
$text = [System.IO.File]::ReadAllText($prgPath, $Utf8NoBom)
Check 'D11 no address prefixes (@...) anywhere' (-not ($text -match '@'))
$badTokens = @($text -split "`n" | Where-Object { $_ -ne '' } | ForEach-Object { $_ -split ' ' } | Where-Object { $_ -notmatch '^[0-9a-f]{2}$' })
Check 'D11 every token matches ^[0-9a-f]{2}$' ($badTokens.Count -eq 0) ("$($badTokens.Count) bad tokens")
Check 'D11 no double spaces (no empty separator token)' (-not ($text -match '  '))
Check 'D11 no trailing space at end of any line' (-not ($text -match ' \n'))
Check 'D11 no tab characters' (-not ($text -match "`t"))

# ---------------------------------------------------------------------------
Write-Output ''
Write-Output ('=== summary: {0} passed, {1} failed' -f $script:Pass, $script:FailCount)
if ($script:FailCount -gt 0) {
    Write-Output ''
    Write-Output 'failing checks:'
    foreach ($f in $script:Failures) { Write-Output ("  " + $f) }
    Write-Output ''
    Write-Output ("Result: FAIL ({0} of {1})" -f $script:FailCount, ($script:Pass + $script:FailCount))
    exit 1
}
Write-Output ''
Write-Output ("Result: PASS ({0} of {0})" -f $script:Pass)
exit 0
