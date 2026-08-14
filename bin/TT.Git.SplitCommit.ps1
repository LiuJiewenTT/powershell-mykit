<#
.SYNOPSIS
    Git 暂存区拆分提交工具 - 按字节大小自动分批提交
.DESCRIPTION
    将当前暂存区（staged）的变更按 UTF-8 字节大小拆分为多个提交，
    每个提交不超过指定字节上限。提交注释自动追加序号后缀。

    工作流程:
      1. 获取暂存区文件列表（git diff --cached --name-only）
      2. 逐文件计算 UTF-8 新增字节数
      3. 贪心装箱：累加文件字节，不超过 MaxBytes 则放入当前批，否则新开一批
      4. 对每批：git reset 暂存区 → git add 该批文件 → git commit

    参数说明:
      -MaxBytes    → 每个提交的字节上限（必填，单位：字节）
      -Message     → 提交注释前缀（必填），实际注释为 "前缀 #序号"
      -DryRun      → 仅模拟分批结果，不执行 git add / commit
      -Help        → 显示完整帮助（等同 Get-Help -Full）

    注意事项:
      - 操作对象仅为暂存区（staged），不涉及工作区未跟踪文件
      - 执行前会先 git reset 清空暂存区再重新分批 add
      - 不会执行 git push，仅本地提交
      - 单个文件字节超上限时，该文件独立成一批（不会跳过）
.NOTES
    兼容 PowerShell 5.1，无额外模块依赖
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
function __GitSplit_CheckRepo {
    $null = git rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "错误：当前目录不是 Git 仓库" -ForegroundColor Red
        return $false
    }
    return $true
}


# 检查暂存区是否有内容
function __GitSplit_HasStagedChanges {
    $result = git diff --cached --name-only
    if ($LASTEXITCODE -ne 0) {
        Write-Host "错误：无法获取暂存区文件列表" -ForegroundColor Red
        return $false
    }
    if ($null -eq $result -or $result.Count -eq 0) {
        Write-Host "暂存区为空，没有需要拆分的内容" -ForegroundColor Yellow
        return $false
    }
    return $true
}


# 计算单个文件在暂存区中的新增 UTF-8 字节数
# 使用 git diff --cached -U0 -- <file> 只取变更行，避免全文件内容
function __GitSplit_GetFileBytes {
    param([string]$FilePath)

    $diff = git diff --cached -U0 -- $FilePath 2>$null
    if ($LASTEXITCODE -ne 0 -or $null -eq $diff -or $diff.Count -eq 0) {
        return 0
    }

    $utf8 = [System.Text.Encoding]::UTF8
    $addByte = 0

    foreach ($line in $diff) {
        # 只统计 + 开头的真实代码行，排除 +++ 文件标记
        if ($line -match '^\+' -and $line -notmatch '^\+{3}') {
            $content = $line.Substring(1)
            $addByte += $utf8.GetByteCount($content)
        }
    }

    return $addByte
}


# 帮助请求拦截: -Help 转发到 Get-Help
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


# 贪心装箱：将文件列表按字节上限分批
# 返回二维数组，每个元素是一个文件路径数组
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

    # 先计算每个文件的字节数
    $fileBytes = @()
    foreach ($f in $FileList) {
        $bytes = __GitSplit_GetFileBytes -FilePath $f
        $fileBytes += [PSCustomObject]@{
            Path  = $f
            Bytes = $bytes
        }
    }

    # 贪心装箱
    $batches = @()
    $currentBatch = @()
    $currentBytes = 0

    foreach ($fb in $fileBytes) {
        # 当前批为空 → 直接放入（即使超上限也独立成批）
        if ($currentBatch.Count -eq 0) {
            $currentBatch += $fb.Path
            $currentBytes = $fb.Bytes
            continue
        }

        # 加入后不超上限 → 放入当前批
        if ($currentBytes + $fb.Bytes -le $MaxBytes) {
            $currentBatch += $fb.Path
            $currentBytes += $fb.Bytes
        }
        else {
            # 超上限 → 封装当前批，新开一批
            $batches += ,@($currentBatch)
            $currentBatch = @($fb.Path)
            $currentBytes = $fb.Bytes
        }
    }

    # 封装最后一批
    if ($currentBatch.Count -gt 0) {
        $batches += ,@($currentBatch)
    }

    return ,$batches
}


# ============================================================
# 主函数: Split-GitStagedCommit
# ============================================================
function Split-GitStagedCommit {
    <#
    .SYNOPSIS
        将暂存区按字节大小拆分为多个提交
    .DESCRIPTION
        获取暂存区所有文件，按 UTF-8 新增字节贪心分批，
        每批不超过 -MaxBytes 指定的上限，提交注释自动追加 #序号。

        执行前会先 git reset 清空暂存区，再逐批 git add + commit。
        不会执行 git push。

        -DryRun → 仅模拟分批结果，不执行实际提交
        -Help   → 显示完整帮助
    .EXAMPLE
        Split-GitStagedCommit -MaxBytes 10240 -Message "feature: 新增模块"
        Split-GitStagedCommit -MaxBytes 5KB -Message "feat" -DryRun
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
    if (-not (__GitSplit_HasStagedChanges)) { return }

    if ($MaxBytes -le 0) {
        Write-Host "错误：-MaxBytes 必须大于 0" -ForegroundColor Red
        return
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Host "错误：-Message 不能为空" -ForegroundColor Red
        return
    }

    # 获取暂存区文件列表
    $stagedFiles = git diff --cached --name-only
    if ($null -eq $stagedFiles -or $stagedFiles.Count -eq 0) {
        Write-Host "暂存区为空" -ForegroundColor Yellow
        return
    }
    $stagedFiles = @($stagedFiles)

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

    # 打印分批预览
    __GitSplit_WriteHeader -Title "分批预览（共 $($batches.Count) 批）" -Color Cyan

    $totalBytes = 0
    for ($i = 0; $i -lt $batches.Count; $i++) {
        $batch = $batches[$i]
        $batchBytes = 0
        foreach ($f in $batch) {
            $batchBytes += __GitSplit_GetFileBytes -FilePath $f
        }
        $totalBytes += $batchBytes

        $seq = $i + 1
        Write-Host "  批次 $seq / $($batches.Count) — 提交注释: $Message #$seq" -ForegroundColor Yellow
        Write-Host "  文件数: $($batch.Count)    字节: $batchBytes" -ForegroundColor Gray
        foreach ($f in $batch) {
            $fb = __GitSplit_GetFileBytes -FilePath $f
            Write-Host "    $f  ($fb bytes)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    Write-Host "  总计: $($stagedFiles.Count) 个文件, $totalBytes 字节, $($batches.Count) 批" -ForegroundColor Green
    Write-Host ""

    # ---- DryRun 模式: 到此为止 ----
    if ($DryRun) {
        Write-Host "DryRun 模式：未执行任何 git 操作" -ForegroundColor Yellow
        return
    }

    # ---- 实际执行 ----
    __GitSplit_WriteHeader -Title "开始提交" -Color Green

    # 先保存原始暂存区文件列表（git reset 后需要重新 add）
    # git reset 会清空暂存区，但不影响工作区文件内容

    # 清空暂存区
    git reset 2>$null | Out-Null

    $successCount = 0
    $failCount = 0

    for ($i = 0; $i -lt $batches.Count; $i++) {
        $batch = $batches[$i]
        $seq = $i + 1
        $commitMsg = "$Message #$seq"

        Write-Host "  [$seq/$($batches.Count)] 提交: $commitMsg" -ForegroundColor Yellow
        Write-Host "    文件: $($batch.Count) 个" -ForegroundColor Gray

        # 逐个 add
        foreach ($f in $batch) {
            git add -- $f 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    git add 失败: $f" -ForegroundColor Red
            }
        }

        # commit
        $commitResult = git commit -m $commitMsg 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    提交成功" -ForegroundColor Green
            $successCount++
        }
        else {
            Write-Host "    提交失败: $commitResult" -ForegroundColor Red
            $failCount++
        }
        Write-Host ""
    }

    # 汇总
    __GitSplit_WriteHeader -Title "提交完成" -Color Green
    Write-Host "  成功: $successCount 批" -ForegroundColor Green
    if ($failCount -gt 0) {
        Write-Host "  失败: $failCount 批" -ForegroundColor Red
    }
    Write-Host "  未执行 git push，请手动推送" -ForegroundColor Yellow
    Write-Host ""
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
