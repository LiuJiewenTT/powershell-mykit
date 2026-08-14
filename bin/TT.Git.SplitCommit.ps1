<#
.SYNOPSIS
    Git 暂存区拆分提交工具 - 按字节大小自动分批提交（支持 hunk 级及行级切分）
.DESCRIPTION
    将当前暂存区（staged）的变更按 UTF-8 字节大小拆分为多个提交，
    每个提交不超过指定字节上限。提交注释自动追加序号后缀。

      用户命令:
        Split-GitStagedCommit - 将暂存区按字节大小拆分为多个提交

    工作流程:
      1. 获取暂存区文件列表（git diff --cached --name-only）
      2. 逐文件计算 UTF-8 新增字节数
      3. 贪心装箱：累加文件字节，不超过 MaxBytes 则放入当前批，否则新开一批
      4. 超限文件自动按 hunk 切分，分多次提交
      5. 单个 hunk 超限时，在 hunk 内部按 +行 贪心拆分为多个子 hunk
      6. 逐批提交：整文件用 blob hash + update-index，hunk 切分用 hash-object + update-index

    行级切分规则:
      - 修改型 hunk：第一个子 hunk 保留 - 行（完成删除），后续子 hunk OldCount=0（纯插入）
      - 新增型 hunk：直接按 +行 分组
      - \ No newline at end of file 只附在最后一个子 hunk
      - 拆分后的子 hunk 无缝接入现有 hunk 提交流程

    参数说明:
      -MaxBytes    → 每个提交的字节上限（必填，单位：字节）
      -Message     → 提交注释前缀（必填），实际注释为 "前缀 #序号"
      -DryRun      → 仅模拟分批结果，不执行 git add / commit
      -Help        → 显示完整帮助（等同 Get-Help -Full）

    未暂存改动保护:
      - 所有操作仅针对暂存区，不修改工作区文件
      - git commit 只提交暂存区内容，工作区改动不受影响
      - 无需 stash，无需 stash pop
      - 执行前保存完整 diff 到 .git/TT.ToolKit/split-tmp/，出错可恢复

    临时文件:
      - 临时文件存放在 .git/TT.ToolKit/split-tmp/（Git 内部目录，天然被忽略）
      - 文件名含 PID 和时间戳，防止并发冲突
      - 正常完成后自动清理；异常退出时保留，可用于手动恢复

    注意事项:
      - 操作对象仅为暂存区（staged），不涉及工作区未跟踪文件
      - 不会执行 git push，仅本地提交
      - 单个文件字节超上限时，自动按 hunk 切分多次提交
      - 单个 hunk 也超限时，在 hunk 内部按 +行 贪心拆分（行级切分）
      - 二进制文件无法切分，超限时独立成一批提交
      - 支持新增文件和修改已有文件
.NOTES
    兼容 PowerShell 5.1，无额外模块依赖

    dot-source 加载后可用:
      Split-GitStagedCommit -MaxBytes <字节数> -Message <前缀> [-DryRun] [-Help]
.EXAMPLE
    . G:\path\TT.Git.SplitCommit.ps1
    Split-GitStagedCommit -MaxBytes 10240 -Message "feature: 新增模块"
    Split-GitStagedCommit -MaxBytes 5120 -Message "feat" -DryRun
    Split-GitStagedCommit -MaxBytes 10000 -Message "refactor" -Help
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [long]$MaxBytes,

    [Parameter(Position = 1)]
    [string]$Message,

    [switch]$DryRun,

    [switch]$Help
)


# ============================================================
# 内部辅助函数
# ============================================================

# 检查当前目录是否在 Git 仓库内
# 通过文件系统查找 .git，避免 git 输出在代码页 936 下中文路径乱码
function __GitSplit_CheckRepo {
    $dir = __GitSplit_FindRepoRoot
    if ([string]::IsNullOrWhiteSpace($dir)) {
        Write-Host "错误：当前目录不在 Git 仓库中" -ForegroundColor Red
        return $false
    }
    return $true
}

# 从当前目录向上查找 .git，返回仓库根目录（空字符串表示未找到）
# 纯文件系统操作，不受代码页/编码影响
function __GitSplit_FindRepoRoot {
    $dir = (Get-Location).Path
    while (-not [string]::IsNullOrEmpty($dir)) {
        if (Test-Path (Join-Path $dir '.git') -PathType Container) {
            return $dir
        }
        # .git 也可能是文件（worktree 指向实际 .git 目录）
        if (Test-Path (Join-Path $dir '.git') -PathType Leaf) {
            return $dir
        }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return ''
}


# 检查暂存区是否有内容
function __GitSplit_HasStagedChanges {
    $lines = __GitSplit_RunGitNameLines -Arguments "diff --cached --name-only"
    if ($null -eq $lines) {
        Write-Host "错误：无法获取暂存区文件列表" -ForegroundColor Red
        Write-Host "请确认当前目录在 Git 仓库中，且有暂存区内容" -ForegroundColor Red
        return $false
    }
    if ($lines.Count -eq 0) {
        Write-Host "暂存区为空，没有需要拆分的内容" -ForegroundColor Yellow
        return $false
    }
    return $true
}


# 通过 .NET Process 执行 git 命令，返回原始字节数组
# 绕过 PS 5.1 管道编码转换（代码页 936 下中文内容会损坏）
function __GitSplit_RunGitBytes {
    param([string]$Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Get-Location).Path

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.Start() | Out-Null

    $ms = New-Object System.IO.MemoryStream
    $process.StandardOutput.BaseStream.CopyTo($ms)
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        $ms.Dispose()
        return $null
    }

    $bytes = $ms.ToArray()
    $ms.Dispose()
    return $bytes
}


# 获取 git diff --cached 的行数组（UTF-8 正确解码）
# 返回 $null 表示失败，@() 表示无内容
function __GitSplit_GetDiffLines {
    param(
        [string]$FilePath,
        [switch]$U0
    )

    $args = "diff --cached"
    if ($U0) { $args += " -U0" }
    $args += " -- `"$FilePath`""

    $bytes = __GitSplit_RunGitBytes -Arguments $args
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return @() }

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $content = $utf8NoBom.GetString($bytes)

    # 统一换行为 LF
    $content = $content -replace "`r`n", "`n"
    # 去尾换行
    if ($content.EndsWith("`n")) {
        $content = $content.Substring(0, $content.Length - 1)
    }

    if ([string]::IsNullOrEmpty($content)) { return @() }
    return @($content -split "`n")
}


# 获取 git diff --cached（无文件过滤）的行数组
# 用于 IsBinaryFile 等不需要 -U0 的场景
function __GitSplit_GetDiffLinesFull {
    param([string]$FilePath)

    $bytes = __GitSplit_RunGitBytes -Arguments "diff --cached -- `"$FilePath`""
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return @() }

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $content = $utf8NoBom.GetString($bytes)

    $content = $content -replace "`r`n", "`n"
    if ($content.EndsWith("`n")) {
        $content = $content.Substring(0, $content.Length - 1)
    }

    if ([string]::IsNullOrEmpty($content)) { return @() }
    return @($content -split "`n")
}


# 通过 .NET Process 执行 git 命令，返回行数组（UTF-8 解码，过滤空行）
# 适用于 --name-only / --name-status 等简单输出
# 返回 $null 表示命令失败，@() 表示无输出
function __GitSplit_RunGitNameLines {
    param([string]$Arguments)

    $bytes = __GitSplit_RunGitBytes -Arguments $Arguments
    if ($null -eq $bytes) { return $null }
    if ($bytes.Length -eq 0) { return @() }

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $content = $utf8NoBom.GetString($bytes)

    $content = $content -replace "`r`n", "`n"
    if ($content.EndsWith("`n")) {
        $content = $content.Substring(0, $content.Length - 1)
    }

    if ([string]::IsNullOrEmpty($content)) { return @() }

    # 过滤空行，返回非空行数组
    $lines = @($content -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return $lines
}


function __GitSplit_GetFileBytes {
    param([string]$FilePath)

    $diff = __GitSplit_GetDiffLines -FilePath $FilePath -U0
    if ($null -eq $diff -or $diff.Count -eq 0) {
        return 0
    }

    $utf8 = [System.Text.Encoding]::UTF8
    $addByte = 0

    foreach ($line in $diff) {
        if ($line -match '^\+' -and $line -notmatch '^\+{3}') {
            $content = $line.Substring(1)
            $addByte += $utf8.GetByteCount($content)
        }
    }

    return $addByte
}


# 检查文件是否为二进制文件
function __GitSplit_IsBinaryFile {
    param([string]$FilePath)

    $diff = __GitSplit_GetDiffLinesFull -FilePath $FilePath
    if ($null -eq $diff -or $diff.Count -eq 0) {
        return $false
    }
    foreach ($line in ($diff | Select-Object -First 5)) {
        if ($line -match 'Binary files') {
            return $true
        }
    }
    return $false
}


# 获取文件的 diff 头部（diff --git / index / --- / +++）
# 截取第一个 @@ 之前的所有行
function __GitSplit_GetFileDiffHeader {
    param([string]$FilePath)

    $diff = __GitSplit_GetDiffLines -FilePath $FilePath -U0
    if ($null -eq $diff -or $diff.Count -eq 0) {
        return $null
    }

    $header = [System.Collections.ArrayList]::new()
    foreach ($line in $diff) {
        if ($line -match '^@@') { break }
        $null = $header.Add($line)
    }

    return $header
}


# 解析文件的 diff 为 hunk 列表
# 每个 hunk 包含:
#   AtHeader    @@ 行
#   Lines       hunk 的所有 diff 行（- + \ No newline）
#   AddBytes    +行 UTF-8 字节数
#   OldStart    旧行起始号（1-based，0 表示新文件）
#   OldCount    旧行数
#   NoNewlineOld  旧版本末尾无换行
#   NoNewlineNew  新版本末尾无换行
function __GitSplit_ParseHunks {
    param([string]$FilePath)

    $diff = __GitSplit_GetDiffLines -FilePath $FilePath -U0
    if ($null -eq $diff -or $diff.Count -eq 0) {
        return @()
    }

    $utf8 = [System.Text.Encoding]::UTF8
    $header = __GitSplit_GetFileDiffHeader -FilePath $FilePath
    if ($null -eq $header -or $header.Count -eq 0) { return @() }

    $headerLineCount = $header.Count
    $hunks = [System.Collections.ArrayList]::new()
    $currentHunkLines = [System.Collections.ArrayList]::new()
    $currentAtHeader = ""
    $currentAddBytes = 0
    $inHunk = $false
    $lineIndex = 0

    foreach ($line in $diff) {
        $lineIndex++
        if ($lineIndex -le $headerLineCount) { continue }

        if ($line -match '^@@') {
            # 遇到新 @@ 头，保存上一个 hunk
            if ($inHunk -and $currentHunkLines.Count -gt 0) {
                $null = $hunks.Add((__GitSplit_FinalizeHunk $currentAtHeader $currentHunkLines $currentAddBytes))
            }
            $currentAtHeader = $line
            $currentHunkLines = [System.Collections.ArrayList]::new()
            $currentAddBytes = 0
            $inHunk = $true
            continue
        }

        if ($inHunk) {
            $null = $currentHunkLines.Add($line)
            if ($line -match '^\+' -and $line -notmatch '^\+{3}') {
                $currentAddBytes += $utf8.GetByteCount($line.Substring(1))
            }
        }
    }

    # 保存最后一个 hunk
    if ($inHunk -and $currentHunkLines.Count -gt 0) {
        $null = $hunks.Add((__GitSplit_FinalizeHunk $currentAtHeader $currentHunkLines $currentAddBytes))
    }

    return $hunks
}


# 从 @@ 头和 diff 行构建 hunk 对象
function __GitSplit_FinalizeHunk {
    param([string]$AtHeader, [System.Collections.ArrayList]$Lines, [long]$AddBytes)

    # 解析 @@ -oldStart[,oldCount] +newStart[,newCount] @@
    $oldStart = 0
    $oldCount = 0
    if ($AtHeader -match '^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@') {
        $oldStart = [int]$Matches[1]
        $oldCount = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
    }

    # 检测 \ No newline 标记
    $noNewlineOld = $false
    $noNewlineNew = $false
    $seenPlus = $false
    foreach ($l in $Lines) {
        if ($l -match '^\+' -and $l -notmatch '^\+{3}') { $seenPlus = $true }
        if ($l -match '^\\ No newline') {
            if ($seenPlus) { $noNewlineNew = $true }
            else { $noNewlineOld = $true }
        }
    }

    return [PSCustomObject]@{
        AtHeader     = $AtHeader
        Lines        = $Lines.ToArray()
        AddBytes     = $AddBytes
        OldStart     = $oldStart
        OldCount     = $oldCount
        NoNewlineOld = $noNewlineOld
        NoNewlineNew = $noNewlineNew
    }
}


# 将超限的单个 hunk 按 +行 贪心拆分为多个子 hunk
# 参数:
#   Hunk      待拆分的 hunk 对象（来自 __GitSplit_ParseHunks / __GitSplit_FinalizeHunk）
#   MaxBytes  每个子 hunk 的字节上限
# 返回: 子 hunk 数组（每个子 hunk 都是标准的 hunk 对象）
#
# 拆分规则:
#   - 修改型 hunk（OldCount > 0）: 第一个子 hunk 保留 - 行（完成删除），后续子 hunk
#     的 OldCount=0（纯插入，不需要先删除旧行）
#   - 新增型 hunk（OldStart=0）: 直接按 +行 分组
#   - 每个子 hunk 生成自己的 @@ 头
#   - \ No newline at end of file 只附在最后一个子 hunk
#
# 重要：后续子 hunk 的 OldStart 基于"前一个子 hunk 提交后的 HEAD 行号"计算，
# 而非原始 hunk 的旧行号。这是因为每次提交后 HEAD 已经改变，
# 后续子 hunk 必须基于新的 HEAD 定位插入位置。
#
# 具体计算:
#   - 第一个子 hunk: OldStart = 原始 oldStart, OldCount = 原始 oldCount
#   - 第 k 个子 hunk (k>0): OldStart = 原始 oldStart + sum(前 k 个子 hunk 的 +行数) - 1
#     （因为第一个子 hunk 删除了 oldCount 行并插入了 N1 行，
#       HEAD 中该区域变成了 N1 行，所以下一个插入点在第 N1 行之后）
function __GitSplit_SplitSingleHunk {
    param(
        [object]$Hunk,
        [long]$MaxBytes
    )

    $utf8 = [System.Text.Encoding]::UTF8

    # 提取 + 行及其字节数
    $addLines = [System.Collections.ArrayList]::new()
    $addLineBytes = [System.Collections.ArrayList]::new()
    foreach ($line in $Hunk.Lines) {
        if ($line -match '^\+' -and $line -notmatch '^\+{3}') {
            $content = $line.Substring(1)
            $null = $addLines.Add($content)
            $null = $addLineBytes.Add($utf8.GetByteCount($content))
        }
    }

    # 提取 - 行（仅第一个子 hunk 需要）
    $removeLines = [System.Collections.ArrayList]::new()
    foreach ($line in $Hunk.Lines) {
        if ($line -match '^-' -and $line -notmatch '^-{3}') {
            $null = $removeLines.Add($line.Substring(1))
        }
    }

    # 如果 + 行数 <= 1，无法再拆分，直接返回原 hunk
    if ($addLines.Count -le 1) {
        return @($Hunk)
    }

    # 贪心分组：将 + 行按 MaxBytes 分成多组
    # 每组: @{ StartIndex, Count, Bytes }
    $groups = [System.Collections.ArrayList]::new()
    $gStart = 0
    $gBytes = 0

    for ($i = 0; $i -lt $addLines.Count; $i++) {
        $lb = $addLineBytes[$i]
        if ($gStart -eq $i) {
            # 当前组的第一行，必须放入（即使超限）
            $gBytes = $lb
        }
        elseif ($gBytes + $lb -le $MaxBytes) {
            $gBytes += $lb
        }
        else {
            # 结束当前组，开新组
            $null = $groups.Add([PSCustomObject]@{ StartIndex = $gStart; Count = $i - $gStart; Bytes = $gBytes })
            $gStart = $i
            $gBytes = $lb
        }
    }
    # 最后一组
    if ($gStart -lt $addLines.Count) {
        $null = $groups.Add([PSCustomObject]@{ StartIndex = $gStart; Count = $addLines.Count - $gStart; Bytes = $gBytes })
    }

    # 只分出1组 → 无需拆分
    if ($groups.Count -le 1) {
        return @($Hunk)
    }

    # 解析原始 @@ 头中的 OldStart / OldCount
    $oldStart = $Hunk.OldStart
    $oldCount = $Hunk.OldCount

    # 构建子 hunk 列表
    $subHunks = [System.Collections.ArrayList]::new()

    for ($gi = 0; $gi -lt $groups.Count; $gi++) {
        $g = $groups[$gi]
        $subLines = [System.Collections.ArrayList]::new()
        $subAddBytes = 0

        if ($gi -eq 0 -and $removeLines.Count -gt 0) {
            # 第一个子 hunk：包含 - 行（删除旧行），然后是第一组 + 行
            foreach ($rl in $removeLines) {
                $null = $subLines.Add("-$rl")
            }
        }

        # 添加本组的 + 行
        for ($j = $g.StartIndex; $j -lt $g.StartIndex + $g.Count; $j++) {
            $null = $subLines.Add("+$($addLines[$j])")
            $subAddBytes += $addLineBytes[$j]
        }

        # \ No newline 标记处理
        if ($gi -eq $groups.Count - 1 -and $Hunk.NoNewlineNew) {
            $null = $subLines.Add('\ No newline at end of file')
        }
        if ($gi -eq 0 -and $groups.Count -gt 1 -and $Hunk.NoNewlineOld) {
            $null = $subLines.Add('\ No newline at end of file')
        }

        # 构造 @@ 头
        # 后续子 hunk 的 OldStart 基于前一个子 hunk 提交后的 HEAD 行号：
        #   第一个子 hunk 提交后，原区域变成 N1 行（第一组+行数），
        #   所以第二个子 hunk 应在 oldStart-1+N1 位置之后插入，
        #   即 OldStart = oldStart - 1 + N1 + 1 = oldStart + N1
        if ($gi -eq 0) {
            $subOldStart = $oldStart
            $subOldCount = $oldCount
        }
        else {
            # 计算前面所有子 hunk 的 +行总数
            $prevAddLines = 0
            for ($pk = 0; $pk -lt $gi; $pk++) {
                $prevAddLines += $groups[$pk].Count
            }
            $subOldStart = $oldStart + $prevAddLines
            $subOldCount = 0
        }
        $subNewCount = $g.Count

        # 计算 NewStart
        if ($gi -eq 0) {
            $subNewStart = $oldStart
        }
        else {
            $prevAddLines2 = 0
            for ($pk = 0; $pk -lt $gi; $pk++) {
                $prevAddLines2 += $groups[$pk].Count
            }
            $subNewStart = $oldStart + $prevAddLines2
        }

        # 构造 @@ 头字符串
        if ($subOldCount -eq 0) {
            if ($subOldStart -eq 0) {
                $atHeader = "@@ -0,0 +$subNewStart,$subNewCount @@"
            }
            else {
                $atHeader = "@@ -$subOldStart +$subNewStart,$subNewCount @@"
            }
        }
        else {
            $atHeader = "@@ -$subOldStart,$subOldCount +$subNewStart,$subNewCount @@"
        }

        $subHunk = [PSCustomObject]@{
            AtHeader     = $atHeader
            Lines        = $subLines.ToArray()
            AddBytes     = $subAddBytes
            OldStart     = $subOldStart
            OldCount     = $subOldCount
            NoNewlineOld = ($gi -eq 0 -and $Hunk.NoNewlineOld -and $groups.Count -gt 1)
            NoNewlineNew = ($gi -eq $groups.Count - 1 -and $Hunk.NoNewlineNew)
        }

        $null = $subHunks.Add($subHunk)
    }

    return $subHunks.ToArray()
}


# 将超限文件按 hunk 贪心分批
# 每个 hunk batch 包含: FilePath, Hunks, AddBytes
# 对超限的单个 hunk，调用 __GitSplit_SplitSingleHunk 按行拆分
function __GitSplit_SplitFileByHunks {
    param(
        [string]$FilePath,
        [long]$MaxBytes
    )

    $hunks = __GitSplit_ParseHunks -FilePath $FilePath
    if ($null -eq $hunks -or $hunks.Count -eq 0) {
        return @()
    }

    # 对超限的单个 hunk 按行拆分
    $expandedHunks = [System.Collections.ArrayList]::new()
    foreach ($hunk in $hunks) {
        if ($hunk.AddBytes -gt $MaxBytes) {
            $subHunks = __GitSplit_SplitSingleHunk -Hunk $hunk -MaxBytes $MaxBytes
            foreach ($sh in $subHunks) {
                $null = $expandedHunks.Add($sh)
            }
        }
        else {
            $null = $expandedHunks.Add($hunk)
        }
    }

    # 用展开后的 hunk 列表进行贪心分批
    $hunkBatches = [System.Collections.ArrayList]::new()
    $currentHunks = [System.Collections.ArrayList]::new()
    $currentBytes = 0

    foreach ($hunk in $expandedHunks) {
        if ($currentHunks.Count -eq 0) {
            $null = $currentHunks.Add($hunk)
            $currentBytes = $hunk.AddBytes
            continue
        }

        if ($currentBytes + $hunk.AddBytes -le $MaxBytes) {
            $null = $currentHunks.Add($hunk)
            $currentBytes += $hunk.AddBytes
        }
        else {
            $null = $hunkBatches.Add([PSCustomObject]@{
                FilePath = $FilePath
                Hunks    = $currentHunks.ToArray()
                AddBytes = $currentBytes
            })
            $currentHunks = [System.Collections.ArrayList]::new()
            $null = $currentHunks.Add($hunk)
            $currentBytes = $hunk.AddBytes
        }
    }

    if ($currentHunks.Count -gt 0) {
        $null = $hunkBatches.Add([PSCustomObject]@{
            FilePath = $FilePath
            Hunks    = $currentHunks.ToArray()
            AddBytes = $currentBytes
        })
    }

    return $hunkBatches
}


# 贪心装箱：将文件列表按字节上限分批
function __GitSplit_GreedyPack {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$FileList,

        [Parameter(Mandatory)]
        [long]$MaxBytes
    )

    if (-not $FileList -or $FileList.Count -eq 0) {
        return @()
    }

    $fileBytes = @()
    foreach ($f in $FileList) {
        $bytes = __GitSplit_GetFileBytes -FilePath $f
        $fileBytes += [PSCustomObject]@{
            Path  = $f
            Bytes = $bytes
        }
    }

    $batches = @()
    $currentBatch = @()
    $currentBytes = 0

    foreach ($fb in $fileBytes) {
        if ($currentBatch.Count -eq 0) {
            $currentBatch += $fb.Path
            $currentBytes = $fb.Bytes
            continue
        }

        if ($currentBytes + $fb.Bytes -le $MaxBytes) {
            $currentBatch += $fb.Path
            $currentBytes += $fb.Bytes
        }
        else {
            $batches += ,@($currentBatch)
            $currentBatch = @($fb.Path)
            $currentBytes = $fb.Bytes
        }
    }

    if ($currentBatch.Count -gt 0) {
        $batches += ,@($currentBatch)
    }

    return ,$batches
}


# 获取暂存区文件的 mode 和 blob hash
# 返回 @{Status='A'|'M'|'D'; Mode='100644'; Hash='abc123'} 或 $null
function __GitSplit_GetStagedFileInfo {
    param([string]$FilePath)

    $statusLines = __GitSplit_RunGitNameLines -Arguments "diff --cached --name-status -- `"$FilePath`""
    if ($null -eq $statusLines -or $statusLines.Count -eq 0) {
        return $null
    }

    $statusLine = $statusLines[0]

    $statusChar = ($statusLine -split "`t")[0]
    if ($statusChar.StartsWith('D')) {
        return @{ Status = 'D'; Mode = $null; Hash = $null; Path = $FilePath }
    }

    $line = git ls-files -s -- $FilePath 2>$null
    if ($null -eq $line -or $line.Count -eq 0) {
        return $null
    }

    $parts = $line.Trim() -split '\s+'
    if ($parts.Count -ge 2) {
        return @{ Status = $statusChar; Mode = $parts[0]; Hash = $parts[1]; Path = $FilePath }
    }
    return $null
}


# 获取 HEAD 版本文件内容（原始字节）
# 使用 .NET Process 避免 PowerShell 编码转换
function __GitSplit_GetHeadContentBytes {
    param([string]$FilePath)

    # 检查文件是否在 HEAD 中存在
    $null = git rev-parse "HEAD:$FilePath" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [byte[]]@()
    }

    $bytes = __GitSplit_RunGitBytes -Arguments "cat-file -p HEAD:$FilePath"
    if ($null -eq $bytes) {
        return [byte[]]@()
    }
    return $bytes
}


# 将 hunk 变更应用到 HEAD 内容，生成中间状态内容
# 参数:
#   HeadBytes   HEAD 版本的原始字节
#   AllHunks    该文件的所有 hunk（按顺序）
#   UpToIndex   应用 hunk 0..UpToIndex（含）
# 返回: 应用后的内容字节（保留原始 BOM 和行尾格式）
function __GitSplit_ApplyHunksToContent {
    param(
        [byte[]]$HeadBytes,
        [object[]]$AllHunks,
        [int]$UpToIndex
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false

    # ---- 检测原始字节的 BOM 和行尾特征 ----
    $hasBom = ($HeadBytes.Length -ge 3 -and $HeadBytes[0] -eq 0xEF -and $HeadBytes[1] -eq 0xBB -and $HeadBytes[2] -eq 0xBF)
    $hasCrlf = $false
    for ($b = 0; $b -lt $HeadBytes.Length - 1; $b++) {
        if ($HeadBytes[$b] -eq 0x0D -and $HeadBytes[$b + 1] -eq 0x0A) {
            $hasCrlf = $true
            break
        }
    }

    # 字节转字符串（UTF8Encoding 自动吞掉 BOM，不影响后续操作）
    if ($HeadBytes.Length -eq 0) {
        $content = ""
    } else {
        $content = $utf8NoBom.GetString($HeadBytes)
    }

    # 判断是否有尾换行
    $hasTrailingNewline = $content.EndsWith("`n")

    # 统一换行为 LF（仅用于行操作，输出时按原格式恢复）
    $content = $content -replace "`r`n", "`n"

    # 去掉尾部换行以便按行处理
    if ($content.EndsWith("`n")) {
        $content = $content.Substring(0, $content.Length - 1)
    }

    # 拆分为行
    if ([string]::IsNullOrEmpty($content)) {
        $lines = [System.Collections.ArrayList]::new()
    } else {
        $lines = [System.Collections.ArrayList]@($content -split "`n")
    }

    $offset = 0

    for ($i = 0; $i -le $UpToIndex; $i++) {
        $hunk = $AllHunks[$i]

        $oldStart = $hunk.OldStart
        $oldCount = $hunk.OldCount

        # 在当前结果中的位置（0-based）
        # 新文件 hunk 的 OldStart=0（@@ -0,0 +1,N @@），pos 应为 0
        # OldCount=0 的纯插入 hunk：OldStart 表示"在第 OldStart 行之后插入"，pos = OldStart + offset
        # OldCount>0 的替换 hunk：pos = OldStart - 1 + offset（0-based 起始位置）
        if ($oldStart -eq 0) {
            $pos = 0 + $offset
        } elseif ($oldCount -eq 0) {
            # 纯插入：在第 oldStart 行之后插入，0-based 就是 oldStart
            $pos = $oldStart + $offset
        } else {
            $pos = $oldStart - 1 + $offset
        }

        # 确保 pos 在有效范围内
        if ($pos -lt 0) { $pos = 0 }
        if ($pos -gt $lines.Count) { $pos = $lines.Count }

        # 收集 + 行（新内容）
        $newLines = [System.Collections.ArrayList]::new()
        foreach ($line in $hunk.Lines) {
            if ($line -match '^\+' -and $line -notmatch '^\+{3}') {
                $null = $newLines.Add($line.Substring(1))
            }
        }

        # 删除旧行
        $removeCount = [Math]::Min($oldCount, [Math]::Max(0, $lines.Count - $pos))
        if ($removeCount -gt 0) {
            $lines.RemoveRange($pos, $removeCount)
        }

        # 插入新行
        for ($j = 0; $j -lt $newLines.Count; $j++) {
            $lines.Insert($pos + $j, $newLines[$j])
        }

        # 更新偏移
        $offset += ($newLines.Count - $oldCount)

        # 追踪尾换行状态
        if ($hunk.NoNewlineNew) {
            $hasTrailingNewline = $false
        } elseif ($hunk.NoNewlineOld) {
            $hasTrailingNewline = $true
        } elseif ($HeadBytes.Length -eq 0 -and $newLines.Count -gt 0) {
            # 新文件且有 + 行，默认有尾换行（除非 NoNewlineNew 已处理）
            $hasTrailingNewline = $true
        }
    }

    # 重建内容（用 LF 连接）
    $result = $lines -join "`n"
    if ($hasTrailingNewline -and $lines.Count -gt 0) {
        $result += "`n"
    }

    # ---- 恢复原始行尾格式 ----
    if ($hasCrlf) {
        # LF → CRLF（仅转换行间的 \n，不触碰行内容中的裸 \n）
        $result = $result -replace "(?<!\r)\n", "`r`n"
    }

    # 编码为字节
    $bytes = $utf8NoBom.GetBytes($result)

    # ---- 恢复 BOM ----
    if ($hasBom) {
        $bomBytes = [byte[]]@(0xEF, 0xBB, 0xBF)
        $combined = New-Object byte[] ($bomBytes.Length + $bytes.Length)
        [Array]::Copy($bomBytes, 0, $combined, 0, $bomBytes.Length)
        [Array]::Copy($bytes, 0, $combined, $bomBytes.Length, $bytes.Length)
        $bytes = $combined
    }

    return $bytes
}


# 临时文件路径管理
function __GitSplit_GetTempDir {
    $repoRoot = __GitSplit_FindRepoRoot
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        return $env:TEMP
    }
    # 使用 .git/TT.ToolKit/split-tmp/ —— Git 内部目录，天然被忽略，不依赖项目 .gitignore
    $gitDir = Join-Path $repoRoot ".git\TT.ToolKit\split-tmp"
    if (-not (Test-Path $gitDir)) {
        $null = New-Item -ItemType Directory -Path $gitDir -Force
    }
    return $gitDir
}

function __GitSplit_GetTempFile {
    param([string]$Suffix = "patch")

    $tmpDir = __GitSplit_GetTempDir
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $mypid = $PID
    $rnd = Get-Random -Maximum 9999
    $fileName = "split-$mypid-$ts-$rnd.$Suffix"
    return Join-Path $tmpDir $fileName
}

# 清理临时目录中超过 1 天的残留文件
function __GitSplit_CleanStaleTemp {
    $tmpDir = __GitSplit_GetTempDir
    if (-not (Test-Path $tmpDir)) { return }

    $cutoff = (Get-Date).AddDays(-1)
    Get-ChildItem $tmpDir -Filter "split-*" | Where-Object {
        $_.LastWriteTime -lt $cutoff
    } | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# 清理空的临时目录：split-tmp/ 为空则删除，TT.ToolKit/ 为空也删除
function __GitSplit_CleanEmptyTempDirs {
    $repoRoot = __GitSplit_FindRepoRoot
    if ([string]::IsNullOrWhiteSpace($repoRoot)) { return }

    $splitTmp = Join-Path $repoRoot ".git\TT.ToolKit\split-tmp"
    $toolKit  = Join-Path $repoRoot ".git\TT.ToolKit"

    # split-tmp 为空则删除
    if ((Test-Path $splitTmp) -and (Get-ChildItem $splitTmp -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item $splitTmp -Force -ErrorAction SilentlyContinue
    }
    # TT.ToolKit 为空则删除（可能被其他脚本共享，只删空目录不影响）
    if ((Test-Path $toolKit) -and (Get-ChildItem $toolKit -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item $toolKit -Force -ErrorAction SilentlyContinue
    }
}


# 帮助请求拦截
function __GitSplit_HelpInterceptor {
    param(
        [string]$CommandName,
        [switch]$Help
    )

    if ($Help) {
        Get-Help $CommandName -Full | Out-Host
        return $true
    }
    return $false
}


# 打印区块分隔标题
function __GitSplit_WriteHeader {
    param([string]$Title, [System.ConsoleColor]$Color = 'White')
    Write-Host ""
    Write-Host "================ [$Title] ================" -ForegroundColor $Color
    Write-Host ""
}


# ============================================================
# 主函数: Split-GitStagedCommit
# ============================================================
function Split-GitStagedCommit {
    <#
    .SYNOPSIS
        将暂存区按字节大小拆分为多个提交（支持 hunk 级及行级切分）
    .DESCRIPTION
        获取暂存区所有文件，按 UTF-8 新增字节贪心分批，
        每批不超过 -MaxBytes 指定的上限，提交注释自动追加 #序号。
        超限文件自动按 hunk 切分，分多次提交。
        单个 hunk 超限时，在 hunk 内部按 +行 贪心拆分为多个子 hunk（行级切分）。

        所有操作仅针对暂存区，不修改工作区文件，
        未暂存改动全程保留，无需 stash。
        执行前保存完整 diff 到临时文件，出错可恢复。

        不会执行 git push。
    .EXAMPLE
        Split-GitStagedCommit -MaxBytes 10240 -Message "feature: 新增模块"
        Split-GitStagedCommit -MaxBytes 5120 -Message "feat" -DryRun
        Split-GitStagedCommit -MaxBytes 10000 -Message "refactor" -Help
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [long]$MaxBytes,

        [Parameter(Position = 1)]
        [string]$Message,

        [switch]$DryRun,

        [switch]$Help
    )

    if (__GitSplit_HelpInterceptor -CommandName 'Split-GitStagedCommit' -Help:$Help) { return }
    if (-not (__GitSplit_CheckRepo)) { return }

    # 切换到仓库根目录，确保所有 git 命令使用仓库根相对路径
    # 子目录运行时 git diff --cached --name-only 只返回当前子目录的文件，
    # 需要在根目录才能获取完整的暂存区文件列表
    # 使用文件系统查找而非 git 输出，避免代码页 936 下中文路径乱码
    $repoRoot = __GitSplit_FindRepoRoot
    $pushedLocation = $false
    if (-not [string]::IsNullOrWhiteSpace($repoRoot)) {
        # 规范化路径后再比较（消除尾随反斜杠差异）
        $currentDirNorm = ((Get-Location).Path).TrimEnd('\')
        $repoRootNorm = $repoRoot.TrimEnd('\')
        if ($currentDirNorm -ne $repoRootNorm) {
            Push-Location $repoRoot
            $pushedLocation = $true
        }
    }

    try {
    if (-not (__GitSplit_HasStagedChanges)) { return }

    if ($MaxBytes -le 0) {
        Write-Host "错误：-MaxBytes 必须大于 0" -ForegroundColor Red
        return
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Host "错误：-Message 不能为空" -ForegroundColor Red
        return
    }

    # 清理过期临时文件
    __GitSplit_CleanStaleTemp

    # 获取暂存区文件列表
    $stagedFiles = __GitSplit_RunGitNameLines -Arguments "diff --cached --name-only"
    if ($null -eq $stagedFiles) {
        Write-Host "错误：无法获取暂存区文件列表" -ForegroundColor Red
        return
    }
    if ($stagedFiles.Count -eq 0) {
        Write-Host "暂存区为空" -ForegroundColor Yellow
        return
    }

    # 保存暂存区文件信息（mode + blob hash），reset 后需要
    $stagedInfo = @{}
    foreach ($f in $stagedFiles) {
        $stagedInfo[$f] = __GitSplit_GetStagedFileInfo -FilePath $f
    }

    Write-Host ""
    Write-Host "暂存区共 $($stagedFiles.Count) 个文件，字节上限: $MaxBytes" -ForegroundColor Cyan
    Write-Host "提交注释前缀: $Message" -ForegroundColor Cyan
    Write-Host ""

    # 贪心分批
    $batches = __GitSplit_GreedyPack -FileList $stagedFiles -MaxBytes $MaxBytes

    if ($batches.Count -eq 0) {
        Write-Host "没有可分批的文件" -ForegroundColor Yellow
        return
    }

    # ---- 构建提交计划 ----
    $commitPlan = [System.Collections.ArrayList]::new()
    $seq = 0

    for ($i = 0; $i -lt $batches.Count; $i++) {
        $batch = $batches[$i]
        $batchBytes = 0
        foreach ($f in $batch) {
            $batchBytes += __GitSplit_GetFileBytes -FilePath $f
        }

        if ($batchBytes -le $MaxBytes) {
            # 整文件批次
            $fileInfos = [System.Collections.ArrayList]::new()
            foreach ($f in $batch) {
                $info = $stagedInfo[$f]
                if ($null -ne $info) {
                    $null = $fileInfos.Add($info)
                }
            }
            $seq++
            $null = $commitPlan.Add([PSCustomObject]@{
                Type      = 'files'
                Files     = @($batch)
                FileInfos = $fileInfos.ToArray()
                Bytes     = $batchBytes
                Seq       = $seq
                CommitMsg = "$Message #$seq"
            })
        }
        else {
            # 超限文件需逐个处理
            foreach ($f in $batch) {
                $fileBytes = __GitSplit_GetFileBytes -FilePath $f

                if ($fileBytes -le $MaxBytes) {
                    $seq++
                    $null = $commitPlan.Add([PSCustomObject]@{
                        Type      = 'files'
                        Files     = @($f)
                        FileInfos = @($stagedInfo[$f])
                        Bytes     = $fileBytes
                        Seq       = $seq
                        CommitMsg = "$Message #$seq"
                    })
                    continue
                }

                # 文件超限
                if (__GitSplit_IsBinaryFile -FilePath $f) {
                    $seq++
                    $null = $commitPlan.Add([PSCustomObject]@{
                        Type      = 'files'
                        Files     = @($f)
                        FileInfos = @($stagedInfo[$f])
                        Bytes     = $fileBytes
                        Seq       = $seq
                        CommitMsg = "$Message #$seq"
                        Note      = "二进制文件，无法按 hunk 切分，独立提交"
                    })
                    continue
                }

                # 按 hunk 切分（含单 hunk 内按行切分）
                $hunkBatches = __GitSplit_SplitFileByHunks -FilePath $f -MaxBytes $MaxBytes
                $fMode = if ($null -ne $stagedInfo[$f]) { $stagedInfo[$f].Mode } else { '100644' }

                if ($hunkBatches.Count -le 1 -and $hunkBatches[0].Hunks.Count -le 1) {
                    # 拆分后仍然只有 1 个 hunk（无法再拆的单行或已合规）
                    $seq++
                    $null = $commitPlan.Add([PSCustomObject]@{
                        Type      = 'files'
                        Files     = @($f)
                        FileInfos = @($stagedInfo[$f])
                        Bytes     = $fileBytes
                        Seq       = $seq
                        CommitMsg = "$Message #$seq"
                        Note      = "超限但仅1个hunk/子hunk，整文件提交"
                    })
                }
                else {
                    # 增量提交模式：每个批次只包含当前批次需要应用的 hunk
                    # CommitHunks 从当前 HEAD 开始，只应用本批次的 hunk（而非累积 AllHunks）
                    $hunkIdx = 0
                    foreach ($hb in $hunkBatches) {
                        $hunkIdx += $hb.Hunks.Count
                        $seq++
                        $null = $commitPlan.Add([PSCustomObject]@{
                            Type      = 'hunks'
                            FilePath  = $f
                            Mode      = $fMode
                            Hunks     = $hb.Hunks
                            Bytes     = $hb.AddBytes
                            Seq       = $seq
                            CommitMsg = "$Message #$seq"
                            Note      = "hunk 切分为 $($hunkBatches.Count) 批（含行切分）"
                        })
                    }
                }
            }
        }
    }

    # ---- 打印分批预览 ----
    __GitSplit_WriteHeader -Title "提交计划（共 $($commitPlan.Count) 批）" -Color Cyan

    $totalBytes = 0
    foreach ($item in $commitPlan) {
        Write-Host "  批次 $($item.Seq) / $($commitPlan.Count)  提交注释: $($item.CommitMsg)" -ForegroundColor Yellow
        Write-Host "  字节: $($item.Bytes)" -ForegroundColor Gray
        if ($item.Type -eq 'files') {
            Write-Host "  文件数: $($item.Files.Count)" -ForegroundColor Gray
            foreach ($f in $item.Files) {
                $fb = __GitSplit_GetFileBytes -FilePath $f
                Write-Host "    $f  ($fb bytes)" -ForegroundColor DarkGray
            }
        }
        else {
            $hunkCount = $item.Hunks.Count
            Write-Host "  文件: $($item.FilePath)  [切分提交, 本批 $hunkCount 个 hunk]" -ForegroundColor Gray
        }
        if ($item.Note) {
            Write-Host "  备注: $($item.Note)" -ForegroundColor Magenta
        }
        Write-Host ""
        $totalBytes += $item.Bytes
    }

    Write-Host "  总计: $($stagedFiles.Count) 个文件, $totalBytes 字节, $($commitPlan.Count) 批" -ForegroundColor Green
    Write-Host ""

    # ---- DryRun 模式 ----
    if ($DryRun) {
        Write-Host "DryRun 模式：未执行任何 git 操作，暂存区未修改" -ForegroundColor Yellow
        return
    }

    # ---- 实际执行 ----
    __GitSplit_WriteHeader -Title "开始提交" -Color Green

    # 保存完整暂存区 diff 到临时文件（安全网，出错时可恢复）
    $backupFile = __GitSplit_GetTempFile -Suffix "backup.patch"
    Write-Host "  保存暂存区 diff 到: $backupFile" -ForegroundColor Cyan
    $backupBytes = __GitSplit_GetAllStagedDiffBytes
    if ($null -ne $backupBytes -and $backupBytes.Count -gt 0) {
        [System.IO.File]::WriteAllBytes($backupFile, $backupBytes)
        Write-Host "  备份完成 ($($backupBytes.Count) bytes)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  备份失败，继续执行（无安全网）" -ForegroundColor Yellow
        $backupFile = $null
    }

    # 清空暂存区
    Write-Host "  清空暂存区（不修改工作区）..." -ForegroundColor Cyan
    git reset -q 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  git reset 失败" -ForegroundColor Red
        return
    }

    $successCount = 0
    $failCount = 0
    $anyFail = $false

    for ($i = 0; $i -lt $commitPlan.Count; $i++) {
        $item = $commitPlan[$i]

        Write-Host "  [$($item.Seq)/$($commitPlan.Count)] 提交: $($item.CommitMsg)" -ForegroundColor Yellow
        Write-Host "    字节: $($item.Bytes)" -ForegroundColor Gray

        $success = $false

        if ($item.Type -eq 'files') {
            Write-Host "    文件: $($item.Files.Count) 个" -ForegroundColor Gray
            $success = __GitSplit_CommitFiles -FileInfos $item.FileInfos -CommitMsg $item.CommitMsg
        }
        else {
            Write-Host "    文件: $($item.FilePath)  [hunk 切分, $($item.Hunks.Count) hunk]" -ForegroundColor Gray
            $success = __GitSplit_CommitHunks -FilePath $item.FilePath -Mode $item.Mode -Hunks $item.Hunks -CommitMsg $item.CommitMsg
        }

        if ($success) {
            Write-Host "    提交成功" -ForegroundColor Green
            $successCount++
        }
        else {
            Write-Host "    提交失败" -ForegroundColor Red
            $failCount++
            $anyFail = $true
        }
        Write-Host ""
    }

    # 清理临时文件和空目录
    if ($null -ne $backupFile -and -not $anyFail) {
        Remove-Item $backupFile -Force -ErrorAction SilentlyContinue
        Write-Host "  备份文件已清理" -ForegroundColor DarkGray
    }
    # 尝试清理空的临时目录（目录为空则删除，有文件则保留）
    __GitSplit_CleanEmptyTempDirs

    if ($anyFail) {
        Write-Host "  有提交失败！" -ForegroundColor Red
        # 用 stagedInfo 恢复剩余未提交文件到暂存区
        $remainingFiles = @()
        for ($j = $i + 1; $j -lt $commitPlan.Count; $j++) {
            $planItem = $commitPlan[$j]
            if ($planItem.Type -eq 'files') {
                $remainingFiles += @($planItem.FileInfos | ForEach-Object { $_.Path })
            } else {
                $remainingFiles += $planItem.FilePath
            }
        }
        if ($remainingFiles.Count -gt 0) {
            $remainingFiles = $remainingFiles | Select-Object -Unique
            Write-Host "  以下文件未提交，正在恢复到暂存区: $($remainingFiles -join ', ')" -ForegroundColor Yellow
            foreach ($rf in $remainingFiles) {
                $ri = $stagedInfo[$rf]
                if ($null -eq $ri) { continue }
                if ($ri.Status -eq 'D') {
                    git update-index --force-remove -- $ri.Path 2>$null
                } elseif ($null -ne $ri.Mode -and $null -ne $ri.Hash) {
                    git update-index --add --cacheinfo "$($ri.Mode),$($ri.Hash),$($ri.Path)" 2>$null
                }
            }
            Write-Host "  暂存区已恢复（已提交的文件除外）" -ForegroundColor Yellow
        }
        if ($null -ne $backupFile -and (Test-Path $backupFile)) {
            Write-Host "  备份文件保留: $backupFile" -ForegroundColor Yellow
        }
    }

    # 汇总
    __GitSplit_WriteHeader -Title "提交完成" -Color Green
    Write-Host "  成功: $successCount 批" -ForegroundColor Green
    if ($failCount -gt 0) {
        Write-Host "  失败: $failCount 批" -ForegroundColor Red
    }
    Write-Host "  未执行 git push，请手动推送" -ForegroundColor Yellow
    Write-Host ""

    } # end try
    finally {
        if ($pushedLocation) {
            Pop-Location
        }
    }
}


# 获取完整暂存区 diff 的字节数组（用于备份恢复）
function __GitSplit_GetAllStagedDiffBytes {
    return __GitSplit_RunGitBytes -Arguments "diff --cached"
}


# 整文件提交：用 blob hash + update-index 恢复到暂存区，然后 commit
function __GitSplit_CommitFiles {
    param(
        [object[]]$FileInfos,
        [string]$CommitMsg
    )

    foreach ($info in $FileInfos) {
        if ($info.Status -eq 'D') {
            # 删除文件：用 update-index --force-remove 避免 pathspec 歧义
            git update-index --force-remove -- $info.Path 2>$null
        } else {
            # 新增/修改文件
            git update-index --add --cacheinfo "$($info.Mode),$($info.Hash),$($info.Path)" 2>$null
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    git update-index 失败: $($info.Path)" -ForegroundColor Red
            return $false
        }
    }

    $result = git commit -m $CommitMsg 2>&1
    if ($LASTEXITCODE -eq 0) {
        return $true
    } else {
        Write-Host "    git commit 失败: $result" -ForegroundColor Red
        return $false
    }
}


# Hunk 切分提交（增量模式）：从当前 HEAD 应用当前批次的 hunk，生成中间内容后提交
# 每次只接收当前批次需要应用的 hunk 列表，从当前 HEAD 内容开始应用
# 这样每次提交后 HEAD 更新，下一次调用自然基于新的 HEAD
function __GitSplit_CommitHunks {
    param(
        [string]$FilePath,
        [string]$Mode,
        [object[]]$Hunks,
        [string]$CommitMsg
    )

    # 获取当前 HEAD 内容字节
    $headBytes = __GitSplit_GetHeadContentBytes -FilePath $FilePath

    # 应用当前批次的 hunk 变更，生成中间内容
    # UpToIndex = Hunks.Count - 1（应用全部本批次 hunk）
    $contentBytes = __GitSplit_ApplyHunksToContent -HeadBytes $headBytes -AllHunks $Hunks -UpToIndex ($Hunks.Count - 1)

    # 写入临时文件
    $tempFile = __GitSplit_GetTempFile -Suffix "content.bin"
    [System.IO.File]::WriteAllBytes($tempFile, $contentBytes)

    # 创建 blob
    $blobHash = git hash-object -w $tempFile 2>$null
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($blobHash)) {
        Write-Host "    git hash-object 失败" -ForegroundColor Red
        return $false
    }

    # 更新暂存区
    git update-index --add --cacheinfo "$Mode,$blobHash,$FilePath" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    git update-index 失败" -ForegroundColor Red
        return $false
    }

    # 提交
    $result = git commit -m $CommitMsg 2>&1
    if ($LASTEXITCODE -eq 0) {
        return $true
    } else {
        Write-Host "    git commit 失败: $result" -ForegroundColor Red
        return $false
    }
}


# ============================================================
# 直接运行此脚本时，执行拆分提交
# dot-source 加载时不会触发
# ============================================================
if ($MyInvocation.InvocationName -ne '.') {
    if ($Help) {
        Get-Help $MyInvocation.MyCommand.Path -Full | Out-Host
        return
    }
    Split-GitStagedCommit @PSBoundParameters
}
