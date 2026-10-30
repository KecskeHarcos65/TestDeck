@echo off
echo ========================================
echo TestDeck - App.tsx Visszaallitas
echo ========================================
echo.
echo Az App.tsx fajl visszaallitva az osszes funkcióval:
echo - Login/Register
echo - Dashboard statisztikakkal
echo - New Test wizard (4 lepes)
echo - Drives nezet szuressel
echo - Drive drawer reszletekkel
echo - Admin panel (profiles, labels, models, users)
echo - Help nezet
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
pause
