<#
.SYNOPSIS
停止本项目的服务进程树，释放模型占用的显存。
#>
[CmdletBinding()]
param()
. "$PSScriptRoot\common.ps1"
$state = Get-ServerState
if (-not $state) { Write-Host '服务已停止，当前没有保存的模型进程。'; return }
$process = Get-VerifiedServerProcess $state
if ($process) {
    $stopOutput = & taskkill.exe /PID $process.Id /T /F 2>&1
    if ($LASTEXITCODE -ne 0) { throw '停止服务进程树失败。' }
    if (-not $process.WaitForExit(10000)) { throw '等待服务退出超时。' }
    Write-Host '服务已停止，模型占用的显存已释放。'
} else { Write-Host '服务此前已经退出。' }
Remove-Item -LiteralPath (Resolve-ProjectPath 'logs\server-state.json')
