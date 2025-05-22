@REM This script is used to rename network interface configuration file when ifIndex is changed.

@if "%~1" == "" goto:eof
@if "%~2" == "" goto:eof
@if not exist "%~1" @(
    echo File not exists.
    goto :eof
)
@setlocal
@for /f "tokens=1,2,3 delims=_" %%i in ("%~n1") do @(
    echo Current if = %%k
    echo New if = %~2
    set basename=%%i_%%j
    set newname=%%i_%%j_%~2
)
@set newname=%newname%%~x1
@echo New net config name: %newname%
@if exist "%newname%" (
    echo File exists. Abort.
    goto:eof
)
@choice /M "Confirm"
@if ERRORLEVEL 2 (
    goto:eof
)
ren "%~1" "%newname%"
@if exist "%~dp1%newname%" (
    echo File exists. Success.
    goto:eof
) else (
    echo Failed.
)
@endlocal
