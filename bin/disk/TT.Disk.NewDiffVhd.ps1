<#
.SYNOPSIS
PowerShell 5.1 差分VHD/VHDX一键创建工具
文件名：New-DiffVhd.ps1
功能：交互式选择母盘，弹窗选保存路径，自动提权创建差分盘，可选锁定母盘只读
规则：传入母盘路径参数则跳过手动输入；窗体异常自动降级命令行交互
#>
#Requires -Modules Hyper-V
# 全局一次性加载窗体程序集，脚本最顶部执行
Add-Type -AssemblyName System.Windows.Forms

<#
弹窗统一封装：弹窗正常弹出，加载失败自动降级控制台文字交互
返回值：6=Yes，7=No，1=OK，和原生DialogResult数值保持一致
#>
function Show-MsgBox {
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [Parameter(Mandatory)]
        [string]$Title,
        [ValidateSet("OK","YesNo")]
        [string]$Buttons = "OK",
        [ValidateSet("None","Error","Warning","Information","Question")]
        [string]$Icon = "None"
    )

    try {
        $result = [System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon)
        return [int]$result
    }
    catch {
            # 弹窗彻底失败，切换控制台文字交互
            Write-Host "`n【$Title】`n$Text" -ForegroundColor Yellow
            Write-Host "弹窗异常: $($_.Exception.Message)" -ForegroundColor Red
            if ($Buttons -eq "YesNo") {
                do {
                    $inp = (Read-Host "请输入 Y 确认 / N 取消").Trim().ToLower()
                } while ($inp -notin 'y', 'n')
                # 修复：PS5.1 不支持 return if()，拆分标准if else
                if ($inp -eq 'y')
                {
                    return 6
                }
                else
                {
                    return 7
                }
            }
            return 1
        }
}

<#
核心创建差分盘主函数
.PARAMETER ParentVhdPath 外部传入母盘完整路径，传入后跳过手动输入环节
.PARAMETER ChildVhdPath 外部传入子盘保存路径，传入后跳过SaveFileDialog弹窗选择
#>
function New-VhdDifferencingChild {
    [CmdletBinding()]
    param (
        [string]$ParentVhdPath,
        [string]$ChildVhdPath
    )

    #region 步骤1：处理母盘路径
    if ([string]::IsNullOrWhiteSpace($ParentVhdPath)) {
        try {
            # 优先弹窗选择母盘
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = "请选择母盘VHD/VHDX文件"
            $dlg.Filter = "虚拟磁盘文件(*.vhd;*.vhdx)|*.vhd;*.vhdx|所有文件(*.*)|*.*"
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $ParentVhdPath = $dlg.FileName
            }
        }
        catch{
            Write-Host "文件选择弹窗加载失败，将降级为手动输入路径。" -ForegroundColor Yellow
            Write-Host "弹窗异常: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # 弹窗取消或失败后，降级为手动输入
    if ([string]::IsNullOrWhiteSpace($ParentVhdPath)) {
        Write-Host "`n===== 手动输入母盘VHD/VHDX路径 =====" -ForegroundColor Cyan
        Write-Host "可选输入方式："
        Write-Host "1. Windows Terminal普通权限窗口直接拖拽文件填入；"
        Write-Host "2. 文件按住【Shift键+右键】→ 复制为路径，Ctrl+V粘贴到此；"
        Write-Host "3. Win+R运行框拖拽文件，复制路径后粘贴；"
        Write-Host "4. 手动输入完整文件路径"
        Write-Host "输入完成按下回车确认`n" -ForegroundColor Cyan
        $ParentVhdPath = Read-Host "母盘文件完整路径"
        # 剔除首尾引号、空格、单引号脏字符
        $trimChars = @('"', "'", ' ')
        $ParentVhdPath = $ParentVhdPath.Trim($trimChars)
    }

    # 校验母盘文件合法性
    if (-not (Test-Path -Path $ParentVhdPath -PathType Leaf)) {
        Show-MsgBox -Text "目标母盘文件不存在：`n$ParentVhdPath" -Title "路径校验失败" -Icon Error
        return
    }
    $fileInfo = Get-Item -LiteralPath $ParentVhdPath
    $ext = $fileInfo.Extension.ToLower()
    if ($ext -notin '.vhd', '.vhdx') {
        Show-MsgBox -Text "仅支持 .vhd / .vhdx 格式虚拟磁盘" -Title "格式不支持" -Icon Error
        return
    }
    #endregion

    #region 步骤2：风险确认弹窗
    $warnContent = @"
【重要风险警告】
1. 差分子盘会硬绑定当前母盘绝对路径：
$ParentVhdPath
2. 母盘移动、重命名、剪切后差分盘将失效；
3. 母盘迁移修复绑定命令参考：
Set-VHD -Path "差分盘路径" -ParentPath "新母盘完整路径"

确认继续创建差分子磁盘？
"@
    $confirmCreate = Show-MsgBox -Text $warnContent -Title "绑定路径风险提示" -Buttons YesNo -Icon Warning
    if ($confirmCreate -eq 7) {
        Write-Host "用户取消创建任务，脚本退出" -ForegroundColor DarkCyan
        return
    }
    #endregion

    #region 步骤3：选择子盘保存路径，外部传参则跳过弹窗
    if ([string]::IsNullOrWhiteSpace($ChildVhdPath)) {
        try {
            # PowerShell 5.1 & WinForms: 直接调用即可，无需Task.Run避免MTA/STA线程死锁
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Title = "指定差分子磁盘保存位置与文件名"
            $dlg.InitialDirectory = $fileInfo.DirectoryName
            $dlg.FileName = "$($fileInfo.BaseName)_Diff.vhdx"
            $dlg.Filter = "VHDX磁盘(*.vhdx)|*.vhdx|VHD磁盘(*.vhd)|*.vhd"
            $dlg.RestoreDirectory = $true
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $ChildVhdPath = $dlg.FileName
            }

            if ([string]::IsNullOrWhiteSpace($ChildVhdPath)) {
                Write-Host "取消选择保存路径，任务终止" -ForegroundColor DarkCyan
                return
            }
        }
        catch {
            Write-Host "文件选择弹窗加载失败，请手动输入子盘完整保存路径：" -ForegroundColor Red
            Write-Host "弹窗异常: $($_.Exception.Message)" -ForegroundColor Red
            $ChildVhdPath = Read-Host "输出路径"
            $ChildVhdPath = $ChildVhdPath.Trim(@('"', "'", ' '))
            if ([string]::IsNullOrWhiteSpace($ChildVhdPath)) { return }
        }
    }
    #endregion

    #region 步骤4：判断当前权限，决定本地执行 / 拉起管理员进程
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # 核心执行逻辑脚本块
    $execScript = {
        param(
            [string]$ParentDisk,
            [string]$ChildDisk
        )
        $ErrorActionPreference = "Stop"
        Add-Type -AssemblyName System.Windows.Forms

        function Show-MsgBox {
            param(
                [Parameter(Mandatory)]
                [string]$Text,
                [Parameter(Mandatory)]
                [string]$Title,
                [ValidateSet("OK","YesNo")]
                [string]$Buttons = "OK",
                [ValidateSet("None","Error","Warning","Information","Question")]
                [string]$Icon = "None"
            )
            Add-Type -AssemblyName System.Windows.Forms
            try {
                $res = [System.Windows.Forms.MessageBox]::Show($Text,$Title,$Buttons,$Icon)
                return [int]$res
            }
            catch {
                Write-Host "`n【$Title】`n$Text" -ForegroundColor Yellow
                if($Buttons -eq "YesNo"){
                    do{$inp=(Read-Host "Y/N").Trim().ToLower()}while($inp -notin 'y','n')
                    if($inp -eq 'y'){return 6}else{return 7}
                }
                return 1
            }
        }

        try {
            # 创建差分VHD
            New-VHD -Path $ChildDisk -ParentPath $ParentDisk -Differencing
            $successText = @"
✅ 差分磁盘创建成功！

子盘路径：$ChildDisk
绑定母盘：$ParentDisk

母盘迁移修复命令示例：
Set-VHD -Path "$ChildDisk" -ParentPath "D:\新目录\母盘.vhdx"
"@
            Show-MsgBox -Text $successText -Title "创建成功" -Icon Information

            # 弹窗询问锁定母盘只读
            $roAns = Show-MsgBox -Text "是否将母盘设置只读属性，防止误写入破坏差分链？`n母盘：$ParentDisk" `
                -Title "母盘只读保护" -Buttons YesNo -Icon Question
            if ($roAns -eq 6) {
                $pItem = Get-Item -LiteralPath $ParentDisk
                $pItem.Attributes += [System.IO.FileAttributes]::ReadOnly
                Write-Host "✅ 母盘已设置只读保护" -ForegroundColor Green
            }
            else {
                Write-Host "已跳过只读设置，请自行保护母盘不被修改" -ForegroundColor DarkYellow
            }
        }
        catch {
            Show-MsgBox -Text "执行失败：`n$($_.Exception.Message)" -Title "创建异常" -Icon Error
            Write-Host "`n❌ 执行异常：$($_.Exception.Message)" -ForegroundColor Red
        }
        # 窗口阻塞等待回车，防止管理员窗口一闪关闭
        Read-Host "`n执行完毕，按下回车键关闭当前窗口" | Out-Null
    }

    if ($isAdmin) {
        # 当前已是管理员，直接本地执行
        & $execScript -ParentDisk $ParentVhdPath -ChildDisk $ChildVhdPath
    }
    else {
        # 普通权限，将完整执行逻辑拼接为字符串，整体Base64编码后拉起管理员进程
        # 这是为了确保脚本块和参数能被新进程正确接收
        $commandString = "& { $($execScript.ToString()) } -ParentDisk '$ParentVhdPath' -ChildDisk '$ChildVhdPath'"
        $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandString))

        Write-Host "当前非管理员权限，即将拉起管理员窗口执行创建任务..." -ForegroundColor Yellow
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            "-ExecutionPolicy", "Bypass",
            "-NoProfile",
            "-EncodedCommand", $encodedCommand
        )
        Write-Host "管理员任务已启动，当前窗口可关闭；等待管理员窗口手动回车关闭即可" -ForegroundColor Green
    }
    #endregion
}

# 脚本入口
New-VhdDifferencingChild @args

# 主线程收尾阻塞
Write-Host "`n主线程准备退出，按下任意键关闭本窗口..." -ForegroundColor Gray
[Console]::ReadKey($true) | Out-Null