@if "%~1" == "" (
	dir "%~dp0"
) else (
	dir %~dp0%*
)