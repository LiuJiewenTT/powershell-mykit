<#
功能：保存Win11当前桌面壁纸
1.优先读取原始图片；原图不存在自动读取系统缓存TranscodedWallpaper
2.自动保存到【桌面】，带时间戳 Wallpaper_yyyyMMdd_HHmmss.jpg
#>
# 输出路径：桌面
$destFolder = [Environment]::GetFolderPath("Desktop")
$timeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outFile = Join-Path $destFolder "Wallpaper_$timeStamp.jpg"

# 1.读取注册表原始壁纸路径
$regPath = "HKCU:\Control Panel\Desktop"
$origPath = (Get-ItemProperty -Path $regPath -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper

if (-not [string]::IsNullOrWhiteSpace($origPath) -and (Test-Path $origPath -PathType Leaf)) {
    # 原图存在：直接复制原图（保留原格式）
    $ext = [System.IO.Path]::GetExtension($origPath)
    $outFile = Join-Path $destFolder "Wallpaper_$timeStamp$ext"
    Copy-Item -Path $origPath -Destination $outFile -Force
    Write-Host "✅ 成功复制【原始原图】：$outFile"
}
else {
    # 原图已删除 → 使用系统转码缓存 TranscodedWallpaper
    $cacheFile = Join-Path $env:APPDATA "Microsoft\Windows\Themes\TranscodedWallpaper"
    if (Test-Path $cacheFile -PathType Leaf) {
        Copy-Item -Path $cacheFile -Destination $outFile -Force
        Write-Host "⚠️ 原始文件已丢失，使用系统缓存图片保存：$outFile"
    }
    else {
        Write-Host "❌ 错误：找不到壁纸缓存文件！"
        Read-Host "按回车关闭"
        exit 1
    }
}

# 自动打开保存目录
Start-Process $destFolder
Read-Host "执行完成，按回车退出"
