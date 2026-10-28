@echo off
rem 全局 tts 命令：把 bin 目录加入 PATH 后可在任意终端使用，参数见 tts --help
setlocal
where pwsh >nul 2>nul && (set "PS=pwsh") || (set "PS=powershell")
%PS% -NoProfile -File "%~dp0..\tts.ps1" %*
exit /b %errorlevel%
