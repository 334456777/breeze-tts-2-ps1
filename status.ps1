<#
.SYNOPSIS
查看本地服务、模型加载状态和整卡显存占用。
#>
[CmdletBinding()]
param()
. "$PSScriptRoot\common.ps1"
$state = Get-ServerState
if (-not $state) { Write-Host '服务已停止，当前没有保存的模型进程。'; return }
$process = Get-VerifiedServerProcess $state
if (-not $process) { Write-Host '服务已经退出，保存的状态记录已过期。'; return }
$baseUrl = Get-ServerBaseUrl $state $state.port
$health = Read-ServerJson "$baseUrl/health" 3000
$models = Read-ServerJson "$baseUrl/v1/models" 3000
[pscustomobject]@{
    '服务地址'=$baseUrl; '监听地址'=$state.listen_address; '端口'=$state.port; '进程编号'=$state.pid
    '运行模式'=$(if ($state.mode -eq 'streaming') { '流式' } else { '离线' })
    '计算后端'=$health.backend; '模型文件'=$state.model; '模型详情'=$models.data
} | ConvertTo-Json -Depth 8
if (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue) {
    $gpu = & nvidia-smi.exe --query-gpu=name,memory.used,memory.total --format=csv,noheader
    Write-Host "显卡、已用显存、总显存：$gpu"
}
