<#
.SYNOPSIS
    Convert binary PPM (P6) files written by tb_nes_boot_rom into PNG.

.DESCRIPTION
    tb_nes_boot_rom dumps each captured NES frame as a binary PPM (P6), because
    PPM needs no library, no encoder and no dependencies.  This turns those into
    PNG so the frame can actually be viewed as an image.

    Uses System.Drawing, which is part of the .NET Framework and present on
    every Windows install this project targets, so there is nothing to install.
    The PPM is parsed here rather than handed to any decoder so the script does
    not depend on which codecs happen to be registered.

.PARAMETER Path
    One or more .ppm files, or a directory containing them.

.PARAMETER OutDir
    Where the .png files go.  Defaults to the directory of each input file.

.EXAMPLE
    .\tools\ppm2png.ps1 -Path build\frames
    .\tools\ppm2png.ps1 -Path build\frames\nes_frame29.ppm -OutDir build\png
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

function Resolve-PpmFile {
    param([string]$InputPath)

    if (Test-Path -LiteralPath $InputPath -PathType Container) {
        return @(Get-ChildItem -LiteralPath $InputPath -Filter '*.ppm' -File |
            Sort-Object Name |
            ForEach-Object { $_.FullName })
    }
    if (Test-Path -LiteralPath $InputPath -PathType Leaf) {
        return @((Resolve-Path -LiteralPath $InputPath).Path)
    }
    Write-Error -Message "ppm2png: not found: $InputPath" -ErrorAction Continue
    return @()
}

function Convert-PpmToPng {
    param(
        [string]$PpmFile,
        [string]$Destination
    )

    $bytes = [IO.File]::ReadAllBytes($PpmFile)

    # ---- P6 header: magic, width, height, maxval, each terminated by whitespace
    $pos = 0
    function Read-PpmToken {
        param([byte[]]$Data, [ref]$Cursor)
        while ($Cursor.Value -lt $Data.Length) {
            $c = $Data[$Cursor.Value]
            if ($c -ge 0x21 -and $c -le 0x7E) {
                break
            }
            $Cursor.Value = $Cursor.Value + 1
        }
        $start = $Cursor.Value
        while ($Cursor.Value -lt $Data.Length) {
            $c = $Data[$Cursor.Value]
            if ($c -lt 0x21 -or $c -gt 0x7E) {
                break
            }
            $Cursor.Value = $Cursor.Value + 1
        }
        $text = [Text.Encoding]::ASCII.GetString($Data, $start, $Cursor.Value - $start)
        $Cursor.Value = $Cursor.Value + 1   # consume exactly one delimiter
        return $text
    }

    $magic = Read-PpmToken -Data $bytes -Cursor ([ref]$pos)
    if ($magic -ne 'P6') {
        Write-Error -Message "ppm2png: $PpmFile is not a binary PPM (magic '$magic')" -ErrorAction Continue
        return
    }
    $width  = [int](Read-PpmToken -Data $bytes -Cursor ([ref]$pos))
    $height = [int](Read-PpmToken -Data $bytes -Cursor ([ref]$pos))
    $maxval = [int](Read-PpmToken -Data $bytes -Cursor ([ref]$pos))
    if ($width -le 0 -or $height -le 0) {
        Write-Error -Message "ppm2png: $PpmFile has a bad size ${width}x${height}" -ErrorAction Continue
        return
    }
    if ($maxval -ne 255) {
        Write-Error -Message "ppm2png: $PpmFile maxval is $maxval, only 255 is supported" -ErrorAction Continue
        return
    }

    $expected = $width * $height * 3
    $available = $bytes.Length - $pos
    if ($available -lt $expected) {
        Write-Error -Message ("ppm2png: $PpmFile is truncated, {0} of {1} pixel bytes present" -f $available, $expected) -ErrorAction Continue
        return
    }

    # LockBits needs a 32bpp buffer; build one and copy the RGB triples in.
    $bmp = New-Object System.Drawing.Bitmap($width, $height,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $width, $height)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $stride = $data.Stride
        $row = New-Object byte[] $stride
        for ($y = 0; $y -lt $height; $y++) {
            [Array]::Clear($row, 0, $stride)
            $src = $pos + ($y * $width * 3)
            for ($x = 0; $x -lt $width; $x++) {
                $row[$x * 3 + 0] = $bytes[$src + $x * 3 + 0]
                $row[$x * 3 + 1] = $bytes[$src + $x * 3 + 1]
                $row[$x * 3 + 2] = $bytes[$src + $x * 3 + 2]
            }
            [System.Runtime.InteropServices.Marshal]::Copy($row, 0,
                [IntPtr]::Add($data.Scan0, $y * $stride), $stride)
        }
    } finally {
        $bmp.UnlockBits($data)
    }

    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $bmp.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    Write-Output ("ppm2png: {0} -> {1}  ({2}x{3})" -f $PpmFile, $Destination, $width, $height)
}

$files = @()
foreach ($p in $Path) { $files += Resolve-PpmFile -InputPath $p }

if ($files.Count -eq 0) {
    Write-Error -Message 'ppm2png: no .ppm files found' -ErrorAction Continue
    exit 1
}

foreach ($f in $files) {
    $targetDir = if ($OutDir) { $OutDir } else { Split-Path -Parent $f }
    $target = Join-Path $targetDir (([IO.Path]::GetFileNameWithoutExtension($f)) + '.png')
    Convert-PpmToPng -PpmFile $f -Destination $target
}

exit 0
