@echo off
echo ========================================
echo TestDeck - Probe JSON Fix
echo ========================================
echo.
echo Fajlok masolasa dist mappabol public mappaba...
xcopy /E /I /Y "dist\*" "public\"
echo.
echo Masolas befejezve!
echo.
echo Javitas:
echo - Minden benchmark fuggveny PSCustomObject-ge konvertalja a hashtable-et
echo - A return elott , operatot hasznalunk a PowerShell 5.1 "unwrapping" megakadalyozasara
echo - A JSON valasz most mar objektum lesz, nem tomb
echo.
echo Most allitsd le a probe-ot (Ctrl+C), majd inditsd ujra:
echo   start-probe.bat
echo.
echo A probe konzolban a kovetkezot kellene latnod:
echo   [RESPONSE] JSON: {"writeMbps":1007.2,"readMbps":1102.5}
echo.
echo FONTOS: A JSON valasz most mar objektum, nem tomb!
echo.
pause
