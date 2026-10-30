@echo off
echo ========================================
echo TestDeck - JSON Escape Fix
echo ========================================
echo.
echo A hiba oka: A JSON válaszban volt egy érvénytelen vezérlő karakter
echo (valószínűleg a drive serial number-ben vagy más mezőben).
echo.
echo A javított probe.ps1 fájl most már megfelelően escape-eli
echo a speciális karaktereket a string értékekben.
echo.
echo Másold át a javított probe.ps1 fájlt a probe mappádba:
echo.
echo   copy "public\probe.ps1" "D:\Letöltések\SSDSZERVER\public\probe.ps1"
echo.
echo Vagy manuálisan:
echo   1. Nyisd meg a public\probe.ps1 fájlt
echo   2. Másold ki a teljes tartalmát
echo   3. Illeszd be a D:\Letöltések\SSDSZERVER\public\probe.ps1 fájlba
echo   4. Mentsd el
echo.
echo Ezután állítsd le a probe-ot (Ctrl+C) és indítsd újra:
echo   start-probe.bat
echo.
echo A legfontosabb változások:
echo - Escape-JsonString függvény: escape-eli a speciális karaktereket
echo - ConvertTo-SafeJson függvény: használja az Escape-JsonString-et
echo - Kezeli a vezérlő karaktereket (\n, \r, \t, stb.)
echo - Eltávolítja az érvénytelen vezérlő karaktereket (ASCII 0-31)
echo.
echo Most már nem lesz "Bad control character in string literal" hiba.
echo.
pause
