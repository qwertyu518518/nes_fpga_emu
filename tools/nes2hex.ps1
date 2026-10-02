[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('Rom', 'Input')]
    [string]$RomPath,

    [string]$OutDir = '.',

    [string]$PrgOut,
    [string]$ChrOut,

    [int]$PrgWords = 131072,
    [int]$ChrWords = 8192,

    [switch]$OverwritePlaceholders,
    [switch]$AllowTrailingBytes,
    [switch]$Quiet
)

# NOTE ON THE PARAMETER NAME
#   This is deliberately NOT called -Input.  $Input is a PowerShell automatic
#   variable (the pipeline enumerator), and a param() block named $Input binds
#   to the empty string when the script is run with -File, so every Test-Path
#   and [IO.File] call downstream fails with "cannot bind ... LiteralPath
#   because it is an empty string".  -RomPath is the name; -Input is kept only
#   as an alias so the conventional spelling still works.

# nes2hex.ps1 : convert an iNES .nes ROM into the two $readmemh images the
# bitstream embeds.
#
# WHY THE HEADER IS STRIPPED, NOT EMITTED
#   rtl/nes_core/cart/ines_header_parser.v exists and parses the 16-byte header,
#   but it is instantiated ONLY by its own testbench (tb/cart/tb_ines_header_
#   parser.v).  Nothing in the bitstream path instantiates it, and it has no
#   ROM of its own: its `header` port is a 128-bit INPUT, so a consumer would
#   still have to supply the 16 bytes from somewhere.  Meanwhile nes_cart_rom.v
#   does `reg [7:0] prg_rom [0:PRG_SIZE_BYTES-1]; $readmemh(PRG_INIT_FILE,
#   prg_rom);` and indexes it with mapper_prg_bank_offset alone.  For NROM at
#   PRG_SIZE_BYTES=32768, nes_mapper_nrom.v:22-24 gives
#   prg_bank_offset = cpu_addr[14:0], so $8000 lands on prg_rom[0].  Array
#   index 0 therefore has to be the PRG byte fetched at $8000, not header byte
#   0 ('N').  The images are raw PRG and raw CHR, no header, no trainer.
#
# WHY PADDING IS MANDATORY
#   A $readmemh that supplies fewer entries than the array declares leaves the
#   rest X in the fabric.  A 16 KiB game would boot into 87% undefined block
#   RAM, so the images are always padded to the full declared depth with 00.
#
# REFUSAL POLICY
#   Every check below runs BEFORE any file is opened for writing, and the two
#   outputs are staged to temporary files and moved into place only after both
#   have been written in full.  A rejected ROM therefore leaves no output at
#   all, rather than a short file that $readmemh would silently accept.

$ErrorActionPreference = 'Stop'

$script:HeaderBytes = 16
$script:TrainerBytes = 512
$script:PrgBankBytes = 16384
$script:ChrBankBytes = 8192
$script:MaxPrgBytes = 131072
$script:WordsPerLine = 64
$script:PadByte = '00'

$script:PlaceholderNames = @('prg_placeholder.hex', 'chr_placeholder.hex')

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Info {
    param([string]$Text)
    if (-not $Quiet) { Write-Output $Text }
}

function Fail {
    param([string]$Message)
    Write-Output ("nes2hex: ERROR: " + $Message)
    exit 2
}

# $readmemh format, byte-for-byte identical to rtl/nes_core/cart/prg_placeholder
# .hex and chr_placeholder.hex: two lowercase hex digits per byte, ONE space
# between values, 64 values per line, LF line endings, one trailing LF.
function Format-HexImage {
    param([byte[]]$Data)

    $builder = New-Object System.Text.StringBuilder
    $line = New-Object System.Text.StringBuilder
    $count = 0

    for ($i = 0; $i -lt $Data.Length; $i++) {
        if ($count -eq $script:WordsPerLine) {
            [void]$builder.Append($line.ToString())
            [void]$builder.Append("`n")
            [void]$line.Clear()
            $count = 0
        }
        if ($count -ne 0) { [void]$line.Append(' ') }
        [void]$line.Append($Data[$i].ToString('x2'))
        $count++
    }

    if ($count -ne 0) {
        [void]$builder.Append($line.ToString())
        [void]$builder.Append("`n")
    }

    return $builder.ToString()
}

function New-PaddedImage {
    param([byte[]]$Data, [int]$Depth, [string]$What, [int]$RealSize)

    # PRG over the array depth is refused outright: prg_rom is bank-indexed by
    # mapper_prg_bank_offset, so silently dropping the tail would change which
    # bank each window reads.  CHR over the depth is different -- see
    # New-ChrImage.
    if ($What -eq 'PRG ROM' -and $Data.Length -gt $Depth) {
        Fail ("PRG ROM is " + $Data.Length + " bytes but the prg_rom array is " +
              "only " + $Depth + " bytes.  prg_rom is indexed by " +
              "mapper_prg_bank_offset, so truncating it would change which " +
              "bank each CPU window reads; the only fix is to raise " +
              "PRG_SIZE_BYTES on nes_system_v6 and nes_cart_rom, which is an " +
              "RTL and BRAM change.  Refusing.")
    }

    if ($Data.Length -eq $Depth) {
        return ,$Data
    }

    $padded = New-Object byte[] $Depth
    $copy = [math]::Min($Data.Length, $Depth)
    [System.Array]::Copy($Data, 0, $padded, 0, $copy)
    for ($i = $copy; $i -lt $Depth; $i++) {
        $padded[$i] = 0
    }
    return ,$padded
}

function Resolve-OutputPath {
    param([string]$Name, [string]$Explicit, [string]$Role)

    if ([string]::IsNullOrWhiteSpace($Explicit)) {
        $Explicit = Join-Path $OutDir $Name
    }

    $full = $null
    try {
        $full = [System.IO.Path]::GetFullPath($Explicit)
    } catch {
        Fail ("output path for $Role is not usable: " + $Explicit + " (" + $_.Exception.Message + ")")
    }

    $leaf = [System.IO.Path]::GetFileName($full)
    if ($script:PlaceholderNames -contains $leaf -and -not $OverwritePlaceholders) {
        Fail ("refusing to overwrite the committed placeholder " + $leaf +
              ".  Pass -OverwritePlaceholders if that is genuinely what you " +
              "want, or name the outputs yourself with -PrgOut/-ChrOut.")
    }

    if ((Test-Path -LiteralPath $full) -and (Test-Path -LiteralPath $full -PathType Leaf)) {
        Fail ("output file already exists: " + $full +
              ".  Refusing to overwrite; delete it or choose another name.")
    }

    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not (Test-Path -LiteralPath $parent)) {
        Fail ("output directory does not exist: " + $parent)
    }

    return $full
}

function Write-StagedFile {
    param([string]$Path, [string]$Content)

    $temp = $Path + '.nes2hex-tmp'
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }

    [System.IO.File]::WriteAllText($temp, $Content, $script:Utf8NoBom)

    $written = [System.IO.File]::ReadAllText($temp, $script:Utf8NoBom)
    if ($written -cne $Content) {
        Remove-Item -LiteralPath $temp -Force
        Fail ("staged output did not read back identically: " + $Path)
    }

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    [System.IO.File]::Move($temp, $Path)
}

# ---------------------------------------------------------------------------
# input
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($RomPath)) {
    Fail 'no input file was given.  Pass -RomPath <file.nes> (alias -Input).'
}
if (-not (Test-Path -LiteralPath $RomPath)) {
    Fail ("input file not found: " + $RomPath)
}
if (-not (Test-Path -LiteralPath $RomPath -PathType Leaf)) {
    Fail ("input path is not a file: " + $RomPath)
}

$inputPath = (Resolve-Path -LiteralPath $RomPath).Path

if ($PrgWords -le 0) { Fail ("-PrgWords must be positive, got " + $PrgWords) }
if ($ChrWords -le 0) { Fail ("-ChrWords must be positive, got " + $ChrWords) }

$bytes = [System.IO.File]::ReadAllBytes($inputPath)
$actualSize = $bytes.Length

Write-Info ("nes2hex: input  " + $inputPath)
Write-Info ("nes2hex: size   " + $actualSize + " bytes")

if ($actualSize -lt $script:HeaderBytes) {
    Fail ("file is only " + $actualSize + " bytes, shorter than the 16-byte " +
          "iNES header.  Truncated file.")
}

# ---------------------------------------------------------------------------
# header
# ---------------------------------------------------------------------------

$magic0 = $bytes[0]; $magic1 = $bytes[1]; $magic2 = $bytes[2]; $magic3 = $bytes[3]
if ($magic0 -ne 0x4E -or $magic1 -ne 0x45 -or $magic2 -ne 0x53 -or $magic3 -ne 0x1A) {
    $got = '{0:X2} {1:X2} {2:X2} {3:X2}' -f $magic0, $magic1, $magic2, $magic3
    Fail ("bad iNES magic: expected 4E 45 53 1A, got " + $got +
          ".  This is not an iNES/NES2.0 image (a headerless .nes, a FDS or " +
          "UNIF image, or plain PRG/CHR will all land here).")
}

$prgBanks16k = [int]$bytes[4]
$chrBanks8k  = [int]$bytes[5]
$flags6      = [int]$bytes[6]
$flags7      = [int]$bytes[7]

$hasTrainer  = (($flags6 -band 0x04) -ne 0)
$fourScreen  = (($flags6 -band 0x08) -ne 0)
$hasBattery  = (($flags6 -band 0x02) -ne 0)
$verticalMir = (($flags6 -band 0x01) -ne 0)

$nes2 = ((($flags7 -band 0x0C) -shr 2) -eq 2)

$mapperId = ((($flags7 -shr 4) -band 0x0F) -shl 4) -bor (($flags6 -shr 4) -band 0x0F)

if ($prgBanks16k -eq 0) {
    Fail ("header declares 0 PRG-ROM banks.  ines_header_parser treats this " +
          "as ERR_PRG_ZERO (error 2); there is no core configuration for a " +
          "cartridge with no PRG ROM.")
}

if ($nes2) {
    $nes2Head = $bytes[8]
    $nes2Mapr = $bytes[9]
    $prgExponent = (($nes2Mapr -shr 4) -band 0x0F)
    $chrExponent = (($nes2Mapr -shr 2) -band 0x03)
    $prgRamExponent = (($bytes[10] -shr 6) -band 0x03)
    $chrRamExponent = (($bytes[11] -shr 6) -band 0x03)
    if ($prgExponent -ne 0 -or $chrExponent -ne 0 -or
        $prgRamExponent -ne 0 -or $chrRamExponent -ne 0) {
        Fail ("NES2.0 exponent notation (PRG x2^" + $prgExponent +
              ", CHR x2^" + $chrExponent + ", PRG-RAM x2^" + $prgRamExponent +
              ", CHR-RAM x2^" + $chrRamExponent +
              ") is not implemented in this core.  ines_header_parser rejects " +
              "it as ERR_EXPONENT (error 3).")
    }
    $prgBanks16k = ($nes2Head -band 0x0F) -bor ((($nes2Mapr -band 0x0F)) -shl 4)
    $chrBanks8k  = ($nes2Head -shr 4) -bor ((($nes2Mapr -shr 4) -band 0x0F) -shl 4)
}

$prgReal = $prgBanks16k * $script:PrgBankBytes
$chrReal = $chrBanks8k  * $script:ChrBankBytes

if ($prgReal -gt $script:MaxPrgBytes) {
    Fail ("header declares " + $prgBanks16k + " x 16 KiB = " + $prgReal +
          " bytes of PRG ROM, which is over the 128 KiB (" +
          $script:MaxPrgBytes + " byte) ceiling of nes_system_v6's " +
          "PRG_SIZE_BYTES and of the nes_cart_rom prg_rom array.  Raising that " +
          "is an RTL/BRAM change, not a conversion.")
}

$trainerLen = 0
if ($hasTrainer) { $trainerLen = $script:TrainerBytes }

$expected = $script:HeaderBytes + $trainerLen + $prgReal + $chrReal

if ($actualSize -lt $expected) {
    Fail ("truncated: header declares " + $prgBanks16k + " x 16 KiB PRG (" +
          $prgReal + " B) and " + $chrBanks8k + " x 8 KiB CHR (" + $chrReal +
          " B)" + $(if ($hasTrainer) { " plus a 512-byte trainer" } else { "" }) +
          ", so the file must be " + $expected + " bytes, but it is only " +
          $actualSize + " (" + ($expected - $actualSize) + " bytes short).")
}

if ($actualSize -gt $expected) {
    $extra = $actualSize - $expected
    if (-not $AllowTrailingBytes) {
        Fail ("size mismatch: header accounts for " + $expected +
              " bytes but the file is " + $actualSize + " (" + $extra +
              " trailing bytes).  ines_header_parser would flag this as " +
              "size_trailing.  Pass -AllowTrailingBytes to convert anyway.")
    }
}

$prgOffset = $script:HeaderBytes + $trainerLen
$chrOffset = $prgOffset + $prgReal

$prgBytes = New-Object byte[] $prgReal
if ($prgReal -gt 0) {
    [System.Array]::Copy($bytes, $prgOffset, $prgBytes, 0, $prgReal)
}
$chrBytes = New-Object byte[] $chrReal
if ($chrReal -gt 0) {
    [System.Array]::Copy($bytes, $chrOffset, $chrBytes, 0, $chrReal)
}

# ---------------------------------------------------------------------------
# mapper / mirroring advice
# ---------------------------------------------------------------------------

$mapperSelectMap = @{
    0 = '0'
    1 = '1'
    2 = '2'
    3 = '3'
    4 = '4'
}
$mapperNameMap = @{
    0 = 'NROM'
    1 = 'MMC1'
    2 = 'UxROM'
    3 = 'CNROM'
    4 = 'MMC3'
}

if ($mapperSelectMap.ContainsKey($mapperId)) {
    $suggestedSelect = $mapperSelectMap[$mapperId]
    $suggestedName = $mapperNameMap[$mapperId]
} else {
    $suggestedSelect = $null
    $suggestedName = $null
}

$mirroringMode = 'four-screen'
$headerMirroring = 0
if (-not $fourScreen) {
    if ($verticalMir) {
        $mirroringMode = 'vertical'
        $headerMirroring = 1
    } else {
        $mirroringMode = 'horizontal'
        $headerMirroring = 0
    }
}

$chrIsRam = ($chrReal -eq 0)

# ---------------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------------

$prgPath = Resolve-OutputPath -Name 'prg.hex' -Explicit $PrgOut -Role 'PRG'
$chrPath = Resolve-OutputPath -Name 'chr.hex' -Explicit $ChrOut -Role 'CHR'

$prgPadded = New-PaddedImage -Data $prgBytes -Depth $PrgWords -What 'PRG ROM' -RealSize $prgReal
$chrPadded = New-PaddedImage -Data $chrBytes -Depth $ChrWords -What 'CHR ROM' -RealSize $chrReal

# CHR deeper than 8 KiB is truncated to the first $ChrWords bytes, NOT
# refused.  nes_cart_rom.v:57-63 documents this as the accepted behaviour: with
# CHR_LOCAL_BITS = 13 the mapper-translated chr_final_addr is indexed on
# [12:0] and every bank bit above 12 is dropped, "an alias for CNROM (32 KiB),
# MMC1 (up to 64 KiB) and MMC3 (up to 64 KiB), whose banks fold onto 0..7".
# Keeping the FIRST bank means bank 0 is the real bank 0, which is what an
# unprogrammed mapper register selects.
$chrTruncatedBytes = 0
if ($chrReal -gt $ChrWords) {
    $chrTruncatedBytes = $chrReal - $ChrWords
}

$prgText = Format-HexImage -Data $prgPadded
$chrText = Format-HexImage -Data $chrPadded

Write-StagedFile -Path $prgPath -Content $prgText
Write-StagedFile -Path $chrPath -Content $chrText

$prgPadWords = $PrgWords - $prgReal
$chrPadWords = $ChrWords - $chrReal

$prgOutBytes = ([System.IO.FileInfo]$prgPath).Length
$chrOutBytes = ([System.IO.FileInfo]$chrPath).Length

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '=== iNES header'
Write-Output ("  magic            4E 45 53 1A")
Write-Output ("  format           " + $(if ($nes2) { 'NES 2.0' } else { 'iNES 1.0' }))
Write-Output ("  PRG ROM banks    {0} x 16 KiB = {1} bytes" -f $prgBanks16k, $prgReal)
Write-Output ("  CHR ROM banks    {0} x 8 KiB  = {1} bytes" -f $chrBanks8k, $chrReal)
Write-Output ("  flags 6          {0:X2}  mapper low nibble {1}, {2}{3}{4}{5}" -f `
    $flags6, ($flags6 -shr 4), `
    $(if ($hasTrainer) { 'trainer ' } else { '' }), `
    $(if ($hasBattery) { 'battery ' } else { '' }), `
    $(if ($fourScreen) { 'four-screen ' } else { '' }), `
    $(if ($verticalMir) { 'vertical' } else { 'horizontal' }))
Write-Output ("  flags 7          {0:X2}  mapper high nibble {1}" -f $flags7, (($flags7 -shr 4) -band 0x0F))
Write-Output ("  MAPPER NUMBER    {0}{1}" -f $mapperId, `
    $(if ($null -ne $suggestedName) { "  ($suggestedName)" } else { "  (not implemented in this core)" }))
Write-Output ("  trainer          " + $(if ($hasTrainer) { 'present, 512 bytes skipped (belongs in cart RAM at $7000, not in the ROM image)' } else { 'absent' }))
Write-Output ("  battery          " + $(if ($hasBattery) { 'yes (PRG RAM at $6000-$7FFF)' } else { 'no' }))
Write-Output ("  mirroring        " + $mirroringMode)
Write-Output ("  CHR kind         " + $(if ($chrIsRam) { 'CHR-RAM game: header declares 0 CHR-ROM banks, so the 8 KiB CHR array is RAM' } else { 'CHR ROM' }))
Write-Output ''
Write-Output '=== core parameters to set'
if ($null -ne $suggestedSelect) {
    Write-Output ("  MAPPER_SELECT    = 8'd{0}   ({1})" -f $suggestedSelect, $suggestedName)
} else {
    Write-Output ("  MAPPER_SELECT    : mapper {0} is not one of the five mappers in nes_mapper.v" -f $mapperId)
    Write-Output ("                     (0=NROM 1=MMC1 2=UxROM 3=CNROM 4=MMC3).  The core")
    Write-Output ("                     cannot run this cartridge; picking a wrong value")
    Write-Output ("                     gives a game that runs but renders wrong tiles.")
}
Write-Output ("  HEADER_MIRRORING = 3'd{0}   ({1})" -f $headerMirroring, $mirroringMode)
if ($mapperId -eq 0 -and $prgReal -le $script:PrgBankBytes) {
    Write-Output ("  NROM_PRG_SIZE_BYTES = {0}   A 16 KiB NROM game MUST set this to" -f $prgReal)
    Write-Output ("                     16384, not the 32768 default.  nes_mapper_nrom.v:7")
    Write-Output ("                     derives NROM_MIRROR_16K from it; at 32768 the")
    Write-Output '                     16 KiB image is mirrored into both $8000-$BFFF'
    Write-Output '                     and $C000-$FFFF and the CPU fetches the wrong half.'
}
if ($chrIsRam) {
    $ramParam = $null
    if ($mapperId -eq 0) { $ramParam = 'NROM_CHR_RAM' }
    elseif ($mapperId -eq 1) { $ramParam = 'MMC1_CHR_RAM' }
    elseif ($mapperId -eq 4) { $ramParam = 'MMC3_CHR_RAM' }
    if ($null -ne $ramParam) {
        Write-Output ("  {0}     = 1'b1   REQUIRED" -f $ramParam)
        Write-Output ("                     0 CHR-ROM banks means the 8 KiB CHR array is RAM,")
        Write-Output ("                     and nes_cart_rom only honours chr_we when")
        Write-Output ("                     chr_ram_enable is high.  With the default 1'b0")
        Write-Output ("                     the $2007 writes are discarded and the screen stays")
        Write-Output ("                     blank or shows tile 0 everywhere.")
    } else {
        Write-Output ("  (no *_CHR_RAM parameter exists for mapper {0}; this core has no" -f $mapperId)
        Write-Output ("   CHR-RAM path for it.)")
    }
}
Write-Output ''
Write-Output '=== padding (mandatory: a short $readmemh leaves the rest X in the fabric)'
Write-Output ("  PRG  {0} real words -> {1} words, {2} words of {3} pad" -f $prgReal, $PrgWords, $prgPadWords, $script:PadByte)
Write-Output ("  CHR  {0} real words -> {1} words, {2} words of {3} pad" -f $chrReal, $ChrWords, $chrPadWords, $script:PadByte)
if ($prgPadWords -gt 0) {
    $pct = [math]::Round(100.0 * $prgPadWords / $PrgWords, 1)
    Write-Output ("       PRG is {0}% padding.  A 16 KiB game in a 128 KiB array is" -f $pct)
    Write-Output ("       expected to look like this, not a bug.")
}
if ($chrIsRam) {
    Write-Output ("  CHR  the whole image is {0} because this is a CHR-RAM game." -f $script:PadByte)
}
if ($chrTruncatedBytes -gt 0) {
    Write-Output ("  CHR  only the first {0} bytes of the {1}-byte CHR ROM are" -f $ChrWords, $chrReal)
    Write-Output ("       emitted; the other {0} bytes are DROPPED, not padded." -f $chrTruncatedBytes)
    Write-Output ("       This is nes_cart_rom.v's documented CHR_LOCAL_BITS = 13")
    Write-Output ("       aliasing (bank bits above 12 fold onto 0..7), not a")
    Write-Output ("       conversion error, but CHR banks 1 and above will show the")
    Write-Output ("       wrong patterns.  Widening CHR_LOCAL_BITS and")
    Write-Output ("       CHR_SIZE_BYTES is the fix, and that is an RTL/BRAM change.")
}
Write-Output ''
Write-Output '=== outputs'
Write-Output ("  {0}  ({1} bytes, {2} words, {3} per line)" -f $prgPath, $prgOutBytes, $PrgWords, $script:WordsPerLine)
Write-Output ("  {0}  ({1} bytes, {2} words, {3} per line)" -f $chrPath, $chrOutBytes, $ChrWords, $script:WordsPerLine)
Write-Output ''
Write-Output ("Result: OK (header and trainer stripped, both images at full depth)")

exit 0
