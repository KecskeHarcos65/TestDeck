@echo off
echo ========================================
echo TestDeck - Probe Array Unwrapping Javitas
echo ========================================
echo.
echo Fajlok masolasa dist mappabol public mappaba...
xcopy /E /I /Y "dist\*" "public\"
echo.
echo Masolas befejezve!
echo.
echo Javitasok:
echo 1. probe.ps1 - Handle-ProbeRequest: array unwrapping detektalas es javitas
echo    - SEQ, RND, QD, MIX, SUSTAINED, VERIFY, CLEANUP benchmarkok
echo    - Ha a PowerShell 5.1 tombbe csomagolja az objektumot, kiveszi a masodik elemet
echo.
echo Most allitsd le a probe-ot (Ctrl+C), majd inditsd ujra:
echo   start-probe.bat
echo.
echo A probe konzolban a kovetkezot kellene latnod:
echo   [BENCH-SEQ] Detected array unwrapping, extracting object
echo   [RESPONSE] JSON: {"writeMbps":900,"readMbps":1052.1}
echo.
echo FONTOS: A JSON valasz most mar objektum, nem tomb!
echo.
echo Utana nyisd meg a bongeszot: http://localhost:8080
echo.
echo FONTOS: Nyomj Ctrl+Shift+R-t a gyorsitotar torleshez!
echo.
echo Teszteld a New Test - SEQ benchmarkot!
echo.
pause
