@echo off
rem Lanzador del Gestor de Salud USB (solicita permisos de administrador automaticamente)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0GestorSaludUSB.ps1"
