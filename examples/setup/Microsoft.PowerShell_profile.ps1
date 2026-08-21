$mykit_dir = "G:\TT.OS.ToolKit\Windows\powershell-mykit\bin\"
Write-Host "`$mykit_dir=${mykit_dir}"
$env:PATH += ";$mykit_dir"

try {
    $currentCP = (chcp | Out-String) -replace "[^\d]",""
    if ($currentCP -ne "65001") {
        Write-Host "[LOG]: Active code page is not 65001(UTF-8). [$currentCP]"
        chcp 65001 | Out-Null
    }
} catch {
    Write-Warning "Failed to check/set code page: $_"
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ─── 加载工具箱入口 ──────────────────────────────────────
# dot-source 加载后即可使用：Get-MyKitCommand, Get-MyKitCommandList, Import-MyKit, Get-MyKitCategory
# 如需自动导入全部工具，取消下行注释：
# Import-MyKit -All
. "$mykit_dir\TT.MyKit.ps1"

# ─── 保留兼容：旧的 Import-ScriptFunctions ───────────────
. "$mykit_dir\_core\TT.LoadScript.Utils.ps1"


function profile_home {
    ishome
}

function profile_normal {
    isnormal
}

function profile_work {
    iswork
}


function ishome {
    $init_file = "_sceneinit\TT.Home.Init.ps1"

    $filepath = Join-Path -Path $mykit_dir -ChildPath $init_file
    echo "init_file path: $filepath"
    # Import-ScriptFunctions $filepath
    . $filepath

    Home-NetInit
}


function isnormal {
    $init_file = "_sceneinit\TT.Normal.Init.ps1"

    $filepath = Join-Path -Path $mykit_dir -ChildPath $init_file
    echo "init_file path: $filepath"
    # Import-ScriptFunctions $filepath
    . $filepath

    Normal-NetInit
}


function iswork {
    $init_file = "_sceneinit\TT.Work1.Init.ps1"

    $filepath = Join-Path -Path $mykit_dir -ChildPath $init_file
    echo "init_file path: $filepath"
    # Import-ScriptFunctions $filepath
    . $filepath

    Work1-NetInit
}


# @description 获取第一个匹配的网络适配器 Id
# @param[input] 
# @param[output] $global:adapterId 匹配到的网络适配器 Id
function getIfAdapterIdExist {
    # 获取所有网络适配器的 ID 列表
    $adapterList = Get-NetAdapter | Select-Object -ExpandProperty ifIndex
    $targetAdapterId_cnt = 2
    $targetAdapterId_1 = 6   # 以太网
    $targetAdapterId_2 = 18  # 以太网 2
    # 使用 for 循环从 1 遍历到 cnt
    for ($i = 1; $i -le $targetAdapterId_cnt; $i++) {
        ${targetAdapterId_i} = (Get-Variable -Name "targetAdapterId_${i}").Value
        Write-Host "尝试匹配第${i}个网络适配器, Id=${targetAdapterId_i}"
        if ($adapterList -contains ${targetAdapterId_i}) {
            Write-Host "找到的网络适配器Id是：${targetAdapterId_i}"
            $global:adapterId = ${targetAdapterId_i}
            break
        }
    }
}


getIfAdapterIdExist
