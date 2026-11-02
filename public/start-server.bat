@echo off
title TestDeck Server
echo Starting TestDeck Server...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" %*
pause
