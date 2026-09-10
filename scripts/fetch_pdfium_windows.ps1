# Downloads the prebuilt pdfium dynamic library (BSD-3) for Windows from
# bblanchon/pdfium-binaries and places it at rust/libpdfium/pdfium.dll for the
# Rust core to link at runtime. Mirrors scripts/fetch_pdfium.sh (Linux).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/fetch_pdfium_windows.ps1
#
# Source: bblanchon/pdfium-binaries (rolling release, no pinned tag). GitHub
# is fetched through a domestic acceleration proxy by default (override with
# -Mirror or $env:PDFIUM_MIRROR; pass -Mirror "" for a direct connection);
# after download the script verifies the file is a valid PE DLL and prints its
# SHA-256 for audit.
#
# Requires: PowerShell 5.1+ (built-in tar supports .tgz on Win10 1803+).

param(
    [string]$Mirror = $(if ($env:PDFIUM_MIRROR) { $env:PDFIUM_MIRROR } else { "https://ghfast.top/" })
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$DestDir = Join-Path $ProjectRoot "rust\libpdfium"
$DestLib = Join-Path $DestDir "pdfium.dll"

if (Test-Path $DestLib) {
    Write-Host "pdfium.dll already exists, skipping."
    exit 0
}

$Url = "https://github.com/bblanchon/pdfium-binaries/releases/latest/download/pdfium-win-x64.tgz"
$Tgz = Join-Path $env:TEMP "pdfium-win-x64.tgz"
$ExtractDir = Join-Path $env:TEMP "pdfium-win-x64-extract"

$DownloadUrl = if ($Mirror) { "$Mirror$Url" } else { $Url }
Write-Host "Downloading $DownloadUrl ..."
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $Tgz
} catch {
    if ($Mirror) {
        Write-Warning "镜像下载失败，回退到 GitHub 直连: $_"
        Invoke-WebRequest -Uri $Url -OutFile $Tgz
    } else {
        throw
    }
}

if (Test-Path $ExtractDir) { Remove-Item -Recurse -Force $ExtractDir }
New-Item -ItemType Directory -Path $ExtractDir | Out-Null
tar -xzf $Tgz -C $ExtractDir

$PdfiumDll = Join-Path $ExtractDir "bin\pdfium.dll"
if (-not (Test-Path $PdfiumDll)) {
    Write-Error "pdfium.dll not found in the downloaded archive"
    exit 1
}

# Verify it is a PE DLL (MZ header) before accepting it.
$bytes = [System.IO.File]::ReadAllBytes($PdfiumDll)
if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
    Write-Error "Downloaded file is not a valid PE DLL (missing MZ header)"
    exit 1
}

New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
Copy-Item $PdfiumDll $DestLib

$hash = Get-FileHash $DestLib -Algorithm SHA256
Write-Host "pdfium.dll installed to $DestLib"
Write-Host "SHA-256: $($hash.Hash)"
Write-Host "Size: $((Get-Item $DestLib).Length) bytes"
