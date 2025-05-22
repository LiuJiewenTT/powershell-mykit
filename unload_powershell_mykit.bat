@setlocal enabledelayedexpansion
@set flag=0
@for /f "delims=" %%i in ('echo "%PATH%" ^| findstr /i "powershell-mykit"') do @set flag=1
@if %flag%==0 (
    @echo powershell-mykit is not in PATH.
    @endlocal
    goto :eof
)
@echo Unloading powershell-mykit...
@set "newpath=!PATH:%~dp0;=!"
@endlocal && set "PATH=%newpath%"
@set POWERSHELL_MYKIT_DIR=
@echo powershell-mykit has been unloaded.
