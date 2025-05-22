@setlocal
@set flag=0
@for /f "delims=" %%i in ('echo "%PATH%" ^| findstr /i "powershell-mykit"') do @set flag=1
@if %flag%==1 (
  @echo powershell-mykit is already in PATH.
) else (
  @endlocal && set "PATH=%~dp0;%PATH%"
  @echo powershell-mykit is added to PATH.
)
@echo Use "dir_powershell_mykit" to list the directory contents of powershell-mykit.
set POWERSHELL_MYKIT_DIR=%~dp0
@endlocal