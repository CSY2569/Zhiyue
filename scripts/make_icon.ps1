# 从 PNG 生成多尺寸 PNG 压缩 ICO（Windows Vista+ 格式）
param(
    [string]$Source = "$PSScriptRoot\..\assets\ZhiYue.png",
    [string]$Output = "$PSScriptRoot\..\windows\runner\resources\app_icon.ico"
)

Add-Type -AssemblyName System.Drawing

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$src = [System.Drawing.Image]::FromFile((Resolve-Path $Source))

# 生成各尺寸 PNG 数据
$pngs = foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($src, $s, $s)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    ,$ms.ToArray()
}
$src.Dispose()

$fs = [System.IO.File]::Create((Resolve-Path (Split-Path $Output)).Path + '\' + (Split-Path $Output -Leaf))
$bw = New-Object System.IO.BinaryWriter($fs)

# ICONDIR: reserved=0, type=1(icon), count
$bw.Write([uint16]0)
$bw.Write([uint16]1)
$bw.Write([uint16]$sizes.Count)

# 计算各图像数据偏移（头 6 字节 + 每条目 16 字节）
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))   # 宽度（0=256）
    $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))   # 高度
    $bw.Write([byte]0)                                        # 调色板
    $bw.Write([byte]0)                                        # 保留
    $bw.Write([uint16]1)                                      # 色平面
    $bw.Write([uint16]32)                                     # 位深
    $bw.Write([uint32]$pngs[$i].Length)                       # 数据大小
    $bw.Write([uint32]$offset)                                # 数据偏移
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close()

"OK: $Output ($((Get-Item $Output).Length) bytes, sizes: $($sizes -join ','))"
