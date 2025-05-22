
# @description Save network configuration to a file
# @param string $InterfaceAlias The network interface alias
# @param string $FilePath The file path to save the network configuration
function Save-NetworkConfiguration {
    param (
        [string]$InterfaceAlias,
        [string]$FilePath
    )    

    $ipConfig = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength, DefaultGateway
    $dnsConfig = Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias | Select-Object ServerAddresses
    
    $isDhcpEnabled = (Get-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4).Dhcp
    $isDnsRegisterThisConnectionsAddress = (Get-DnsClient -InterfaceAlias $InterfaceAlias).RegisterThisConnectionsAddress

    $settings = @{
        IsDhcpEnabled = $isDhcpEnabled
        IsDnsRegisterThisConnectionsAddress = $isDnsRegisterThisConnectionsAddress
        InterfaceAlias = $InterfaceAlias
        IPAddresses = $ipConfig.IPAddress
        PrefixLength = $ipConfig.PrefixLength
        DefaultGateway = $ipConfig.DefaultGateway
        DnsServers = $dnsConfig.ServerAddresses -join ","
    }

    $settings | ConvertTo-Json | Set-Content -Path $FilePath
}


function Restore-NetworkConfiguration {
    param (
        [string]$FilePath
    )

    if (Test-Path $FilePath) {
        $settings = Get-Content -Path $FilePath | ConvertFrom-Json
        Write-Host "Saved Config: $settings"
        Write-Host

        if ($settings.IsDhcpEnabled) {
            Write-Host "正在启用DHCP"
            Set-NetIPInterface -InterfaceAlias $settings.InterfaceAlias -Dhcp Enabled -PolicyStore ActiveStore

            if($settings.IsDnsRegisterThisConnectionsAddress) {
                Set-DnsClient -InterfaceAlias $settings.InterfaceAlias -RegisterThisConnectionsAddress $true
            }
        } else {
            foreach ($IPAddress in $settings.IPAddresses) {
                if ($IPAddress) {
                    Write-Host "正在设置IPv4地址：[$IPAddress]"
                    New-NetIPAddress -InterfaceAlias $settings.InterfaceAlias -IPAddress $IPAddress -PrefixLength $settings.PrefixLength -DefaultGateway $settings.DefaultGateway -PolicyStore ActiveStore
                }
            }
        }
        Write-Host "正在设置DNS地址：[$(($settings).DnsServers)]"
        Set-DnsClientServerAddress -InterfaceAlias $settings.InterfaceAlias -ServerAddresses ($settings.DnsServers -split ",")
        Write-Host "设置完成"
    } else {
        Write-Host "指定的文件路径不存在: $FilePath"
    }
}
