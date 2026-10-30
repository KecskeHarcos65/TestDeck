@echo off
echo ========================================
echo TestDeck - Probe Benchmark Fix
echo ========================================
echo.
echo Fajlok masolasa dist mappabol public mappaba...
xcopy /E /I /Y "dist\*" "public\"
echo.
echo Masolas befejezve!
echo.
echo Javitas:
echo - Teljes probe.ps1 ujra letrehozva valodi benchmark kodokkal
echo - SEQ, RND, QD, MIX, SUSTAINED, VERIFY benchmarkok
echo - ConvertTo-SafeJson fuggveny a hashtable-ek megfelelo JSON konvertalasahoz
echo.
echo Most allitsd le a probe-ot (Ctrl+C), majd inditsd ujra:
echo   start-probe.bat
echo.
echo Utana nyisd meg a bongeszot: http://localhost:8080
echo.
echo FONTOS: Nyomj Ctrl+Shift+R-t a gyorsitotar torleshez!
echo.
echo Most mar meg kell jelennie a sebesseg ertekeknek!
echo.
pause
