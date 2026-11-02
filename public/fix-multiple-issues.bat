@echo off
echo ========================================
echo TestDeck - Tobb hiba javitasa
echo ========================================
echo.
echo Fajlok masolasa dist mappabol public mappaba...
xcopy /E /I /Y "dist\*" "public\"
echo.
echo Masolas befejezve!
echo.
echo Javitasok:
echo 1. DriveDrawer - lifecycle status explicit stringge konvertalasa
echo 2. DrivesView - getLifecycleStatus explicit stringge konvertalasa
echo 3. AdminProfiles - New Profile es Cancel gombok javitva
echo 4. Logout button - toggle mukodes (nem hover)
echo.
echo Most allitsd le a szervert (Ctrl+C), majd inditsd ujra:
echo   start-server.bat
echo.
echo Utana nyisd meg a bongeszot: http://localhost:8080
echo.
echo FONTOS: Nyomj Ctrl+Shift+R-t a gyorsitotar torleshez!
echo.
echo Teszteld a kovetkezoket:
echo 1. My Drives - nyiss meg egy drive-ot, valtoztasd meg a status-t, nyiss meg masik drive-ot
echo 2. Admin - Profiles - kattints a "+ New Profile" gombra
echo 3. Admin - Profiles - szerkessz egy profile-t, kattints a "Cancel" gombra
echo 4. Logout - kattints a felhasznalonevre, majd a "Logout" gombra
echo.
pause
