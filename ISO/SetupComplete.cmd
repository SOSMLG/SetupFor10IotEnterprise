@echo off
rem blank start tiles for fresh profiles. runs as SYSTEM before first logon.
rem no reboot in here, setup forbids it. apps and tweaks come later via FirstBoot.
if exist C:\Setup\ISO\StartLayout.xml powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-StartLayout -LayoutPath 'C:\Setup\ISO\StartLayout.xml' -MountPath 'C:\'"
