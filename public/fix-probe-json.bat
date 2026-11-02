@echo off
echo ========================================
echo TestDeck - Probe JSON Fix
echo ========================================
echo.
echo Javitas:
echo - Enum ertekek explicit stringge konvertalasa
echo - Szamok invariant culture-rel (pont, nem vesszo)
echo - Letters tomb szurese (csak ervenyes betuk)
echo - Reliability counter ertekek explicit tipuskonverzio
echo - CIM fallback ertekek explicit stringge konvertalasa
echo.
echo Most allitsd le a probe-ot (Ctrl+C), majd inditsd ujra:
echo   start-probe.bat
echo.
echo Utana nyisd meg a bongeszot: http://localhost:8080
echo.
echo FONTOS: Nyomj Ctrl+Shift+R-t a gyorsitotar torleshez!
echo.
echo A probe konzolban a kovetkezot kellene latnod:
echo   [RESPONSE] JSON: [{"serial":"...","firmware":"...","healthStatus":"Healthy",...}]
echo.
echo FONTOS: A healthStatus es operationalStatus most mar string ertek,
echo         nem objektum! A capacityGB pontot hasznal, nem vesszot!
echo.
pause
