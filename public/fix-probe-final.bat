@echo off
echo ========================================
echo TestDeck - Probe JSON es Writable Folder Javitas
echo ========================================
echo.
echo Javitasok:
echo 1. Enum ertekek (HealthStatus, OperationalStatus) explicit stringge konvertalasa
echo 2. Letters tomb szurese: csak ervenyes A-Z betuk
echo 3. Get-WritableFolder fallback mappakkal (Downloads, Desktop, TEMP)
echo 4. Rszletes logolas a writable folder kereseshez
echo.
echo A probe.ps1 fajl frissitve!
echo.
echo Most inditsd ujra a probe-ot:
echo   1. Allitsd le a jelenlegi probe-ot (Ctrl+C a probe konzolban)
echo   2. Futtasd: start-probe.bat
echo.
echo A probe konzolban a kovetkezot kellene latnod:
echo   [INVENTORY] Added drive: ... | Letters: C,D
echo   [WRITABLE] Testing: C:\TestDeck
echo   [WRITABLE] Found writable folder: C:\TestDeck
echo.
echo A JSON valaszban a kovetkezot kellene latnod:
echo   "healthStatus":"Healthy"
echo   "operationalStatus":"Online"
echo   "letters":["C","D"]
echo.
echo Ha meg mindig problemad van, kuldd el a probe konzol teljes kimenetet!
echo.
pause
