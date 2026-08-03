<#
图片/文件哈希去重脚本 | 兼容 Windows PowerShell 5.1
功能：MD5比对，找出二进制完全相同的重复文件
策略：重复文件移动到隔离目录，不直接删除，防止误删
#>

# ===================== 配置区，自行修改 =====================
$ScanPath = $PWD.Path          # 扫描目录：当前目录
$Recurse = $true               # $true=扫描子文件夹  $false=仅本级目录
$TargetExts = @(".jpg",".jpeg",".png",".webp",".gif",".bmp",".tiff",".heic",".avif") # 只扫描这些后缀
$QuarantineDir = Join-Path $ScanPath "_重复文件隔离区" # 重复文件存放目录
# ==========================================================

# 创建隔离文件夹
if (-not (Test-Path $QuarantineDir)) {
    New-Item -Path $QuarantineDir -ItemType Directory | Out-Null
}

Write-Host "`n正在扫描文件并计算MD5哈希，请稍候..." -ForegroundColor Cyan

# 获取指定后缀文件
$files = Get-ChildItem -Path $ScanPath -File -Recurse:$Recurse | Where-Object {
    $TargetExts -contains $_.Extension.ToLower()
}

if ($files.Count -eq 0) {
    Write-Host "未找到匹配后缀的文件" -ForegroundColor Yellow
    Read-Host "回车退出"
    exit
}

# 哈希字典：key=md5值，value=文件路径数组
$hashDict = @{}
$hashProvider = [System.Security.Cryptography.MD5]::Create()

foreach ($f in $files) {
    try {
        $stream = [System.IO.File]::OpenRead($f.FullName)
        $md5Bytes = $hashProvider.ComputeHash($stream)
        $stream.Close()
        $md5Hex = [BitConverter]::ToString($md5Bytes).Replace("-", "").ToLower()

        if (-not $hashDict.ContainsKey($md5Hex)) {
            $hashDict[$md5Hex] = @()
        }
        $hashDict[$md5Hex] += $f.FullName
    }
    catch {
        Write-Host "读取失败：$($f.FullName)  $_" -ForegroundColor DarkGray
    }
}

# 筛选存在重复的组
$duplicateGroups = $hashDict.Values | Where-Object { $_.Count -gt 1 }

if ($duplicateGroups.Count -eq 0) {
    Write-Host "✅ 扫描完成，没有发现重复文件！" -ForegroundColor Green
    Read-Host "回车退出"
    exit
}

Write-Host "`n==================== 发现重复组预览 ====================" -ForegroundColor Yellow
$groupIndex = 1
foreach ($group in $duplicateGroups) {
    Write-Host "`n【重复组 $groupIndex】"
    Write-Host "✅ 保留: $($group[0])"
    for ($i = 1; $i -lt $group.Count; $i++) {
        Write-Host "❌ 待移动: $($group[$i])"
    }
    $groupIndex++
}

Write-Host "`n======================================================" -ForegroundColor Yellow
$confirm = Read-Host "确认将所有重复项移动至【_重复文件隔离区】？Y确认 / 其他退出"
if ($confirm.ToUpper() -ne "Y") {
    Write-Host "操作已取消"
    exit
}

# 执行移动
$moveCount = 0
foreach ($group in $duplicateGroups) {
    # 第0个保留，后面全部移动
    for ($i = 1; $i -lt $group.Count; $i++) {
        $src = $group[$i]
        $fileName = Split-Path $src -Leaf
        $dst = Join-Path $QuarantineDir $fileName

        # 隔离目录重名冲突处理，增加时间戳
        if (Test-Path $dst) {
            $ts = Get-Date -Format "HHmmssfff"
            $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $ext = [System.IO.Path]::GetExtension($fileName)
            $dst = Join-Path $QuarantineDir "$nameNoExt`_$ts$ext"
        }
        Move-Item -Path $src -Destination $dst
        Write-Host "✔️ 已移动：$fileName"
        $moveCount++
    }
}

Write-Host "`n操作完成！总共移动 $moveCount 个重复文件" -ForegroundColor Green
Write-Host "隔离目录：$QuarantineDir"
Read-Host "按回车关闭"
