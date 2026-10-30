@echo off
echo ========================================
echo TestDeck - React Crash Fix
echo ========================================
echo.
echo Javitas:
echo - Minden mezot String()-ve alakitunk a React oldalon
echo - Ez megakadalyozza, hogy objektumok jelenjenek meg szovegkent
echo - A healthStatus es operationalStatus most mar mindig string lesz
echo.
echo Fajlok masolasa dist mappabol public mappaba...
xcopy /E /I /Y "dist\*" "public\"
echo.
echo Masolas befejezve!
echo.
echo Most allitsd le a szervert (Ctrl+C), majd inditsd ujra:
echo   start-server.bat
echo.
echo Utana nyisd meg a bongeszot: http://localhost:8080
echo.
echo FONTOS: Nyomj Ctrl+Shift+R-t a gyorsitotar torleshez!
echo.
echo Most mar nem fog crashelni a React, ha objektumot kap a szervertol.
echo.
pause
