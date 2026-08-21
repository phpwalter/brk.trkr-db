@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=master.schema"
set "OUTPUT=master_schema_combined.txt"

if not exist "%ROOT%\" (
    echo ERROR: Directory "%ROOT%" was not found.
    exit /b 1
)

if exist "%OUTPUT%" del "%OUTPUT%"

echo Building %OUTPUT%...
echo.

(
    echo ========================================================================
    echo MASTER SCHEMA COMBINED SQL
    echo Generated from: %ROOT%
    echo ========================================================================
    echo.
) > "%OUTPUT%"

for /f "delims=" %%F in ('dir /b /s /a-d "%ROOT%\*.sql" ^| sort') do (
    echo Adding: %%F

    >> "%OUTPUT%" echo.
    >> "%OUTPUT%" echo.
    >> "%OUTPUT%" echo ========================================================================
    >> "%OUTPUT%" echo FILE: %%F
    >> "%OUTPUT%" echo ========================================================================
    >> "%OUTPUT%" echo.

    type "%%F" >> "%OUTPUT%"
)

echo.
echo Complete.
echo Output: %OUTPUT%

endlocal