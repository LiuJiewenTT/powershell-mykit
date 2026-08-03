$bytes = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TranscodedImageCache).TranscodedImageCache
($bytes = $bytes[24..($bytes.Length-1)]) 2>$null 1>$null
$text = [System.Text.Encoding]::Unicode.GetString($bytes)
($text -replace "`0.*" ) -replace '.*([A-Z]:\\.*\.(jpg|png|bmp|jpeg))','$1'