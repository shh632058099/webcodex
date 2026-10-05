# Verify that Windows legacy-compatible binaries do not statically import
# entry points that are unavailable on Windows 8.1. This catches loader-time
# failures before an installer is produced (for example USER32!
# SetThreadDpiAwarenessContext).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Binary,
    [string]$Dumpbin
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    throw "Windows legacy import validation failed: $Message"
}

function Resolve-Dumpbin([string]$Explicit) {
    if ($Explicit) {
        $candidate = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Explicit)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
        Fail "dumpbin.exe was not found at '$candidate'"
    }

    $command = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installation = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $installation) {
            $toolsRoot = Join-Path $installation.Trim() "VC\Tools\MSVC"
            $matches = @(Get-ChildItem -LiteralPath $toolsRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName "bin\Hostx64\x64\dumpbin.exe" } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
            if ($matches.Count -gt 0) {
                return $matches[0]
            }
        }
    }

    Fail "dumpbin.exe was not found; install the Visual Studio C++ x64 build tools or run from a Developer PowerShell"
}

$forbiddenImports = @(
    "SetThreadDpiAwarenessContext",
    "GetThreadDpiAwarenessContext",
    "SetProcessDpiAwarenessContext",
    "GetDpiForWindow",
    "GetDpiForSystem",
    "GetSystemMetricsForDpi",
    "AdjustWindowRectExForDpi",
    "EnableNonClientDpiScaling",
    "AreDpiAwarenessContextsEqual"
)

$dumpbinExe = Resolve-Dumpbin $Dumpbin
foreach ($inputPath in $Binary) {
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($inputPath)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        Fail "binary does not exist: $resolved"
    }

    $output = @(& $dumpbinExe /nologo /imports $resolved 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Fail "dumpbin /imports failed for '$resolved' with exit code $LASTEXITCODE"
    }
    $text = $output -join "`n"
    $found = @($forbiddenImports | Where-Object { $text -match [regex]::Escape($_) })
    if ($found.Count -gt 0) {
        Fail "'$resolved' imports Windows 10-only API(s): $($found -join ', ')"
    }
    Write-Host "Legacy import check passed: $resolved"
}
