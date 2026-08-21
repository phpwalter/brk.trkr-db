@echo off
setlocal EnableExtensions
cls

rem =============================================================================
rem  File:           bootstrap.bat
rem  Project:        BrickTrackr
rem  Purpose:        Recreate the BrickTrackr PostgreSQL database from scratch
rem                  and install the complete master schema.
rem  PostgreSQL:     16+
rem =============================================================================

set "SCRIPT_DIR=%~dp0"
set "BOOTSTRAP_SQL=%SCRIPT_DIR%bootstrap.sql"

rem -----------------------------------------------------------------------------
rem Configuration
rem -----------------------------------------------------------------------------

if not defined PGHOST set "PGHOST=localhost"
if not defined PGPORT set "PGPORT=5432"
if not defined PGUSER set "PGUSER=root"

set "MAINTENANCE_DB=postgres"
set "APP_DB=bricktrackr"


rem -----------------------------------------------------------------------------
rem Verify psql.exe is available
rem -----------------------------------------------------------------------------

where psql.exe >nul 2>&1

if errorlevel 1 (
    echo.
    echo ===============================================================================
    echo  ERROR
    echo ===============================================================================
    echo.
    echo  psql.exe was not found in PATH.
    echo.
    echo  Add the PostgreSQL bin directory to PATH and try again.
    echo.
    exit /b 10
)


rem -----------------------------------------------------------------------------
rem Verify bootstrap.sql exists
rem -----------------------------------------------------------------------------

if not exist "%BOOTSTRAP_SQL%" (
    echo.
    echo ===============================================================================
    echo  ERROR
    echo ===============================================================================
    echo.
    echo  bootstrap.sql was not found:
    echo.
    echo    "%BOOTSTRAP_SQL%"
    echo.
    exit /b 11
)


rem -----------------------------------------------------------------------------
rem Banner
rem -----------------------------------------------------------------------------

echo.
echo ===============================================================================
echo  BrickTrackr PostgreSQL Fresh Database Bootstrap
echo ===============================================================================
echo.
echo  Host:          %PGHOST%
echo  Port:          %PGPORT%
echo  User:          %PGUSER%
echo  Maintenance:   %MAINTENANCE_DB%
echo  Application:   %APP_DB%
echo  Bootstrap SQL: %BOOTSTRAP_SQL%
echo.
echo  WARNING:
echo  The database "%APP_DB%" will be deleted if it already exists.
echo  All data currently stored in that database will be permanently removed.
echo.


rem -----------------------------------------------------------------------------
rem Verify PostgreSQL connection
rem -----------------------------------------------------------------------------

echo [PRECHECK] Testing PostgreSQL connection...

psql.exe ^
    -X ^
    -v ON_ERROR_STOP=1 ^
    -h "%PGHOST%" ^
    -p "%PGPORT%" ^
    -U "%PGUSER%" ^
    -d "%MAINTENANCE_DB%" ^
    -c "SELECT version();" ^
    >nul

if errorlevel 1 (
    set "EXIT_CODE=%ERRORLEVEL%"

    echo.
    echo ===============================================================================
    echo  BrickTrackr bootstrap FAILED
    echo ===============================================================================
    echo.
    echo  Unable to connect to PostgreSQL.
    echo.
    echo  Exit code: %EXIT_CODE%
    echo.
    exit /b %EXIT_CODE%
)

echo [PRECHECK] PostgreSQL connection successful.
echo.


rem -----------------------------------------------------------------------------
rem Drop existing application database
rem
rem WITH (FORCE) disconnects existing sessions before dropping the database.
rem PostgreSQL 13+ supports DROP DATABASE ... WITH (FORCE).
rem -----------------------------------------------------------------------------

echo [DATABASE] Dropping existing "%APP_DB%" database if present...

psql.exe ^
    -X ^
    -v ON_ERROR_STOP=1 ^
    -h "%PGHOST%" ^
    -p "%PGPORT%" ^
    -U "%PGUSER%" ^
    -d "%MAINTENANCE_DB%" ^
    -c "DROP DATABASE IF EXISTS \"%APP_DB%\" WITH (FORCE);"

if errorlevel 1 (
    set "EXIT_CODE=%ERRORLEVEL%"

    echo.
    echo ===============================================================================
    echo  BrickTrackr bootstrap FAILED
    echo ===============================================================================
    echo.
    echo  Unable to drop database "%APP_DB%".
    echo.
    echo  Exit code: %EXIT_CODE%
    echo.
    exit /b %EXIT_CODE%
)

echo [DATABASE] Existing database removed.
echo.


rem -----------------------------------------------------------------------------
rem Create fresh application database
rem -----------------------------------------------------------------------------

echo [DATABASE] Creating fresh "%APP_DB%" database...

psql.exe ^
    -X ^
    -v ON_ERROR_STOP=1 ^
    -h "%PGHOST%" ^
    -p "%PGPORT%" ^
    -U "%PGUSER%" ^
    -d "%MAINTENANCE_DB%" ^
    -c "CREATE DATABASE \"%APP_DB%\";"

if errorlevel 1 (
    set "EXIT_CODE=%ERRORLEVEL%"

    echo.
    echo ===============================================================================
    echo  BrickTrackr bootstrap FAILED
    echo ===============================================================================
    echo.
    echo  Unable to create database "%APP_DB%".
    echo.
    echo  Exit code: %EXIT_CODE%
    echo.
    exit /b %EXIT_CODE%
)

echo [DATABASE] Fresh database created.
echo.


rem -----------------------------------------------------------------------------
rem Change working directory
rem
rem bootstrap.sql uses relative \ir paths, so execution must occur from the
rem master schema directory.
rem -----------------------------------------------------------------------------

pushd "%SCRIPT_DIR%" >nul 2>&1

if errorlevel 1 (
    echo.
    echo ===============================================================================
    echo  BrickTrackr bootstrap FAILED
    echo ===============================================================================
    echo.
    echo  Unable to change directory to:
    echo.
    echo    "%SCRIPT_DIR%"
    echo.
    exit /b 12
)


rem -----------------------------------------------------------------------------
rem Install master schema
rem -----------------------------------------------------------------------------

echo ===============================================================================
echo  Installing BrickTrackr master schema
echo ===============================================================================
echo.

psql.exe ^
    -X ^
    -v ON_ERROR_STOP=1 ^
    -h "%PGHOST%" ^
    -p "%PGPORT%" ^
    -U "%PGUSER%" ^
    -d "%APP_DB%" ^
    -f "bootstrap.sql"

set "PSQL_EXIT_CODE=%ERRORLEVEL%"

popd >nul 2>&1


rem -----------------------------------------------------------------------------
rem Handle bootstrap failure
rem -----------------------------------------------------------------------------

if not "%PSQL_EXIT_CODE%"=="0" (
    echo.
    echo ===============================================================================
    echo  BrickTrackr schema installation FAILED
    echo ===============================================================================
    echo.
    echo  Database:       %APP_DB%
    echo  psql exit code: %PSQL_EXIT_CODE%
    echo.
    echo  The "%APP_DB%" database exists, but schema installation did not
    echo  complete successfully.
    echo.

    exit /b %PSQL_EXIT_CODE%
)


rem -----------------------------------------------------------------------------
rem Success
rem -----------------------------------------------------------------------------

echo.
echo ===============================================================================
echo  BrickTrackr master schema v10.0 installed successfully.
echo ===============================================================================
echo.
echo  Database: %APP_DB%
echo  Host:     %PGHOST%
echo  Port:     %PGPORT%
echo.
echo ===============================================================================
echo.

exit /b 0