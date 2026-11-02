@echo off
title TestDeck Probe
echo Starting TestDeck Probe...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0probe.ps1" %*
pause
