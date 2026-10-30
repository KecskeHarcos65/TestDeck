@echo off
echo ========================================
echo TestDeck - Probe Array es React Error javitas
echo ========================================
echo.
echo Fajlok masolasa dist mappabol public mappaba...
xcopy /E /I /Y "dist\*" "public\"
echo.
echo Masolas befejezve!
echo.
echo Javitasok:
echo 1. App.tsx - probe() fuggveny: ha tombot kap [true, {...}], kiveszi a masodik elemet
echo 2. App.tsx - drive.notes explicit stringge konvertalasa
echo.
echo Most allitsd le a szervert (Ctrl+C), majd inditsd ujra:
echo   start-server.bat
echo.
echo Utana nyisd meg a bongeszot: http://localhost:8080
echo.
echo FONTOS: Nyomj Ctrl+Shift+R-t a gyorsitotar torleshez!
echo.
echo Teszteld a kovetkezoket:
echo 1. New Test - futtass le egy SEQ tesztet, ellenorizd, hogy megjelennek-e a sebesseg ertekek
echo 2. My Drives - nyiss meg egy drive-ot, valtoztasd meg a status-t, nyiss meg masik drive-ot
echo.
pause
