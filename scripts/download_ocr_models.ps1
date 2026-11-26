# Downloads the PP-OCRv4 models for the RBWA full-page OCR engine
# (FEATURES 7.1.1 / 7.1.9). Windows counterpart of scripts/download_ocr_models.sh.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/download_ocr_models.ps1            # 高精度（默认，server 模型）
#   powershell -ExecutionPolicy Bypass -File scripts/download_ocr_models.ps1 -Fast      # 快速模式（mobile 模型）
#   powershell -ExecutionPolicy Bypass -File scripts/download_ocr_models.ps1 -All       # 两种都下载
#   powershell -ExecutionPolicy Bypass -File scripts/download_ocr_models.ps1 -All -Dir <path>  # 下载到指定目录（打包用）
#
# Packaged builds ship the models next to the exe (install from CMake);
# dev builds land in %APPDATA%\RBWA\models (dirs::data_dir() on Windows) --
# the fallback directory the Rust core resolves via app_data_dir:
#
#   models\
#     cls.onnx               # 方向分类（两模式共用）
#     ppocr_keys_v1.txt      # 识别字符表（共用）
#     high_precision\        # ch_PP-OCRv4_*_server.onnx（高精度，~200MB）
#       det.onnx  rec.onnx
#     fast\                  # ch_PP-OCRv4_*_mobile.onnx（快速，~16MB）
#       det.onnx  rec.onnx
#
# Source: ModelScope 官方仓库 RapidAI/RapidOCR (v3.9.0)；sha256 与 Linux 脚本一致。

param(
    [switch]$Fast,
    [switch]$All,
    [string]$Dir
)

$ErrorActionPreference = "Stop"

$BaseUrl = "https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.0"
if ($Dir) {
    $ModelsDir = $Dir
} else {
    $ModelsDir = Join-Path $env:APPDATA "RBWA\models"
}

# 源文件 → 本地路径 + sha256（det/rec 按模式子目录存放）。
$Files = @(
    @{ Src = "onnx/PP-OCRv4/det/ch_PP-OCRv4_det_server.onnx"; Dest = "high_precision/det.onnx"; Sha = "cfa39a3f298f6d3fc71789834d15da36d11a6c59b489fc16ea4733728012f786" },
    @{ Src = "onnx/PP-OCRv4/rec/ch_PP-OCRv4_rec_server.onnx"; Dest = "high_precision/rec.onnx"; Sha = "6a2676219be9907c7fc9cf61ebaa843bf2898777def567925b78886fcd90c07a" },
    @{ Src = "onnx/PP-OCRv4/det/ch_PP-OCRv4_det_mobile.onnx";  Dest = "fast/det.onnx";          Sha = "d2a7720d45a54257208b1e13e36a8479894cb74155a5efe29462512d42f49da9" },
    @{ Src = "onnx/PP-OCRv4/rec/ch_PP-OCRv4_rec_mobile.onnx";  Dest = "fast/rec.onnx";          Sha = "48fc40f24f6d2a207a2b1091d3437eb3cc3eb6b676dc3ef9c37384005483683b" },
    @{ Src = "onnx/PP-OCRv4/cls/ch_ppocr_mobile_v2.0_cls_mobile.onnx"; Dest = "cls.onnx";       Sha = "e47acedf663230f8863ff1ab0e64dd2d82b838fceb5957146dab185a89d6215c" },
    @{ Src = "paddle/PP-OCRv4/rec/ch_PP-OCRv4_rec_mobile/ppocr_keys_v1.txt"; Dest = "ppocr_keys_v1.txt"; Sha = "28b2362ad4ab2dc38769aa72feb535e3a9ddb3fd2a7585a05920e6393b1dc7f7" }
)

function Download-One([string]$Src, [string]$Dest, [string]$Sha) {
    $destPath = Join-Path $ModelsDir ($Dest -replace "/", "\")
    if (Test-Path $destPath) {
        Write-Host "已有 $(Split-Path $Dest -Leaf)，跳过"
        return
    }
    New-Item -ItemType Directory -Path (Split-Path $destPath) -Force | Out-Null
    $url = "$BaseUrl/$Src"
    Write-Host "下载 $(Split-Path $Dest -Leaf) …"
    $tmp = "$destPath.part"
    Invoke-WebRequest -Uri $url -OutFile $tmp
    $actual = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Sha) {
        Write-Error "校验失败: $Dest (期望 $Sha, 实际 $actual)"
        Remove-Item -Force $tmp
        exit 1
    }
    Move-Item $tmp $destPath
    Write-Host "校验通过: $(Split-Path $Dest -Leaf)"
}

# 选定模式：默认高精度；-Fast 只快速；-All 两个都要。
$wantPrecision = $true
$wantFast = $false
if ($Fast)  { $wantPrecision = $false; $wantFast = $true }
if ($All)   { $wantPrecision = $true;  $wantFast = $true }

foreach ($f in $Files) {
    $isDetRec = $f.Dest -like "high_precision/*" -or $f.Dest -like "fast/*"
    if ($isDetRec) {
        if ($f.Dest -like "high_precision/*" -and -not $wantPrecision) { continue }
        if ($f.Dest -like "fast/*" -and -not $wantFast) { continue }
    }
    Download-One $f.Src $f.Dest $f.Sha
}

Write-Host "完成。模型目录: $ModelsDir"
Write-Host "提示：首次扫描时引擎会懒加载模型（FEATURES 7.1.5）。"
