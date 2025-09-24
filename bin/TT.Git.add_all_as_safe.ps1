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

# 用户确认
$confirmation = Read-Host "`n是否将以上路径添加为 Git 安全目录？输入 Y 继续，其他键退出"

if ($confirmation -ne "Y") {
    Write-Host "🚫 操作已取消。"
    exit
}

# 添加到 Git 的 global 配置
foreach ($repo in $RepoPaths) {
    git config --global --add safe.directory "$repo"
    Write-Host "✅ 已添加: $repo"
}

Write-Host "`n🎉 所有路径已成功添加为安全目录！"
