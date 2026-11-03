@echo off
title TestDeck Backup
echo Creating backup...
set TIMESTAMP=%DATE:~-4%%DATE:~3,2%%DATE:~0,2%_%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%
set TIMESTAMP=%TIMESTAMP: =0%
if not exist "backups" mkdir backups
xcopy /E /I /Y "data" "backups\data-%TIMESTAMP%"
echo Backup created: backups\data-%TIMESTAMP%
pause
