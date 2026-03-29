@echo off
:: ========================================
:: Tax Collector - Deploy Python Scripts
:: ========================================
::
:: Copies prod/scripts/ Python files to the server's automation-io folder.
:: These scripts are called by n8n workflows via Execute Command nodes.
::
:: SOURCE: tax-collector/prod/scripts/
:: TARGET: X:\automation-io\tax-collector\scripts\
:: SERVER PATH: /mnt/disk2/automation-io/tax-collector/scripts/
:: N8N CONTAINER PATH: /data/tax-collector/scripts/
::
:: NOTE: n8n workflow JSON files are NOT copied by this script.
::       Import them manually via the n8n UI (n8n.rodinah.dev).
::

echo.
echo ========================================
echo   Tax Collector - Deploy Python Scripts
echo ========================================
echo.

:: Check if X: drive is mapped
if not exist "X:\automation-io" (
    echo ERROR: Server drive X: is not mapped or automation-io folder missing.
    echo Map the server share before running this script.
    pause
    exit /b 1
)

:: Create target folder if it doesn't exist
if not exist "X:\automation-io\tax-collector\scripts" (
    echo Creating target folder on server...
    mkdir "X:\automation-io\tax-collector\scripts"
)

echo Deploying Python scripts to server...
echo SOURCE: %~dp0..\..\prod\scripts\
echo TARGET: X:\automation-io\tax-collector\scripts\
echo.

:: Copy all Python scripts (top-level only — no subdirs needed yet)
xcopy /Y /I "%~dp0..\..\prod\scripts\*.py" "X:\automation-io\tax-collector\scripts\"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: xcopy failed.
    pause
    exit /b 1
)

echo.
echo ========================================
echo   DEPLOYMENT COMPLETE
echo ========================================
echo.
echo Scripts are now available inside n8n container at:
echo   /data/tax-collector/scripts/
echo.
echo To import workflows:
echo   1. Open https://n8n.rodinah.dev
echo   2. Workflows -^> Add Workflow -^> Import from File
echo   3. Select files from: prod\workflows\
echo.
pause
