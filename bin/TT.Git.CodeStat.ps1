
<#
.SYNOPSIS
    Git 代码统计工具 - 字符数 / UTF-8 字节数 / 仅新增字节数
.DESCRIPTION
    统计 Git 变更代码的字符数和字节数，三种方案独立可用：
      方案1 Get-GitCodeCharStat    - 字符数统计（新增/删除/合计）
      方案2 Get-GitCodeByteStat    - UTF-8 字节数统计（新增/删除/合计）
      方案3 Get-GitCodeNewByteStat - 仅新增代码 UTF-8 字节数
      综合入口 Get-GitCodeStat     - 同时输出三种方案结果

    参数说明:
      无参数        → 同时统计暂存区 + 最新提交(HEAD)
      -Staged       → 仅统计暂存区
      -Commit1 xxx  → 统计 xxx 到 HEAD 之间变更
      -Commit1 xxx -Commit2 yyy → 统计 xxx 到 yyy 之间变更
      -PassThru     → 返回原始统计对象（供编程使用），否则仅展示不返回
      -NoWhitespace → 排除空格、制表符、换行等空白字符再统计

    边界处理:
      - 首次提交（无 HEAD^）自动切换 --root 模式
      - 二进制文件: git diff 不输出二进制内容，不计入统计
      - 空行/空格/制表符: 默认全部计入统计，-NoWhitespace 可排除
.NOTES
    兼容 PowerShell 5.1，无额外模块依赖
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Commit1,
    [Parameter(Position = 1)]
    [string]$Commit2,
    [switch]$Staged,
    [switch]$PassThru,
    [switch]$NoWhitespace,
    [switch]$Help
)


# ============================================================
# 内部辅助函数
# ============================================================

# 核心：从 git diff 输出行计算字符数和 UTF-8 字节数
# 只统计以 +/- 开头的真实代码行，排除 +++ / --- 文件标记行
function __GitCodeStat_Compute {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$DiffLines,
        [switch]$NoWhitespace
    )

    $utf8 = [System.Text.Encoding]::UTF8
    $addChar = 0; $delChar = 0
    $addByte = 0; $delByte = 0

    if (-not $DiffLines -or $DiffLines.Count -eq 0) {
        return [PSCustomObject]@{
            Add_Char    = 0
            Del_Char    = 0
            Total_Char  = 0
            Add_Bytes   = 0
            Del_Bytes   = 0
            Total_Bytes = 0
        }
    }

    # 过滤有效代码行: 以 +/- 开头，排除 +++ / --- 文件标记
    $codeLines = $DiffLines | Where-Object {
        $_ -match '^[+-]' -and $_ -notmatch '^[+-]{3}'
    }

    foreach ($line in $codeLines) {
        $content = $line.Substring(1)  # 去掉行首 + / - 符号

        # -NoWhitespace: 移除所有空白字符（空格、制表符、换行、回车等）
        if ($NoWhitespace) {
            $content = $content -replace '\s', ''
        }

        $charLen = $content.Length
        $byteLen = $utf8.GetByteCount($content)

        if ($line.StartsWith('+')) {
            $addChar += $charLen
            $addByte += $byteLen
        }
        else {
            $delChar += $charLen
            $delByte += $byteLen
        }
    }

    return [PSCustomObject]@{
        Add_Char    = $addChar
        Del_Char    = $delChar
        Total_Char  = $addChar + $delChar
        Add_Bytes   = $addByte
        Del_Bytes   = $delByte
        Total_Bytes = $addByte + $delByte
    }
}


# 获取 git diff 输出，根据参数选择不同模式
function __GitCodeStat_GetDiff {
    param(
        [string]$Commit1,
        [string]$Commit2,
        [switch]$Staged
    )

    # --- 暂存区模式 ---
    if ($Staged) {
        $result = git diff --cached
        if ($LASTEXITCODE -ne 0) { return @() }
        if ($null -eq $result -or $result.Count -eq 0) { return @() }
        return @($result)
    }

    # --- 双 commit 对比模式 ---
    if ($Commit1 -and $Commit2) {
        $result = git diff $Commit1 $Commit2
        if ($LASTEXITCODE -ne 0) {
            Write-Host "git diff $Commit1 $Commit2 执行失败 (退出码: $LASTEXITCODE)" -ForegroundColor Red
            return @()
        }
        if ($null -eq $result -or $result.Count -eq 0) { return @() }
        return @($result)
    }

    # --- 单 commit → HEAD 模式 ---
    if ($Commit1) {
        $result = git diff $Commit1 HEAD
        if ($LASTEXITCODE -ne 0) {
            Write-Host "git diff $Commit1 HEAD 执行失败 (退出码: $LASTEXITCODE)" -ForegroundColor Red
            return @()
        }
        if ($null -eq $result -or $result.Count -eq 0) { return @() }
        return @($result)
    }

    # --- 无参数默认: HEAD^..HEAD，兼容首次提交 ---
    $null = git rev-parse --verify HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "仓库没有任何提交，无法统计" -ForegroundColor Yellow
        return @()
    }

    $null = git rev-parse --verify HEAD^ 2>$null
    if ($LASTEXITCODE -eq 0) {
        $result = git diff HEAD^ HEAD
    }
    else {
        Write-Host "检测到仓库仅存在首次提交，使用 --root 模式" -ForegroundColor Yellow
        $result = git diff --root HEAD
    }

    if ($LASTEXITCODE -ne 0) { return @() }
    if ($null -eq $result -or $result.Count -eq 0) { return @() }
    return @($result)
}


# 检查当前目录是否在 Git 仓库内
function __GitCodeStat_CheckRepo {
    $null = git rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "错误：当前目录不是 Git 仓库" -ForegroundColor Red
        return $false
    }
    return $true
}


# 参数互斥校验: -Staged 与 commit 参数不能同时使用
function __GitCodeStat_ValidateParams {
    param([string]$Commit1, [string]$Commit2, [switch]$Staged)

    if ($Staged -and ($Commit1 -or $Commit2)) {
        Write-Host "错误：-Staged 与 -Commit1/-Commit2 不能同时使用" -ForegroundColor Red
        return $false
    }
    return $true
}


# 帮助请求拦截: -Help 转发到 Get-Help
# --help / -? 由 PowerShell [CmdletBinding()] 原生处理，此处不重复
# 返回 $true 表示已拦截(调用方应 return)，$false 表示正常执行
function __GitCodeStat_HelpInterceptor {
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


# 打印区块分隔标题（两端固定 16 个 =，中间标题自然嵌入）
function __GitCodeStat_WriteHeader {
    param([string]$Title, [System.ConsoleColor]$Color = 'White')
    Write-Host ""
    Write-Host "================ [$Title] ================" -ForegroundColor $Color
    Write-Host ""
}


# 打印单项统计（字符+字节全量，带子 section 标题）
# 标签间距硬编码，无需动态计算显示宽度
# 标签显示宽度: "新增代码总字符"=12, "删除代码总字符"=12, "变更合计字符数"=12,
#               "新增代码UTF8总字节"=17, "删除代码UTF8总字节"=17, "变更合计字节"=10
# 目标显示宽度 17，按差值补空格
function __GitCodeStat_WriteFull {
    param([PSCustomObject]$Stat)

    $fmt = '{0,12:N0}'

    Write-Host "  --- 字符数统计 ---" -ForegroundColor Gray
    Write-Host "  新增代码总字符     $($fmt -f $Stat.Add_Char)"
    Write-Host "  删除代码总字符     $($fmt -f $Stat.Del_Char)"
    Write-Host "  变更合计字符数     $($fmt -f $Stat.Total_Char)"
    Write-Host ""
    Write-Host "  --- UTF-8字节统计 ---" -ForegroundColor Gray
    Write-Host "  新增代码UTF8总字节 $($fmt -f $Stat.Add_Bytes)"
    Write-Host "  删除代码UTF8总字节 $($fmt -f $Stat.Del_Bytes)"
    Write-Host "  变更合计字节       $($fmt -f $Stat.Total_Bytes)"
    Write-Host ""
    Write-Host "  --- 仅新增代码字节统计 ---" -ForegroundColor Gray
    Write-Host "  新增代码UTF8总字节 $($fmt -f $Stat.Add_Bytes)"
}


# ============================================================
# 方案1: 统计代码字符数（新增 / 删除 / 合计）
# ============================================================
function Get-GitCodeCharStat {
    <#
    .SYNOPSIS
        统计 Git 变更代码的字符数（方案1）
    .DESCRIPTION
        统计新增、删除及合计字符数（不含行首 +/- 符号）。

        无参数   → 统计最新提交 HEAD^..HEAD
        -Staged  → 仅统计暂存区
        -Commit1 xxx → xxx..HEAD
        -Commit1 xxx -Commit2 yyy → xxx..yyy
        -PassThru → 返回原始统计对象（供编程使用）
        -NoWhitespace → 排除空格、制表符、换行等空白字符再统计
        -Help → 显示完整帮助（等同 Get-Help -Full）
    .EXAMPLE
        Get-GitCodeCharStat
        Get-GitCodeCharStat -Staged
        Get-GitCodeCharStat HEAD~3
        Get-GitCodeCharStat v1.0 v2.0
        Get-GitCodeCharStat -NoWhitespace
        Get-GitCodeCharStat -Help
        $s = Get-GitCodeCharStat -PassThru
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Commit1,
        [Parameter(Position = 1)]
        [string]$Commit2,
        [switch]$Staged,
        [switch]$PassThru,
        [switch]$NoWhitespace,
        [switch]$Help
    )

    if (__GitCodeStat_HelpInterceptor -CommandName 'Get-GitCodeCharStat' -Help:$Help) { return }
    if (-not (__GitCodeStat_ValidateParams @PSBoundParameters)) { return }
    if (-not (__GitCodeStat_CheckRepo)) { return }

    $diffLines = __GitCodeStat_GetDiff -Commit1 $Commit1 -Commit2 $Commit2 -Staged:$Staged
    $stat = __GitCodeStat_Compute -DiffLines $diffLines -NoWhitespace:$NoWhitespace

    Write-Host "新增代码总字符: $($stat.Add_Char)"
    Write-Host "删除代码总字符: $($stat.Del_Char)"
    Write-Host "变更合计字符数: $($stat.Total_Char)"

    if ($PassThru) { return $stat }
}


# ============================================================
# 方案2: 统计代码 UTF-8 字节数（新增 / 删除 / 合计）
# ============================================================
function Get-GitCodeByteStat {
    <#
    .SYNOPSIS
        统计 Git 变更代码的 UTF-8 字节数（方案2）
    .DESCRIPTION
        统计新增、删除及合计 UTF-8 字节数。
        字符 != 字节，中文/符号等占多字节时此方案更准确。

        参数同 Get-GitCodeCharStat。
    .EXAMPLE
        Get-GitCodeByteStat
        Get-GitCodeByteStat -Staged
        Get-GitCodeByteStat HEAD~3
        Get-GitCodeByteStat v1.0 v2.0
        Get-GitCodeByteStat -NoWhitespace
        Get-GitCodeByteStat -Help
        $s = Get-GitCodeByteStat -PassThru
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Commit1,
        [Parameter(Position = 1)]
        [string]$Commit2,
        [switch]$Staged,
        [switch]$PassThru,
        [switch]$NoWhitespace,
        [switch]$Help
    )

    if (__GitCodeStat_HelpInterceptor -CommandName 'Get-GitCodeByteStat' -Help:$Help) { return }
    if (-not (__GitCodeStat_ValidateParams @PSBoundParameters)) { return }
    if (-not (__GitCodeStat_CheckRepo)) { return }

    $diffLines = __GitCodeStat_GetDiff -Commit1 $Commit1 -Commit2 $Commit2 -Staged:$Staged
    $stat = __GitCodeStat_Compute -DiffLines $diffLines -NoWhitespace:$NoWhitespace

    Write-Host "新增代码UTF8总字节: $($stat.Add_Bytes)"
    Write-Host "删除代码UTF8总字节: $($stat.Del_Bytes)"
    Write-Host "变更合计字节:       $($stat.Total_Bytes)"

    if ($PassThru) { return $stat }
}


# ============================================================
# 方案3: 仅统计新增代码 UTF-8 字节数
# ============================================================
function Get-GitCodeNewByteStat {
    <#
    .SYNOPSIS
        仅统计 Git 变更中新增代码的 UTF-8 字节数（方案3）
    .DESCRIPTION
        只统计 + 行的 UTF-8 字节，忽略删除行。
        适合只关注代码增长量的场景。

        参数同 Get-GitCodeCharStat。
    .EXAMPLE
        Get-GitCodeNewByteStat
        Get-GitCodeNewByteStat -Staged
        Get-GitCodeNewByteStat HEAD~3
        Get-GitCodeNewByteStat v1.0 v2.0
        Get-GitCodeNewByteStat -NoWhitespace
        Get-GitCodeNewByteStat -Help
        $s = Get-GitCodeNewByteStat -PassThru
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Commit1,
        [Parameter(Position = 1)]
        [string]$Commit2,
        [switch]$Staged,
        [switch]$PassThru,
        [switch]$NoWhitespace,
        [switch]$Help
    )

    if (__GitCodeStat_HelpInterceptor -CommandName 'Get-GitCodeNewByteStat' -Help:$Help) { return }
    if (-not (__GitCodeStat_ValidateParams @PSBoundParameters)) { return }
    if (-not (__GitCodeStat_CheckRepo)) { return }

    $diffLines = __GitCodeStat_GetDiff -Commit1 $Commit1 -Commit2 $Commit2 -Staged:$Staged
    $stat = __GitCodeStat_Compute -DiffLines $diffLines -NoWhitespace:$NoWhitespace

    Write-Host "新增代码UTF8总字节: $($stat.Add_Bytes)"

    if ($PassThru) { return $stat }
}


# ============================================================
# 综合入口: 同时输出三种方案结果
# ============================================================
function Get-GitCodeStat {
    <#
    .SYNOPSIS
        Git 代码统计综合入口
    .DESCRIPTION
        同时输出字符数、UTF-8字节数、仅新增字节数三种统计结果。

        无参数        → 同时统计暂存区 + 最新提交(HEAD) 各自的三种方案
        -Staged       → 仅暂存区（三种方案）
        -Commit1 xxx  → xxx..HEAD（三种方案）
        -Commit1 xxx -Commit2 yyy → xxx..yyy（三种方案）
        -PassThru     → 返回原始统计对象（供编程使用）
        -NoWhitespace → 排除空格、制表符、换行等空白字符再统计
        -Help → 显示完整帮助（等同 Get-Help -Full）
    .EXAMPLE
        Get-GitCodeStat
        Get-GitCodeStat -Staged
        Get-GitCodeStat HEAD~3
        Get-GitCodeStat v1.0 v2.0
        Get-GitCodeStat -NoWhitespace
        Get-GitCodeStat -Help
        $r = Get-GitCodeStat -PassThru
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Commit1,
        [Parameter(Position = 1)]
        [string]$Commit2,
        [switch]$Staged,
        [switch]$PassThru,
        [switch]$NoWhitespace,
        [switch]$Help
    )

    if (__GitCodeStat_HelpInterceptor -CommandName 'Get-GitCodeStat' -Help:$Help) { return }
    if (-not (__GitCodeStat_ValidateParams @PSBoundParameters)) { return }
    if (-not (__GitCodeStat_CheckRepo)) { return }

    # ---- 无参数: 暂存区 + HEAD 双模式 ----
    if (-not $Staged -and -not $Commit1 -and -not $Commit2) {

        # -- 暂存区统计 --
        __GitCodeStat_WriteHeader -Title "暂存区变更统计" -Color Cyan
        $diffLines = __GitCodeStat_GetDiff -Staged
        $stagedStat = __GitCodeStat_Compute -DiffLines $diffLines -NoWhitespace:$NoWhitespace
        __GitCodeStat_WriteFull -Stat $stagedStat

        # -- 最新提交统计 --
        __GitCodeStat_WriteHeader -Title "最新提交 HEAD 变更统计" -Color Green
        $diffLines = __GitCodeStat_GetDiff
        $headStat = __GitCodeStat_Compute -DiffLines $diffLines -NoWhitespace:$NoWhitespace
        __GitCodeStat_WriteFull -Stat $headStat

        if ($PassThru) {
            return [PSCustomObject]@{
                Staged = $stagedStat
                Head   = $headStat
            }
        }
        return
    }

    # ---- 有参数: 单模式 ----
    $label = if ($Staged) { "暂存区" }
              elseif ($Commit1 -and $Commit2) { "$Commit1 ~ $Commit2" }
              elseif ($Commit1) { "$Commit1 ~ HEAD" }
              else { "HEAD" }

    __GitCodeStat_WriteHeader -Title "$label 变更统计" -Color Yellow
    $diffLines = __GitCodeStat_GetDiff -Commit1 $Commit1 -Commit2 $Commit2 -Staged:$Staged
    $stat = __GitCodeStat_Compute -DiffLines $diffLines -NoWhitespace:$NoWhitespace
    __GitCodeStat_WriteFull -Stat $stat

    if ($PassThru) { return $stat }
}


# ============================================================
# 直接运行此脚本时，执行默认统计（暂存区 + HEAD）
# dot-source 加载时不会触发
# ============================================================
if ($MyInvocation.InvocationName -ne '.') {
    if ($Help) {
        Get-Help $MyInvocation.MyCommand.Path -Full | Out-Host
        return
    }
    Get-GitCodeStat @PSBoundParameters
}
