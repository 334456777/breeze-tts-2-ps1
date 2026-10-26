<#
.SYNOPSIS
停止服务并清理本项目文件，支持预览和按类别卸载。
.PARAMETER All
全部：删除运行器、模型、安装包、音频、日志和缓存，仅保留源码。
.PARAMETER Preview
预览：只显示清理目标，不停止服务，不删除文件。
.PARAMETER RemoveDownloads
删除安装包：清理 downloads 文件夹。
.PARAMETER RemoveRuntime
删除运行器：清理 runtime 文件夹。
.PARAMETER RemoveModels
删除模型：清理 models 文件夹。
.PARAMETER RemoveOutputs
删除音频：清理 outputs 中的音频和请求记录。
.PARAMETER RemoveLogs
删除日志：清理 logs 文件夹。
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [switch]$RemoveDownloads,
    [switch]$RemoveRuntime,
    [switch]$RemoveModels,
    [switch]$RemoveOutputs,
    [switch]$RemoveLogs,
    [switch]$All,
    [switch]$Preview
)
. "$PSScriptRoot\common.ps1"
if ($Preview) {
    Write-Host '预览：将停止 audio.cpp CUDA Q8_0 服务并释放模型显存。'
} elseif ($PSCmdlet.ShouldProcess('audio.cpp CUDA Q8_0 服务', '停止服务并释放模型显存')) {
    & "$PSScriptRoot\stop-server.ps1"
}
$targets = @('.cache', '.tmp')
if ($RemoveDownloads -or $All) { $targets += 'downloads' }
if ($RemoveRuntime -or $All) { $targets += 'runtime' }
if ($RemoveModels -or $All) { $targets += 'models' }
if ($RemoveOutputs -or $All) { $targets += 'outputs' }
if ($RemoveLogs -or $All) { $targets += 'logs' }
foreach ($relative in $targets) {
    $path = Resolve-ProjectPath $relative
    if (Test-Path -LiteralPath $path) {
        if ($Preview) { Write-Host "预览：将删除项目目录 $path" }
        elseif ($PSCmdlet.ShouldProcess($path, '删除项目目录')) { Remove-ProjectDirectory $relative }
    }
}
if ($Preview -or $WhatIfPreference) { Write-Host '预览完成，未停止服务或删除文件。' }
else { Write-Host '清理完成，源码、配置、使用说明和许可证已保留。' }
