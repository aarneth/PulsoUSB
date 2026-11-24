@echo off
rem Ejecuta PulsoUSB desde el script (pide permisos de administrador automaticamente)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0PulsoUSB.ps1"
