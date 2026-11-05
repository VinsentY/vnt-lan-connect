@echo off
chcp 65001 >nul
title VNT 峡谷模拟联机群 - 一键启动器

set "PS1_PATH="
if exist "%~dp0scripts\vnt_room.ps1" (
    set "PS1_PATH=%~dp0scripts\vnt_room.ps1"
) else if exist "%~dp0vnt_room.ps1" (
    set "PS1_PATH=%~dp0vnt_room.ps1"
) else if exist "%USERPROFILE%\.gemini\config\skills\vnt-lan-connect\scripts\vnt_room.ps1" (
    set "PS1_PATH=%USERPROFILE%\.gemini\config\skills\vnt-lan-connect\scripts\vnt_room.ps1"
) else if exist "%USERPROFILE%\.gemini\antigravity\scratch\vnt-lan-connect\scripts\vnt_room.ps1" (
    set "PS1_PATH=%USERPROFILE%\.gemini\antigravity\scratch\vnt-lan-connect\scripts\vnt_room.ps1"
)

if "%PS1_PATH%"=="" (
    echo [错误] 未找到 vnt_room.ps1 脚本文件！
    pause
    exit /b 1
)

echo ==================================================================
echo 🚀 正在启动 VNT 虚拟局域网联机 (脚本路径: %PS1_PATH%)
echo ==================================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%" join %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo ❌ 启动过程中出现异常 (退出码: %EXIT_CODE%)，请查看上方日志。
    pause
    exit /b %EXIT_CODE%
)

echo.
echo ✅ 联机与「VNT 实时联机状态监控台」已启动！本引导窗口将在 3 秒后自动关闭...
timeout /t 3 >nul
exit /b 0