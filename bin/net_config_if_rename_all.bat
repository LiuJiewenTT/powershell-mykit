@if "%~1" == "" goto:eof
@if "%~2" == "" goto:eof
@setlocal enabledelayedexpansion
@for /f "usebackq" %%i in ("%~dp0net_config_classes.txt") do @(
    echo Current class: %%i
    call "%~dp0net_config_if_rename.bat" "%~dp0TT.%%i.net_config_%~1.json" "%~2"
)

@endlocal