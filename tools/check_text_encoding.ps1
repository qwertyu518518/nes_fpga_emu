<#
.SYNOPSIS
    Verify repository text files against the encoding rules in AGENTS.md.

.DESCRIPTION
    Every text file in this repository must be UTF-8 without BOM and LF-only.
    AGENTS.md records why that is a rule rather than a preference: a real
    incident destroyed about 90 newlines in README.md, taking it from 283 lines
    to 193, because Windows PowerShell 5.1 round-tripped it through Get-Content
    and Set-Content. Under the ANSI code page UTF-8 Chinese decodes to mojibake
    and the GBK decoder swallows LF bytes, collapsing line breaks silently.

    This script exists so that verification is one command rather than a
    hand-rolled byte inspection that each session reinvents slightly differently.
    AGENTS.md requires the check after any bulk edit; this is that check.

    It reads raw bytes and never round-trips the file through Get-Content,
    Set-Content or Out-File. That is the exact failure mode being guarded
    against, so using those cmdlets here would be self-defeating.

    Checks per file: no UTF-8 BOM, no CRLF, no lone CR, decodes as strict UTF-8,
    and contains no U+FFFD replacement character. The last one catches text that
    was already mangled somewhere upstream and then written back out.

    A CRLF hit is not automatically a repository defect. .gitattributes pins
    "* text=auto eol=lf", so git stores LF in the blob; a CRLF worktree copy
    usually means the file was written by an editor or tool and never re-checked
    out, or that a local core.autocrlf=true is still set. Distinguish the two
    with:

        git ls-files --eol <path>

    i/lf w/crlf means the committed content is correct and only the local
    working copy drifted. i/crlf means CRLF is actually in the repository and
    needs "git add --renormalize". This script reports the worktree, because
    that is what a bulk edit can damage, so it flags both.

.PARAMETER Path
    Files or directories to check. Defaults to every tracked text file in the
    repository, resolved through git so build output and vendored sources under
    .slim/clonedeps are excluded.

.PARAMETER MinLines
    Fail any file with fewer lines than this. A collapsed file usually still has
    content, so a plausible line count is a cheap extra tripwire. 0 disables.

.EXAMPLE
    .\tools\check_text_encoding.ps1

    Check every tracked text file. This is what to run after a bulk edit.

.EXAMPLE
    .\tools\check_text_encoding.ps1 -Path docs\00-overview\vivado-runbook.md

    Check one file.

.EXAMPLE
    .\tools\check_text_encoding.ps1 -MinLines 100

    Also fail anything that dropped below 100 lines, which is how the README.md
    incident would have been caught immediately.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Path,

    [int]$MinLines = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-RepoRelative {
    param([string]$Full)
    $root = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Full)
    if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length)
    }
    return $full
}

function Resolve-Targets {
    param([string[]]$Requested)

    if ($null -eq $Requested -or @($Requested).Count -eq 0) {
        $tracked = & git -C $repoRoot ls-files 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-files failed; run from inside the repository or pass -Path explicitly"
        }
        $extensions = @('.md', '.txt', '.ps1', '.v', '.vh', '.sv', '.tcl', '.xdc',
                        '.qsf', '.qpf', '.sdc', '.json', '.yml', '.yaml', '.py', '.f',
                        '.cfg', '.ini', '.gitignore', '.gitattributes')
        $tracked | Where-Object {
            $name = $_
            ($extensions -contains [IO.Path]::GetExtension($name).ToLowerInvariant()) -or
            ($name -match '(^|/)\.(gitignore|gitattributes)$')
        }
        return
    }

    foreach ($p in $Requested) {
        $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $repoRoot $p }
        if (Test-Path -LiteralPath $full -PathType Container) {
            Get-ChildItem -LiteralPath $full -Recurse -File |
                Where-Object { $_.FullName -notmatch '[\\/]\.slim[\\/]' } |
                ForEach-Object { $_.FullName }
        }
        elseif (Test-Path -LiteralPath $full -PathType Leaf) {
            $full
        }
        else {
            throw "path not found: $p"
        }
    }
}

function Test-TextFile {
    param([string]$File)

    $bytes = [IO.File]::ReadAllBytes($File)
    $problems = New-Object System.Collections.Generic.List[string]

    $hasBom = $bytes.Length -ge 3 -and
              $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if ($hasBom) { $problems.Add('UTF-8 BOM') }

    $crlf = 0
    $loneCr = 0
    $lf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -ne 0x0D) {
            if ($bytes[$i] -eq 0x0A) { $lf++ }
            continue
        }
        if ($i + 1 -lt $bytes.Length -and $bytes[$i + 1] -eq 0x0A) { $crlf++ } else { $loneCr++ }
    }
    if ($crlf -gt 0) { $problems.Add("CRLF x$crlf") }
    if ($loneCr -gt 0) { $problems.Add("lone-CR x$loneCr") }

    $text = $null
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    try {
        $text = $encoding.GetString($bytes)
    }
    catch {
        $problems.Add('not valid UTF-8')
    }

    $replacement = 0
    $lines = 0
    if ($null -ne $text) {
        $replacement = ([regex]::Matches($text, [string][char]0xFFFD)).Count
        if ($replacement -gt 0) { $problems.Add("U+FFFD x$replacement") }
        if ($lf -gt 0) { $lines = $lf } else { $lines = ($text -split "`n").Count }
    }

    $tooFew = ($MinLines -gt 0 -and $lines -lt $MinLines)
    if ($tooFew) { $problems.Add("only $lines lines, expected >= $MinLines") }

    [pscustomobject]@{
        File       = Get-RepoRelative $File
        Bytes      = $bytes.Length
        Lines      = $lines
        Problems   = $problems
        IsClean    = ($problems.Count -eq 0)
    }
}

$targets = @(Resolve-Targets -Requested $Path)
if ($targets.Count -eq 0) {
    Write-Host 'no text files matched' -ForegroundColor Yellow
    exit 0
}

# Wrapped in @() deliberately. A single file makes $results a bare PSCustomObject,
# and .Count on a scalar is an error under Set-StrictMode -Version Latest, which
# would break the most common invocation of all: checking one file.
$results = @(foreach ($t in $targets) { Test-TextFile -File $t })
$bad = @($results | Where-Object { -not $_.IsClean })

foreach ($r in $results) {
    $rel = $r.File
    if ($r.IsClean) {
        Write-Host ('  ok    {0,-58} {1,7} B  {2,5} lines' -f $rel, $r.Bytes, $r.Lines)
    }
    else {
        Write-Host ('  FAIL  {0,-58} {1}' -f $rel, ($r.Problems -join ', ')) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ('checked {0} file(s): {1} clean, {2} with problems' -f $results.Count, ($results.Count - $bad.Count), $bad.Count)

if ($bad.Count -gt 0) {
    Write-Host ''
    Write-Host 'Do not fix these by round-tripping through Get-Content/Set-Content; that is how' -ForegroundColor Red
    Write-Host 'README.md lost 90 newlines. Re-read the bytes and write the file once, correctly.' -ForegroundColor Red
    exit 1
}

exit 0
