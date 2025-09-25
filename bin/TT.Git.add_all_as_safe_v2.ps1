param (
    [string]$ConfigFile = "$HOME\.git-safe-directories"
)

# 显示当前目录
$CurrentPath = Get-Location
Write-Host "`n🔍 当前目录是: $CurrentPath`n"

# 搜索所有隐藏的 .git 文件夹
$GitDirs = Get-ChildItem -Path $CurrentPath -Recurse -Directory -Force -Filter ".git"

# 提取仓库路径（即 .git 的父目录）
$RepoPaths = $GitDirs | ForEach-Object {
    $_.FullName.Substring(0, $_.FullName.Length - 4)
}

# 如果没有找到仓库，提示退出
if ($RepoPaths.Count -eq 0) {
    Write-Host "⚠️ 没有找到任何 Git 仓库，请确认目录是否正确。"
    exit
}

# 显示所有将要添加的路径
Write-Host "📦 找到以下 Git 仓库目录：`n"
$RepoPaths | ForEach-Object { Write-Host " - $_" }

# 显示目标配置文件路径和状态
try {
    $ResolvedPath = Resolve-Path -Path $ConfigFile -ErrorAction Stop
    $ConfigFileAbsolute = $ResolvedPath.Path
    Write-Host "`n📝 目标配置文件：" -NoNewline
    Write-Host "$ConfigFileAbsolute ✅ 已存在"
} catch {
    $ConfigFileAbsolute = [System.IO.Path]::GetFullPath($ConfigFile)
    Write-Host "`n📝 目标配置文件：" -NoNewline
    Write-Host "$ConfigFileAbsolute ❌ 不存在，将创建新文件"
}

# 用户确认
$confirmation = Read-Host "`n是否将以上路径追加到配置文件？输入 Y 继续，其他键退出"
if ($confirmation -ne "Y") {
    Write-Host "🚫 操作已取消。"
    exit
}

# 读取已有配置（如果存在）
$ExistingPaths = @()
if (Test-Path $ConfigFileAbsolute) {
    $ExistingLines = Get-Content $ConfigFileAbsolute | Where-Object { $_ -match '^\s*directory\s*=' }
    $ExistingPaths = $ExistingLines | ForEach-Object {
        ($_ -split '=')[1].Trim()
    }
}

$ExistingPathsUnescaped = $ExistingPaths | ForEach-Object { $_ -replace '\\\\', '\' } 

# 追加新路径（去重）
$NewPaths = $RepoPaths | Where-Object { $ExistingPathsUnescaped -notcontains $_ } 

# 检查是否已有 [safe] 区块
$HasSafeSection = $false
if (Test-Path $ConfigFileAbsolute) {
    $HasSafeSection = Get-Content $ConfigFileAbsolute | Where-Object { $_ -match '^\s*\[safe\]' }
}

# 写入逻辑（避免重复写入 [safe]）
if ($NewPaths.Count -eq 0) {
    Write-Host "✅ 所有路径已存在于配置文件中，无需添加。"
} else {
    if (-not $HasSafeSection) {
        Add-Content -Path $ConfigFileAbsolute -Value "`n[safe]"
    }
    foreach ($path in $NewPaths) {
        $escapedPath = $path -replace '\\', '\\'
        "    directory = $escapedPath" | Out-File -FilePath $ConfigFileAbsolute -Encoding UTF8 -Append
        Write-Host "✅ 已添加: $path"
    }
}

# 获取传入参数的绝对路径
$ConfigFileAbsolute = [System.IO.Path]::GetFullPath($ConfigFile)

# 获取 Git 中已有的 include.path 条目
$IncludePathsRaw = git config --global --get-all include.path
$IncludePathsResolved = @()

foreach ($raw in $IncludePathsRaw) {
    # 如果路径包含盘符（如 C:），说明是绝对路径
    if ($raw -match '^[a-zA-Z]:') {
        $IncludePathsResolved += $raw
    } else {
        # 相对路径或 ~ 开头 → 补上用户目录
        $resolved = Join-Path $env:USERPROFILE $raw
        $IncludePathsResolved += [System.IO.Path]::GetFullPath($resolved)
    }
}

# 比较是否已包含当前配置文件
if ($IncludePathsResolved -notcontains $ConfigFileAbsolute) {
    $addInclude = Read-Host "`n是否将该文件 include 到 ~/.gitconfig？输入 Y 添加，其他键跳过"
    if ($addInclude -eq "Y") {
        git config --global --add include.path "$ConfigFileAbsolute"
        Write-Host "📎 已添加 include.path 到 global 配置"
    }
}

Write-Host "`n🎉 操作完成！安全目录已整理完毕。"
