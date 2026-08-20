<#
功能：扫描当前目录【无扩展名文件】，通过文件魔数识别图片类型，批量添加后缀
支持格式：JPG,PNG,WEBP,GIF,BMP,TIFF,ICO,HEIC,AVIF
#>

# ===================== 魔数映射表（图片文件头） =====================
$magicTable = @(
    @{Sig=[byte[]]@(0xFF,0xD8,0xFF); Ext="jpg"; Desc="JPEG"},
    @{Sig=[byte[]]@(0x89,0x50,0x4E,0x47); Ext="png"; Desc="PNG"},
    @{Sig=[byte[]]@(0x52,0x49,0x46,0x46); Ext="webp"; Desc="WebP"}, # RIFF....WEBP
    @{Sig=[byte[]]@(0x47,0x49,0x46,0x38); Ext="gif"; Desc="GIF"},
    @{Sig=[byte[]]@(0x42,0x4D); Ext="bmp"; Desc="BMP"},
    @{Sig=[byte[]]@(0x49,0x49,0x2A,0x00); Ext="tiff"; Desc="TIFF(LE)"},
    @{Sig=[byte[]]@(0x4D,0x4D,0x2A,0x00); Ext="tiff"; Desc="TIFF(BE)"},
    @{Sig=[byte[]]@(0x00,0x00,0x01,0x00); Ext="ico"; Desc="ICO图标"},
    @{Sig=[byte[]]@(0x66,0x74,0x79,0x70,0x68,0x65,0x69,0x63); Ext="heic"; Desc="HEIC"},
    @{Sig=[byte[]]@(0x66,0x74,0x79,0x70,0x61,0x76,0x69,0x66); Ext="avif"; Desc="AVIF"}
)

# 读取当前目录所有文件，筛选【没有扩展名】的文件
$allFiles = Get-ChildItem -File
$noExtFiles = $allFiles | Where-Object { $_.Extension -eq "" }

if($noExtFiles.Count -eq 0){
    Write-Host "当前目录没有找到无扩展名的文件" -ForegroundColor Cyan
    Read-Host "回车退出"
    exit
}

$renameList = @()

Write-Host "`n==================== 扫描结果预览 ====================" -ForegroundColor Yellow
foreach($file in $noExtFiles){
    $fs = [System.IO.File]::OpenRead($file.FullName)
    # 最多读取前16字节，足够识别所有图片头
    $buffer = New-Object byte[] 16
    $readLen = $fs.Read($buffer,0,16)
    $fs.Close()

    $matchExt = $null
    foreach($entry in $magicTable){
        $sigLen = $entry.Sig.Length
        if($readLen -ge $sigLen){
            $equal = $true
            for($i=0;$i -lt $sigLen;$i++){
                if($buffer[$i] -ne $entry.Sig[$i]){
                    $equal=$false;break
                }
            }
            if($equal){
                $matchExt = $entry.Ext
                break
            }
        }
    }

    if($matchExt){
        $newName = "$($file.BaseName).$matchExt"
        $renameList += [PSCustomObject]@{
            原文件名 = $file.Name
            识别格式 = $matchExt
            新文件名 = $newName
        }
        Write-Host "✅ $($file.Name)  --> $newName"
    }else{
        Write-Host "❌ $($file.Name) 无法识别为支持的图片" -ForegroundColor DarkGray
    }
}

if($renameList.Count -eq 0){
    Write-Host "`n没有可以重命名的图片文件" -ForegroundColor Cyan
    Read-Host "回车退出"
    exit
}

Write-Host "`n======================================================" -ForegroundColor Yellow
$confirm = Read-Host "确认执行批量重命名？【Y=执行 / 其他按键取消】"
if($confirm.ToUpper() -ne "Y"){
    Write-Host "已取消操作"
    exit
}

# 开始重命名
Write-Host "`n开始重命名..." -ForegroundColor Green
foreach($item in $renameList){
    $oldFile = Join-Path $PWD.Path $item.原文件名
    $newFileName = $item.新文件名
    $fullNewPath = Join-Path $PWD.Path $newFileName

    if(Test-Path $fullNewPath){
        Write-Host "⚠️ 冲突跳过：$newFileName 已存在" -ForegroundColor Red
        continue
    }
    # PS5.1 标准语法，只传文件名给 -NewName
    Rename-Item -Path $oldFile -NewName $newFileName
    Write-Host "✔️ $($item.原文件名) → $newFileName"
}

Write-Host "`n全部任务完成！" -ForegroundColor Green
Read-Host "按回车键关闭窗口"
