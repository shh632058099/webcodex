# Build an x64 WebCodex Desktop package that keeps the Rust runtime compatible
# with Windows 7/8/8.1. The normal Windows build remains Windows 10+.
#
# Rust's ordinary x86_64-pc-windows-msvc target is Windows 10+ on current Rust.
# The x86_64-win7-windows-msvc target keeps the older Windows ABI baseline, but
# Rust does not ship prebuilt std artifacts for it, so this build uses nightly
# cargo -Z build-std with rust-src.
[CmdletBinding()]
param(
    [switch]$AllowDirty,
    [string]$NightlyToolchain = "nightly"
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    throw "Windows 8.1 Desktop build failed: $Message"
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "required command not found: $Name"
    }
}

function Ensure-TauriNsisToolchain {
    # Tauri's bundler downloads these tools on demand with a short global timeout.
    # Pre-seed the exact pinned toolchain so slow GitHub links do not make an otherwise
    # successful Windows 8.1 build fail during the final NSIS packaging step.
    $toolsDir = Join-Path $env:LOCALAPPDATA "tauri"
    $nsisDir = Join-Path $toolsDir "NSIS"
    $required = @(
        "makensis.exe",
        "Bin\makensis.exe",
        "Stubs\lzma-x86-unicode",
        "Stubs\lzma_solid-x86-unicode",
        "Plugins\x86-unicode\additional\nsis_tauri_utils.dll",
        "Include\MUI2.nsh",
        "Include\FileFunc.nsh",
        "Include\x64.nsh",
        "Include\nsDialogs.nsh",
        "Include\WinMessages.nsh",
        "Include\Win\COM.nsh",
        "Include\Win\Propkey.nsh",
        "Include\Win\RestartManager.nsh"
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $nsisDir $_) -PathType Leaf) })
    if ($missing.Count -eq 0) {
        Write-Host "Using cached Tauri NSIS toolchain: $nsisDir"
        return
    }

    Require-Command "curl.exe"
    $nsisUrl = "https://github.com/tauri-apps/binary-releases/releases/download/nsis-3.11/nsis-3.11.zip"
    $nsisSha1 = "EF7FF767E5CBD9EDD22ADD3A32C9B8F4500BB10D"
    $utilsUrl = "https://github.com/tauri-apps/nsis-tauri-utils/releases/download/nsis_tauri_utils-v0.5.3/nsis_tauri_utils.dll"
    $utilsSha1 = "75197FEE3C6A814FE035788D1C34EAD39349B860"
    $downloadDir = Join-Path $env:TEMP ("webcodex-tauri-nsis." + [guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $downloadDir "nsis-3.11.zip"
    $utilsPath = Join-Path $downloadDir "nsis_tauri_utils.dll"
    $extractDir = Join-Path $downloadDir "extract"
    try {
        New-Item -ItemType Directory -Force -Path $downloadDir, $extractDir, $toolsDir | Out-Null
        Write-Host "Downloading pinned Tauri NSIS 3.11 toolchain..."
        & curl.exe -L --fail --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 1800 $nsisUrl -o $zipPath
        if ($LASTEXITCODE -ne 0) { Fail "NSIS 3.11 download failed" }
        & curl.exe -L --fail --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 1800 $utilsUrl -o $utilsPath
        if ($LASTEXITCODE -ne 0) { Fail "nsis_tauri_utils download failed" }

        $actualNsisSha1 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA1).Hash.ToUpperInvariant()
        $actualUtilsSha1 = (Get-FileHash -LiteralPath $utilsPath -Algorithm SHA1).Hash.ToUpperInvariant()
        if ($actualNsisSha1 -ne $nsisSha1) { Fail "NSIS 3.11 SHA-1 mismatch" }
        if ($actualUtilsSha1 -ne $utilsSha1) { Fail "nsis_tauri_utils SHA-1 mismatch" }

        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
        $expandedNsis = Join-Path $extractDir "nsis-3.11"
        if (-not (Test-Path -LiteralPath $expandedNsis -PathType Container)) {
            Fail "NSIS archive did not contain the expected nsis-3.11 directory"
        }
        $candidate = Join-Path $downloadDir "NSIS"
        Move-Item -LiteralPath $expandedNsis -Destination $candidate
        $pluginDir = Join-Path $candidate "Plugins\x86-unicode\additional"
        New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
        Copy-Item -LiteralPath $utilsPath -Destination (Join-Path $pluginDir "nsis_tauri_utils.dll") -Force

        $candidateMissing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $candidate $_) -PathType Leaf) })
        if ($candidateMissing.Count -ne 0) {
            Fail "downloaded NSIS toolchain is incomplete: $($candidateMissing -join ', ')"
        }
        if (Test-Path -LiteralPath $nsisDir) {
            Remove-Item -LiteralPath $nsisDir -Recurse -Force
        }
        Move-Item -LiteralPath $candidate -Destination $nsisDir
        Write-Host "Tauri NSIS toolchain cached: $nsisDir"
    } finally {
        if (Test-Path -LiteralPath $downloadDir) {
            Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-TauriProductionAssets([string]$BinaryPath, [string]$DistDir) {
    $indexPath = Join-Path $DistDir "index.html"
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        Fail "Desktop frontend index is missing: $indexPath"
    }
    $index = [System.IO.File]::ReadAllText($indexPath)
    $assetMatch = [regex]::Match($index, 'assets/[A-Za-z0-9._-]+\.js')
    if (-not $assetMatch.Success) {
        Fail "could not resolve the production JavaScript asset from $indexPath"
    }
    $binaryText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($BinaryPath))
    if (-not $binaryText.Contains($assetMatch.Value)) {
        Fail "legacy Desktop binary does not embed production frontend assets; Tauri custom-protocol production mode is not active"
    }
    Write-Host "Production frontend embedded: $($assetMatch.Value)"
}

$LegacyTarget = "x86_64-win7-windows-msvc"
$Root = Split-Path -Parent $PSScriptRoot
$RuntimeTargetRoot = Join-Path $Root "target\desktop-win81-runtime"
$TauriTargetRoot = Join-Path $Root "target\desktop-win81-tauri"
$OutputDir = Join-Path $Root "target\desktop-win81-dist"
$StageDir = Join-Path $Root ("target\desktop-win81-stage." + [guid]::NewGuid().ToString("N"))
$PreviousLocation = Get-Location
$PreviousBuiltAt = $env:WEBCODEX_BUILT_AT
$PreviousCargoTarget = $env:CARGO_TARGET_DIR
$PreviousRustFlags = $env:RUSTFLAGS

try {
    foreach ($command in @("git", "node", "npm", "cargo", "rustup")) {
        Require-Command $command
    }

    Set-Location $Root

    $nodeVersion = [string](& node --version)
    if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v22(?:\.|$)') {
        Fail "Node.js 22 is required; got '$($nodeVersion.Trim())'"
    }

    $toolchains = @(& rustup toolchain list)
    if ($LASTEXITCODE -ne 0 -or -not ($toolchains | Where-Object { $_ -match "^$([regex]::Escape($NightlyToolchain))(?:-|\s|$)" })) {
        Fail "Rust toolchain '$NightlyToolchain' is required. Install it with: rustup toolchain install $NightlyToolchain --profile minimal"
    }
    $components = @(& rustup component list --toolchain $NightlyToolchain --installed)
    if ($LASTEXITCODE -ne 0 -or -not ($components | Where-Object { $_ -match '^rust-src(?:-|\s|$)' })) {
        Fail "rust-src is required for build-std. Install it with: rustup component add rust-src --toolchain $NightlyToolchain"
    }
    $targets = @(& rustup run $NightlyToolchain rustc --print target-list)
    if ($LASTEXITCODE -ne 0 -or $targets -notcontains $LegacyTarget) {
        Fail "Rust toolchain '$NightlyToolchain' does not provide target specification '$LegacyTarget'"
    }

    $status = @(& git status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { Fail "git status failed" }
    $GitDirty = $status.Count -ne 0
    if ($GitDirty -and -not $AllowDirty) {
        Fail "worktree has uncommitted changes; commit/stash them or rerun with -AllowDirty for local compatibility testing"
    }

    $SourceSha = ([string](& git rev-parse HEAD)).Trim()
    if ($LASTEXITCODE -ne 0 -or $SourceSha -notmatch '^[0-9A-Fa-f]{40}$') {
        Fail "could not resolve the exact Git HEAD"
    }
    $ShortSource = ([string](& git rev-parse --short=12 HEAD)).Trim().ToLowerInvariant()
    $Version = ([string](& node -p "require('./npm/webcodex/package.json').version")).Trim()
    $BuiltAtText = ([string](& git show -s --format=%ct HEAD)).Trim()
    if ($LASTEXITCODE -ne 0 -or $BuiltAtText -notmatch '^[0-9]+$') {
        Fail "could not resolve the source commit timestamp"
    }
    $BuiltAt = [Int64]$BuiltAtText

    Write-Host "Building WebCodex Desktop for Windows 8.1 compatibility"
    Write-Host "  source:     $SourceSha"
    Write-Host "  version:    $Version"
    Write-Host "  rust target: $LegacyTarget"
    Write-Host "  toolchain:  $NightlyToolchain"
    Write-Host "  dirty:      $GitDirty"
    Write-Warning "Windows 8.1 also requires a WebView2 Runtime no newer than 109. This script validates native EXE compatibility but does not install WebView2."

    & npm ci --prefix frontend
    if ($LASTEXITCODE -ne 0) { Fail "frontend npm ci failed" }
    & npm ci --prefix apps/desktop
    if ($LASTEXITCODE -ne 0) { Fail "Desktop npm ci failed" }

    $env:WEBCODEX_BUILT_AT = "$BuiltAt"
    $env:WEBCODEX_GIT_COMMIT = $SourceSha.ToLowerInvariant()
    $env:WEBCODEX_GIT_DIRTY = if ($GitDirty) { "true" } else { "false" }

    $env:CARGO_TARGET_DIR = $RuntimeTargetRoot
    & cargo "+$NightlyToolchain" build `
        -Z "build-std=std,panic_unwind" `
        --locked `
        --profile dogfood `
        --target $LegacyTarget `
        -p webcodex -p webcodex-cli -p webcodex-runner
    if ($LASTEXITCODE -ne 0) { Fail "legacy WebCodex runtime build failed" }

    $BinDir = Join-Path $RuntimeTargetRoot "$LegacyTarget\dogfood"
    $RuntimeBinaries = @(
        (Join-Path $BinDir "webcodex.exe"),
        (Join-Path $BinDir "webcodex-server.exe"),
        (Join-Path $BinDir "webcodex-runner.exe")
    )
    & .\scripts\assert_windows_legacy_imports.ps1 -Binary $RuntimeBinaries
    if ($LASTEXITCODE -ne 0) { Fail "legacy runtime import validation failed" }

    & .\scripts\prepare_desktop_bundle.ps1 `
        -BinDir $BinDir `
        -Version $Version `
        -SourceSha $SourceSha `
        -BuiltAt $BuiltAt `
        -OutputDir $StageDir `
        -GitDirty $GitDirty

    $Config = Join-Path $StageDir "tauri.bundle.conf.json"
    if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
        Fail "Desktop staging did not produce the Tauri config overlay"
    }

    New-Item -ItemType Directory -Force -Path $TauriTargetRoot, $OutputDir | Out-Null
    $BundleDir = Join-Path $TauriTargetRoot "$LegacyTarget\release\bundle\nsis"
    if (Test-Path -LiteralPath $BundleDir) {
        Remove-Item -LiteralPath $BundleDir -Recurse -Force
    }

    # Tauri CLI currently rejects Rust's built-in x86_64-win7-windows-msvc target during
    # `tauri build`, even though rustc can compile it with build-std. Build the native app
    # with Cargo first, then let `tauri bundle` package that already-built executable.
    #
    # The win7 target intentionally reports target_vendor="win7". A few Windows ecosystem
    # crates (notably ctor via tauri-utils) gate COFF support on target_vendor="pc". Add pc
    # as an extra cfg value while retaining win7, so Rust's own win7 compatibility cfgs stay
    # active and those crates can recognize the target as Windows/MSVC.
    # A direct Cargo build must explicitly enable Tauri's custom-protocol feature.
    # Without it Tauri marks the application as a dev build and opens build.devUrl
    # (http://127.0.0.1:1420) instead of the embedded frontendDist assets.
    & npm run build --prefix apps/desktop
    if ($LASTEXITCODE -ne 0) { Fail "Desktop frontend build failed" }

    $env:CARGO_TARGET_DIR = $TauriTargetRoot
    $env:RUSTFLAGS = '--cfg target_vendor="pc" -Aexplicit_builtin_cfgs_in_flags'
    Push-Location (Join-Path $Root "apps\desktop\src-tauri")
    try {
        & cargo "+$NightlyToolchain" build `
            -Z "build-std=std,panic_unwind" `
            --locked `
            --release `
            --target $LegacyTarget `
            --features "tauri/custom-protocol"
        if ($LASTEXITCODE -ne 0) { Fail "legacy Tauri native build failed" }
    } finally {
        Pop-Location
    }

    $CargoDesktopBinary = Join-Path $TauriTargetRoot "$LegacyTarget\release\webcodex-desktop.exe"
    $DesktopBinary = Join-Path $TauriTargetRoot "$LegacyTarget\release\WebCodex.exe"
    if (-not (Test-Path -LiteralPath $CargoDesktopBinary -PathType Leaf)) {
        Fail "legacy Tauri native build did not produce $CargoDesktopBinary"
    }
    Copy-Item -LiteralPath $CargoDesktopBinary -Destination $DesktopBinary -Force
    Assert-TauriProductionAssets $DesktopBinary (Join-Path $Root "apps\desktop\dist")
    & .\scripts\assert_windows_legacy_imports.ps1 -Binary @($DesktopBinary)
    if ($LASTEXITCODE -ne 0) { Fail "legacy Desktop import validation failed" }

    Ensure-TauriNsisToolchain

    Push-Location (Join-Path $Root "apps\desktop")
    try {
        & node node_modules/@tauri-apps/cli/tauri.js bundle `
            --target $LegacyTarget `
            --bundles nsis `
            --config $Config `
            --ci `
            --no-sign
        if ($LASTEXITCODE -ne 0) { Fail "legacy Tauri NSIS bundle failed" }
    } finally {
        Pop-Location
    }

    & .\scripts\assert_windows_legacy_imports.ps1 -Binary @($DesktopBinary)
    if ($LASTEXITCODE -ne 0) { Fail "legacy Desktop import validation failed" }

    $Installers = @(Get-ChildItem -LiteralPath $BundleDir -Filter "*-setup.exe" -File)
    if ($Installers.Count -ne 1) {
        Fail "expected exactly one NSIS installer, found $($Installers.Count) in $BundleDir"
    }

    $SourceLabel = if ($GitDirty) { "dirty-$ShortSource" } else { $ShortSource }
    $OutputInstaller = Join-Path $OutputDir "webcodex-desktop-win81-$SourceLabel-v$Version-win32-x64-setup.exe"
    Copy-Item -LiteralPath $Installers[0].FullName -Destination $OutputInstaller -Force
    $Hash = (Get-FileHash -LiteralPath $OutputInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        "$OutputInstaller.sha256",
        "$Hash  $(Split-Path -Leaf $OutputInstaller)`n",
        [System.Text.Encoding]::ASCII
    )

    Write-Host ""
    Write-Host "Windows 8.1 compatibility installer ready:"
    Write-Host "  $OutputInstaller"
    Write-Host "SHA-256: $Hash"
    Write-Host "Before testing on Windows 8.1, install/retain Microsoft Edge WebView2 Runtime 109.x."
} finally {
    if (Test-Path -LiteralPath $StageDir) {
        Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:WEBCODEX_BUILT_AT = $PreviousBuiltAt
    $env:CARGO_TARGET_DIR = $PreviousCargoTarget
    $env:RUSTFLAGS = $PreviousRustFlags
    Set-Location $PreviousLocation
}
