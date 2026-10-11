@echo off
rem manual double-click path. autounattend calls FirstBoot.ps1 directly now.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FirstBoot.ps1" -Now
