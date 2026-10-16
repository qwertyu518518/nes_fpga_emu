[CmdletBinding()]
param(
    # Verify that docs/figures is already up to date instead of rewriting it.
    # Exits non-zero when any figure differs from what the generator produces.
    [switch]$Check
)

# gen_figures.ps1 : regenerate the SVG schematics under docs/figures/.
#
# WHY THIS WRAPPER EXISTS
#   The drawing code lives in tools/gen_figures.py, not here, and the reason is
#   stated at the top of that file: an SVG figure is a few dozen boxes, arrows
#   and labels whose coordinates are data, and Python expresses that with the
#   standard library alone.  This wrapper keeps the repository's PowerShell
#   entry-point convention and, more usefully, locates a Python interpreter so
#   nobody has to remember which spelling this machine uses.
#
# WHAT IT GUARANTEES
#   The generator is deterministic: running it twice produces byte-identical
#   output.  It writes UTF-8 without BOM and LF line endings, so every SVG and
#   the generated docs/figures/README.md pass tools/check_text_encoding.ps1.
#   Each figure is derived by reading the RTL named in documents/figures/README.md;
#   a detail that cannot be traced to source is not drawn.
#
# USAGE
#   .\tools\gen_figures.ps1
#   .\tools\gen_figures.ps1 -Check

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $PSScriptRoot 'gen_figures.py'

# Find an interpreter.  py -3 first (the Windows launcher), then python, then
# python3, so a machine with any one of them works.
$python = $null
foreach ($candidate in @('py', 'python', 'python3')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        if ($candidate -eq 'py') {
            $probe = & py -3 --version 2>&1
        }
        else {
            $probe = & $candidate --version 2>&1
        }
        if ($LASTEXITCODE -eq 0) {
            $python = $candidate
            break
        }
    }
}

if ($null -eq $python) {
    Write-Host 'gen_figures: no Python interpreter found on PATH.' -ForegroundColor Red
    Write-Host 'Install Python 3 (stdlib only is enough), then re-run.' -ForegroundColor Red
    Write-Host 'The figures are already committed; this is only needed to regenerate them.' -ForegroundColor Yellow
    exit 2
}

Push-Location $repoRoot
try {
    if ($python -eq 'py') {
        if ($Check) { & py -3 $generator --check } else { & py -3 $generator }
    }
    else {
        if ($Check) { & $python $generator --check } else { & $python $generator }
    }
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
}

exit $code
