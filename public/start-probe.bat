@echo off
title TestDeck Probe
echo Starting TestDeck Probe Agent...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0probe.ps1" %*
pause
