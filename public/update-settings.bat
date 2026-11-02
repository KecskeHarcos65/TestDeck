@echo off
echo ========================================
echo TestDeck - Settings and Bug Fixes
echo ========================================
echo.
echo Copying files from dist to public...
xcopy /E /I /Y "dist\*" "public\"
echo.
echo Copy complete!
echo.
echo Changes:
echo 1. Added Settings tab for admins to configure test file size
echo 2. Added logging to New Profile button for debugging
echo 3. Fixed drive deletion crash (delayed refresh)
echo.
echo Next steps:
echo 1. Stop the server (Ctrl+C)
echo 2. Restart: start-server.bat
echo 3. Open browser: http://localhost:8080
echo 4. Press Ctrl+Shift+R to clear cache
echo.
echo New features:
echo - Settings tab (admin only): Configure test file size (16-1024 MB)
echo - New Profile button now has console logging for debugging
echo - Drive deletion no longer crashes the app
echo.
pause
