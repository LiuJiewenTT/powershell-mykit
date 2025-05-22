

function Work1-NetInit {
    $directory = $PSScriptRoot
    $childpath = "TT.NetIP.utils.ps1"
    $filepath = Join-Path -Path $directory -ChildPath $childpath
    . $filepath
    
    $childpath = "TT.Work1.net_config_${adapterId}.json"
    $filepath = Join-Path -Path $directory -ChildPath $childpath
    Restore-NetworkConfiguration -FilePath $filepath
}


function Work1-NetSaveFile {
    $directory = $PSScriptRoot
    $childpath = "TT.NetIP.utils.ps1"
    $filepath = Join-Path -Path $directory -ChildPath $childpath
    . $filepath
    
    # 获取网络适配器信息并以表格形式显示
    $adapters = Get-NetAdapter | Select-Object -Property Name, Status, ifIndex, MacAddress, InterfaceDescription
    
    Write-Host "`n可用网络适配器:"
    $adapters | Format-Table -AutoSize -Property @(
        @{Label="序号"; Expression={$adapters.IndexOf($_)+1}}
        'Name'
        'Status' 
        'ifIndex'
        'MacAddress'
        'InterfaceDescription'
    )
    
    # 创建适配器列表映射
    $adapterList = @{}
    for ($i=0; $i -lt $adapters.Count; $i++) {
        $adapterList[$i+1] = $adapters[$i].Name
    }
    
    # User selects adapter
    do {
        $selection = Read-Host "`n请输入要配置的网络适配器序号 (1-$($adapters.Count))"
        $isValid = $selection -match "^\d+$" -and $selection -ge 1 -and $selection -le $adapters.Count
        if (-not $isValid) {
            Write-Host "输入错误，请输入1到$($adapters.Count)之间的数字" -ForegroundColor Red
        }
    } while (-not $isValid)
    
    $selectedAdapter = $adapterList[[int]$selection]
    $adapterId = $adapters[[int]$selection-1].ifIndex
    
    # Save configuration
    $childpath = "TT.Work1.net_config_${adapterId}.json"
    $filepath = Join-Path -Path $directory -ChildPath $childpath
    Write-Host "正在保存配置到文件: $filepath"
    Save-NetworkConfiguration -FilePath $filepath -InterfaceAlias $selectedAdapter
}


function Work1-Init-Imported {
    echo true
}