<#
.SYNOPSIS
    TT.MyKit 工具箱入口 — 导入、浏览、帮助一体化
.DESCRIPTION
    提供三个核心命令：

      Import-MyKit          按分类或全量导入工具脚本
      Get-MyKitCommand      浏览工具箱命令列表，查看脚本帮助
      Get-MyKitCategory     列出所有分类目录

    dot-source 加载本脚本即可注册上述命令：

      . TT.MyKit.ps1

.NOTES
    兼容 PowerShell 5.1，无额外模块依赖
#>

# ─── 工具箱元数据 ──────────────────────────────────────────
$script:MyKitRoot = $PSScriptRoot
# 已加载脚本记录：Key=脚本全路径小写, Value=加载时间
if ($null -eq $global:__TT_MyKit_Loaded) {
    $global:__TT_MyKit_Loaded = @{}
}

# ─── 内部辅助：计算字符串的终端显示宽度 ──────────────────
#   CJK 字符、全角字符宽度为 2，ASCII 等宽度为 1
function __MyKit_DisplayWidth {
    param([string]$Text)
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $cp = [int]$ch
        # CJK 统一汉字 / CJK 兼容 / 全角片假名等
        if (($cp -ge 0x4E00 -and $cp -le 0x9FFF) -or
            ($cp -ge 0x3400 -and $cp -le 0x4DBF) -or
            ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
            ($cp -ge 0xFF00 -and $cp -le 0xFFEF) -or
            ($cp -ge 0x3000 -and $cp -le 0x303F) -or
            ($cp -ge 0x2E80 -and $cp -le 0x2EFF) -or
            ($cp -ge 0x31C0 -and $cp -le 0x31EF) -or
            ($cp -ge 0xFE30 -and $cp -le 0xFE4F)) {
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

# ─── 内部辅助：按显示宽度右填充空格 ──────────────────────
function __MyKit_PadRight {
    param(
        [string]$Text,
        [int]$TargetDisplayWidth
    )
    $currentW = __MyKit_DisplayWidth $Text
    if ($currentW -ge $TargetDisplayWidth) { return $Text }
    return $Text + (' ' * ($TargetDisplayWidth - $currentW))
}

# ─── 内部辅助：按显示宽度截断并补 .. ────────────────────
function __MyKit_TruncateDisplay {
    param(
        [string]$Text,
        [int]$MaxDisplayWidth
    )
    $w = __MyKit_DisplayWidth $Text
    if ($w -le $MaxDisplayWidth) { return $Text }
    # 逐字符累加，到目标宽度减 2 处截断
    $curW = 0
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $cp = [int]$ch
        $cw = if ((($cp -ge 0x4E00 -and $cp -le 0x9FFF) -or
                   ($cp -ge 0x3400 -and $cp -le 0x4DBF) -or
                   ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
                   ($cp -ge 0xFF00 -and $cp -le 0xFFEF) -or
                   ($cp -ge 0x3000 -and $cp -le 0x303F) -or
                   ($cp -ge 0x2E80 -and $cp -le 0x2EFF) -or
                   ($cp -ge 0x31C0 -and $cp -le 0x31EF) -or
                   ($cp -ge 0xFE30 -and $cp -le 0xFE4F))) { 2 } else { 1 }
        if ($curW + $cw -gt $MaxDisplayWidth - 2) { break }
        $null = $sb.Append($ch)
        $curW += $cw
    }
    return $sb.ToString() + '..'
}

# ─── 内部辅助：从文件内容提取 .SYNOPSIS ───────────────────
function __MyKit_ExtractSynopsis {
    param([string]$Content)
    $inBlock = $false
    $inSynopsis = $false
    $synopsisLines = @()
    foreach ($rawLine in $Content -split "`r?`n") {
        $trimmed = $rawLine.Trim()
        if ($trimmed -eq '<#') { $inBlock = $true; continue }
        if ($trimmed -eq '#>') { break }
        if (-not $inBlock) { continue }
        if ($trimmed -match '^\.SYNOPSIS\b') { $inSynopsis = $true; continue }
        if ($trimmed -match '^\.') { $inSynopsis = $false; continue }
        if ($inSynopsis -and ($trimmed -ne '')) {
            $synopsisLines += $trimmed
        }
    }
    if ($synopsisLines.Count -gt 0) { return ($synopsisLines -join ' ') }
    # 兜底1：提取非标准注释块中第一行非空非标签内容
    $inBlock2 = $false
    foreach ($rawLine in $Content -split "`r?`n") {
        $trimmed = $rawLine.Trim()
        if ($trimmed -eq '<#') { $inBlock2 = $true; continue }
        if ($trimmed -eq '#>') { break }
        if (-not $inBlock2) { continue }
        if ($trimmed -eq '' -or $trimmed -match '^\.') { continue }
        return $trimmed
    }
    # 兜底2：提取 # 单行注释（跳过 shebang、requires、@archived、注释代码行）
    foreach ($rawLine in $Content -split "`r?`n") {
        $trimmed = $rawLine.Trim()
        if ($trimmed -match '^#!') { continue }
        if ($trimmed -match '^#Requires') { continue }
        if ($trimmed -match '^#\s*@archived') { continue }
        if ($trimmed -match '^#\s*(.+)') {
            $desc = $Matches[1].Trim()
            # 跳过 @description 标签前缀，提取实际内容
            if ($desc -match '^@description\s+(.+)') { $desc = $Matches[1].Trim() }
            # 跳过空行、echo/Write-Host 等注释代码行
            if ($desc -eq '') { continue }
            if ($desc -match '^(echo|Write-Host|Write-Warning|Write-Verbose)\b') { continue }
            return $desc
        }
    }
    return ''
}

# ─── 内部辅助：提取文件中定义的 function 名称 ─────────────
function __MyKit_ExtractFunctions {
    param([string]$Content)
    $funcs = [regex]::Matches($Content, '(?mi)^\s*function\s+([A-Za-z][\w.-]+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -notmatch '^__' }    # 过滤内部函数（__前缀）
    return $funcs
}

# ─── 内部辅助：检测脚本是否标记为 @archived ──────────────
#   在脚本前 5 行内出现 # @archived 即视为存档脚本
function __MyKit_DetectArchived {
    param([string]$Content)
    $lines = $Content -split "`r?`n"
    $checkCount = [Math]::Min(5, $lines.Count)
    for ($i = 0; $i -lt $checkCount; $i++) {
        if ($lines[$i].Trim() -match '^#\s*@archived\b') { return $true }
        # 也支持 <# .ARCHIVED #> 形式
        if ($lines[$i].Trim() -match '^\.(?:ARCHIVED)\b') { return $true }
    }
    return $false
}

# ─── 内部辅助：检测脚本是否有脚本级直接执行代码 ────────
#   dot-source 加载时脚本级代码会立即执行，可能导致交互阻塞（Read-Host 等）
#   判断依据：AST 顶层存在非空语句（排除 function/using/require/注释）
#   例外：标准 dot-source 守卫 if ($MyInvocation.InvocationName -ne '.') { ... }
#         这种 if 块在 dot-source 时条件为 false，不会执行，视为安全
function __MyKit_HasDirectExecution {
    param([string]$Content)
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $Content, [ref]$null, [ref]$null
        )
        foreach ($stmt in $ast.EndBlock.Statements) {
            # 跳过函数定义
            if ($stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
            # 跳过 using 语句
            if ($stmt -is [System.Management.Automation.Language.UsingStatementAst]) { continue }
            # 跳过空管道（仅含注释等）
            if ($stmt -is [System.Management.Automation.Language.PipelineAst] -and
                $stmt.PipelineElements.Count -eq 0) { continue }
            # 跳过标准 dot-source 守卫：if ($MyInvocation.InvocationName -ne '.') { ... }
            if ($stmt -is [System.Management.Automation.Language.IfStatementAst]) {
                $clauses = $stmt.Clauses
                if ($clauses -and $clauses.Count -eq 1) {
                    $condPipeline = $clauses[0].Item1
                    if ($condPipeline -is [System.Management.Automation.Language.PipelineAst] -and
                        $condPipeline.PipelineElements.Count -eq 1 -and
                        $condPipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                        $binExpr = $condPipeline.PipelineElements[0].Expression
                        if ($binExpr -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                            ($binExpr.Operator -eq [System.Management.Automation.Language.TokenKind]::Ne -or
                             $binExpr.Operator -eq [System.Management.Automation.Language.TokenKind]::Ine) -and
                            $binExpr.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and
                            $binExpr.Left.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $binExpr.Left.Expression.VariablePath.UserPath -eq 'MyInvocation' -and
                            $binExpr.Left.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                            $binExpr.Left.Member.Value -eq 'InvocationName' -and
                            $binExpr.Right -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                            $binExpr.Right.Value -eq '.') {
                            continue
                        }
                    }
                }
            }
            # 存在非函数定义的顶层语句 → 有直接执行代码
            return $true
        }
    } catch {
        # 解析失败时保守返回 true，避免误导入
        return $true
    }
    return $false
}

# ─── 内部辅助：构建单个脚本的元信息 ─────────────────────
function __MyKit_BuildScriptInfo {
    param(
        [System.IO.FileInfo]$File,
        [string]$Category
    )
    $content = ''
    try { $content = Get-Content -Path $File.FullName -Raw -ErrorAction Stop } catch { }
    $cat = $Category
    # 从 TT.<Category>.xxx 推断分类（优先）
    if ($File.Name -match '^TT\.(\w+)\.') { $cat = $Matches[1].ToLower() }
    return [PSCustomObject]@{
        Path             = $File.FullName
        Name             = $File.Name
        Category         = $cat
        Synopsis         = __MyKit_ExtractSynopsis $content
        Functions         = __MyKit_ExtractFunctions $content
        IsArchived       = __MyKit_DetectArchived $content
        HasDirectExecute = __MyKit_HasDirectExecution $content
    }
}

# ─── 内部：扫描所有 .ps1 脚本 ─────────────────────────────
function __MyKit_ScanScripts {
    param(
        [string]$RootDir
    )
    $scripts = @()

    # 扫描根目录（bin/）下的 TT.*.ps1（扁平脚本，P2 迁移前兼容）
    $rootFiles = Get-ChildItem -Path $RootDir -Filter 'TT.*.ps1' -File -ErrorAction SilentlyContinue
    foreach ($f in $rootFiles) {
        if ($f.Name -eq 'TT.MyKit.ps1') { continue }
        $scripts += __MyKit_BuildScriptInfo -File $f -Category ''
    }

    # 扫描子目录
    $subDirs = Get-ChildItem -Path $RootDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '_core' -and $_.Name -notlike '.*' }
    foreach ($dir in $subDirs) {
        $catName = $dir.Name.ToLower()
        $files = Get-ChildItem -Path $dir.FullName -Filter '*.ps1' -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $scripts += __MyKit_BuildScriptInfo -File $f -Category $catName
        }
    }

    return $scripts
}

# ─── 内部：控制台环境检测与提示 ──────────────────────────
function __MyKit_CheckConsole {
    $warnings = @()

    # 1. 检测代码页（用 .NET API，不依赖 chcp 外部命令）
    $inCP = [Console]::InputEncoding.CodePage
    $outCP = [Console]::OutputEncoding.CodePage
    if ($inCP -ne 65001 -or $outCP -ne 65001) {
        $detail = @()
        if ($inCP -ne 65001) { $detail += "输入={0}" -f $inCP }
        if ($outCP -ne 65001) { $detail += "输出={0}" -f $outCP }
        $warnings += ("当前代码页 {0}，建议设为 65001 (UTF-8) 以正确显示中文。可执行: chcp 65001" -f ($detail -join ', '))
    }

    # 2. 检测等宽字体（仅 Windows Terminal / ConHost 可检测）
    try {
        # Windows Terminal 通过 WT_SESSION 环境变量标识，默认等宽字体
        if ($env:WT_SESSION) {
            # Windows Terminal — 默认等宽，不警告
        } else {
            # 传统 ConHost：检查注册表中的字体设置
            $regPath = 'HKCU:\Console'
            $fontVal = (Get-ItemProperty -Path $regPath -Name FaceName -ErrorAction SilentlyContinue).FaceName
            if ($null -ne $fontVal -and $fontVal -ne '') {
                # 常见等宽字体列表
                $monoFonts = @('Consolas', 'Cascadia Code', 'Cascadia Mono', 'Courier New',
                    'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'SimSun-ExtG',
                    'Lucida Console', 'DejaVu Sans Mono', 'Monaco', 'Menlo')
                $isMono = $false
                foreach ($mf in $monoFonts) {
                    if ($fontVal -like "*$mf*") { $isMono = $true; break }
                }
                if (-not $isMono) {
                    $warnings += ("当前控制台字体为 '{0}'，非等宽字体可能导致列表排版错位。建议切换为 Consolas 等宽字体。" -f $fontVal)
                }
            }
        }
    } catch {
        # 无法检测字体时忽略
    }

    return $warnings
}

# ─── Get-MyKitCategory ─────────────────────────────────────
function Get-MyKitCategory {
    <#
    .SYNOPSIS
        列出工具箱所有分类目录
    #>
    [CmdletBinding()]
    param()

    $allScripts = __MyKit_ScanScripts -RootDir $script:MyKitRoot
    $cats = $allScripts | Select-Object -ExpandProperty Category -Unique |
        Where-Object { $_ -ne '' } | Sort-Object

    $results = @()
    foreach ($cat in $cats) {
        $count = ($allScripts | Where-Object { $_.Category -eq $cat }).Count
        $results += [PSCustomObject]@{
            Category  = $cat
            Commands  = $count
        }
    }
    $uncat = ($allScripts | Where-Object { $_.Category -eq '' }).Count
    if ($uncat -gt 0) {
        $results += [PSCustomObject]@{
            Category  = '(未分类)'
            Commands  = $uncat
        }
    }

    return $results
}

# ─── Get-MyKitCommand ──────────────────────────────────────
function Get-MyKitCommand {
    <#
    .SYNOPSIS
        浏览工具箱命令列表，查看脚本帮助
    .DESCRIPTION
        无参数时列出全部可用命令。
        -Category  按分类筛选，如 git、net、disk
        -Name      按命令名/脚本名筛选（支持通配符）
        -Preview   仅显示 .SYNOPSIS 而不加载脚本
        -Detail    先加载脚本，再显示 Get-Help Full
    .EXAMPLE
        Get-MyKitCommand
        Get-MyKitCommand -Category git
        Get-MyKitCommand -Name Get-GitCodeStat -Detail
        Get-MyKitCommand -Name Split-GitStagedCommit -Preview
    #>
    [CmdletBinding()]
    param(
        [string]$Category,
        [string]$Name,
        [switch]$Preview,
        [switch]$Detail
    )

    # 控制台环境检测
    $envWarnings = __MyKit_CheckConsole
    foreach ($w in $envWarnings) {
        Write-Host $w -ForegroundColor DarkYellow
    }

    $allScripts = __MyKit_ScanScripts -RootDir $script:MyKitRoot

    # 筛选
    $filtered = $allScripts
    if ($Category -ne '') {
        $catLower = $Category.ToLower()
        $filtered = $filtered | Where-Object { $_.Category -eq $catLower }
    }
    if ($Name -ne '') {
        $filtered = $filtered | Where-Object {
            ($_.Name -like $Name) -or
            ($_.Functions -and ($_.Functions | Where-Object { $_ -like $Name }).Count -gt 0)
        }
    }

    if ($Detail -and $filtered.Count -eq 1) {
        $scriptItem = $filtered[0]
        . $scriptItem.Path
        $global:__TT_MyKit_Loaded[$scriptItem.Path.ToLower()] = (Get-Date)
        foreach ($fn in $scriptItem.Functions) {
            $fnHelp = Get-Help -Name $fn -Full -ErrorAction SilentlyContinue
            if ($fnHelp) {
                $fnHelp | Out-String | Write-Host
                break
            }
        }
        return
    }

    if ($Preview -and $filtered.Count -ge 1) {
        foreach ($item in $filtered) {
            $label = if ($item.Functions.Count -gt 0) { ($item.Functions -join ', ') } else { $item.Name }
            $archTag = if ($item.IsArchived) { ' [已存档]' } else { '' }
            Write-Host ''
            Write-Host "[$($item.Category)] $label$archTag" -ForegroundColor Cyan
            if ($item.Synopsis -ne '') {
                Write-Host "  $($item.Synopsis)" -ForegroundColor Gray
            } else {
                Write-Host '  (无 .SYNOPSIS 描述)' -ForegroundColor DarkGray
            }
        }
        return
    }

    # 默认：列表模式（基于显示宽度对齐）
    $results = @()
    foreach ($item in $filtered) {
        $funcList = if ($item.Functions.Count -gt 0) { ($item.Functions -join ', ') } else { '(直接执行)' }
        $status = if ($global:__TT_MyKit_Loaded.ContainsKey($item.Path.ToLower())) { 'loaded' } else { '--' }
        if ($item.IsArchived) { $status = 'archived' }
        if ($item.HasDirectExecute -and $item.Functions.Count -gt 0) { $status = 'mixed' }
        $synopsis = $item.Synopsis
        if ((__MyKit_DisplayWidth $synopsis) -gt 50) { $synopsis = __MyKit_TruncateDisplay $synopsis 50 }

        $results += [PSCustomObject]@{
            Category  = $item.Category
            Command   = $funcList
            Script    = $item.Name
            Status    = $status
            Synopsis  = $synopsis
        }
    }

    if ($results.Count -eq 0) {
        Write-Host '未找到匹配的命令。' -ForegroundColor Yellow
        return
    }

    # 计算各列显示宽度上限
    $catW = [Math]::Max(10, ($results | ForEach-Object { __MyKit_DisplayWidth $_.Category } | Measure-Object -Maximum).Maximum)
    $cmdW = [Math]::Max(8,  [Math]::Min(40, ($results | ForEach-Object { __MyKit_DisplayWidth $_.Command } | Measure-Object -Maximum).Maximum))
    $scrW = [Math]::Max(8,  [Math]::Min(35, ($results | ForEach-Object { __MyKit_DisplayWidth $_.Script }  | Measure-Object -Maximum).Maximum))
    $statW = 8

    # 表头
    Write-Host ''
    $headerParts = @(
        (__MyKit_PadRight 'Category' $catW),
        (__MyKit_PadRight 'Command' $cmdW),
        (__MyKit_PadRight 'Script' $scrW),
        (__MyKit_PadRight 'Status' $statW),
        'Synopsis'
    )
    Write-Host ("  " + ($headerParts -join '  ')) -ForegroundColor White
    $sepLen = $catW + $cmdW + $scrW + $statW + 4 + 50 + 8
    Write-Host ('  ' + ('-' * $sepLen))

    foreach ($r in $results) {
        $catPad  = __MyKit_PadRight $r.Category $catW
        $cmdPad  = __MyKit_TruncateDisplay $r.Command $cmdW
        $cmdPad  = __MyKit_PadRight $cmdPad $cmdW
        $scrPad  = __MyKit_TruncateDisplay $r.Script $scrW
        $scrPad  = __MyKit_PadRight $scrPad $scrW
        $statPad = __MyKit_PadRight $r.Status $statW

        $statusColor = switch ($r.Status) {
            'loaded'   { 'Green' }
            'archived' { 'DarkGray' }
            'mixed'    { 'DarkYellow' }
            default    { 'Gray' }
        }

        Write-Host ("  {0}  " -f $catPad) -NoNewline
        Write-Host ("{0}  " -f $cmdPad) -NoNewline
        Write-Host ("{0}  " -f $scrPad) -NoNewline -ForegroundColor DarkCyan
        Write-Host ("{0}  " -f $statPad) -NoNewline -ForegroundColor $statusColor
        Write-Host $r.Synopsis
    }
    Write-Host ''
}

# ─── Import-MyKit ──────────────────────────────────────────
function Import-MyKit {
    <#
    .SYNOPSIS
        导入工具箱脚本（按分类或全量）
    .DESCRIPTION
        按分类导入或全量导入工具箱脚本。
        -Category  导入指定分类下所有脚本，如 git、net
        -All       导入全部脚本
        -List      仅列出将要导入的脚本，不实际加载（干跑模式）
    .EXAMPLE
        Import-MyKit -All
        Import-MyKit -Category git
        Import-MyKit -Category git,net
        Import-MyKit -List -All
    #>
    [CmdletBinding()]
    param(
        [string[]]$Category,
        [switch]$All,
        [switch]$List
    )

    if ($Category.Count -eq 0 -and -not $All) {
        Write-Host '请指定 Category 或 All 参数。' -ForegroundColor Yellow
        # 提示信息对齐：命令列按显示宽度填充，描述列左对齐
        $cmdColW = 32
        $hints = @(
            @('Import-MyKit -List -All', '查看全部可导入脚本'),
            @('Import-MyKit -Category git', '导入指定分类'),
            @('Get-MyKitCategory', '查看所有分类'),
            @('Get-MyKitCommand', '浏览所有命令')
        )
        foreach ($h in $hints) {
            $padded = __MyKit_PadRight $h[0] $cmdColW
            Write-Host ("  {0}  {1}" -f $padded, $h[1]) -ForegroundColor Gray
        }
        return
    }

    $allScripts = __MyKit_ScanScripts -RootDir $script:MyKitRoot

    # 筛选目标，同时过滤无法 dot-source 导入的脚本
    #   - 无函数定义：纯直接执行型
    #   - 有函数定义 + 有脚本级直接执行代码：混合型（dot-source 会触发脚本级代码）
    #   两种都跳过，避免导入时卡死
    $targets = @()
    $skippedDirect = @()
    $skippedMixed = @()
    if ($All) {
        $candidates = @($allScripts | Where-Object { -not $_.IsArchived })
    } else {
        $catLowerArr = $Category | ForEach-Object { $_.ToLower() }
        $candidates = @($allScripts | Where-Object {
            ($_.Category -in $catLowerArr) -and (-not $_.IsArchived)
        })
    }
    foreach ($c in $candidates) {
        if ($c.Functions.Count -eq 0) {
            $skippedDirect += $c
        } elseif ($c.HasDirectExecute) {
            $skippedMixed += $c
        } else {
            $targets += $c
        }
    }

    if ($targets.Count -eq 0) {
        Write-Host '未找到可导入的脚本。' -ForegroundColor Yellow
        if ($skippedDirect.Count -gt 0) {
            Write-Host ("发现 {0} 个直接执行型脚本（无函数定义，只能直接运行）:" -f $skippedDirect.Count) -ForegroundColor DarkYellow
            foreach ($s in $skippedDirect) {
                Write-Host ("  {0}" -f $s.Name)
            }
        }
        if ($skippedMixed.Count -gt 0) {
            Write-Host ("发现 {0} 个混合型脚本（有函数定义但也有脚本级直接执行代码，dot-source 会触发执行）:" -f $skippedMixed.Count) -ForegroundColor DarkYellow
            foreach ($s in $skippedMixed) {
                Write-Host ("  {0}" -f $s.Name)
            }
        }
        return
    }

    # 排除已加载的
    $toLoad = @($targets | Where-Object { -not $global:__TT_MyKit_Loaded.ContainsKey($_.Path.ToLower()) })

    if ($List) {
        Write-Host ''
        Write-Host ("将导入 {0} 个脚本（已跳过 {1} 个已加载）:" -f $toLoad.Count, ($targets.Count - $toLoad.Count)) -ForegroundColor Cyan
        foreach ($item in $toLoad) {
            $archTag = if ($item.IsArchived) { ' [已存档]' } else { '' }
            Write-Host ("  [{0}] {1}{2}" -f $item.Category, $item.Name, $archTag)
        }
        if ($skippedDirect.Count -gt 0) {
            Write-Host ''
            Write-Host ("另跳过 {0} 个直接执行型脚本:" -f $skippedDirect.Count) -ForegroundColor DarkYellow
            foreach ($s in $skippedDirect) {
                Write-Host ("  {0}" -f $s.Name)
            }
        }
        if ($skippedMixed.Count -gt 0) {
            Write-Host ''
            Write-Host ("另跳过 {0} 个混合型脚本（有函数但也有脚本级代码，dot-source 会触发执行）:" -f $skippedMixed.Count) -ForegroundColor DarkYellow
            foreach ($s in $skippedMixed) {
                Write-Host ("  {0}" -f $s.Name)
            }
        }
        Write-Host ''
        return
    }

    $loadedCount = 0
    $skippedCount = 0
    foreach ($item in $toLoad) {
        try {
            . $item.Path
            $global:__TT_MyKit_Loaded[$item.Path.ToLower()] = (Get-Date)
            $loadedCount++
        } catch {
            Write-Warning ("导入失败: {0} — {1}" -f $item.Name, $_)
        }
    }
    $skippedCount = $targets.Count - $toLoad.Count

    Write-Host ''
    Write-Host ("已导入 {0} 个脚本" -f $loadedCount) -ForegroundColor Green
    if ($skippedCount -gt 0) {
        Write-Host ("已跳过 {0} 个（先前已加载）" -f $skippedCount) -ForegroundColor DarkGray
    }
    if ($skippedDirect.Count -gt 0) {
        Write-Host ("已跳过 {0} 个直接执行型脚本（无函数定义，请直接运行）:" -f $skippedDirect.Count) -ForegroundColor DarkYellow
        foreach ($s in $skippedDirect) {
            Write-Host ("  {0}" -f $s.Name)
        }
    }
    if ($skippedMixed.Count -gt 0) {
        Write-Host ("已跳过 {0} 个混合型脚本（有函数但也有脚本级代码，dot-source 会触发执行）:" -f $skippedMixed.Count) -ForegroundColor DarkYellow
        foreach ($s in $skippedMixed) {
            Write-Host ("  {0}" -f $s.Name)
        }
    }
    Write-Host ''
}
