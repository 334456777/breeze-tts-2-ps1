<#
.SYNOPSIS
在后台启动 audio.cpp，将 Q8_0 模型加载到 NVIDIA 显卡。
.PARAMETER Port
监听端口，默认 8088。
.PARAMETER ListenAddress
监听 IP 地址，默认 127.0.0.1；0.0.0.0 表示所有 IPv4 网卡。
.PARAMETER Mode
模式：offline（离线）或 streaming（流式）。改变模式前需要先停止服务。
.PARAMETER Device
显卡编号，默认 0。
.PARAMETER Threads
CPU 线程数，默认 4。
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port,
    [string]$ListenAddress,
    [ValidateSet('offline', 'streaming')][string]$Mode = 'offline',
    [ValidateRange(0, 16)][int]$Device = 0,
    [ValidateRange(1, 64)][int]$Threads = 4
)
. "$PSScriptRoot\common.ps1"
Initialize-ProjectEnvironment
$runner = Read-ProjectJson 'config\runner.json'
if (-not $PSBoundParameters.ContainsKey('Device')) { $Device = $runner.device }
if (-not $PSBoundParameters.ContainsKey('Threads')) { $Threads = $runner.threads }
if (-not $Port) { $Port = $runner.port }
if (-not $ListenAddress) { $ListenAddress = $runner.listen_address }
$parsedAddress = $null
if (-not [Net.IPAddress]::TryParse($ListenAddress, [ref]$parsedAddress)) {
    throw 'ListenAddress 必须是有效的 IP 地址，例如 127.0.0.1 或 0.0.0.0。'
}
$ListenAddress = $parsedAddress.ToString()
$clientAddress = switch ($ListenAddress) {
    '0.0.0.0' { '127.0.0.1' }
    '::' { '::1' }
    default { $ListenAddress }
}
$state = Get-ServerState
if ($state) {
    $running = Get-VerifiedServerProcess $state
    if ($running) {
        foreach ($parameter in @('Port', 'Mode', 'Device', 'Threads')) {
            if ($PSBoundParameters.ContainsKey($parameter) -and (Get-Variable -Name $parameter -ValueOnly) -ne $state.$parameter) {
                throw '修改端口、模式、显卡或线程数之前，请先停止当前服务。'
            }
        }
        if ($PSBoundParameters.ContainsKey('ListenAddress') -and $ListenAddress -ne $state.listen_address) {
            throw '修改监听地址之前，请先停止当前服务。'
        }
        $modeText = if ($state.mode -eq 'streaming') { '流式' } else { '离线' }
        $baseUrl = Get-ServerBaseUrl $state $state.port
        Write-Host "服务已在运行：$baseUrl，监听地址=$($state.listen_address)，模式=$modeText，进程编号=$($state.pid)"
        return
    }
    Remove-Item -LiteralPath (Resolve-ProjectPath 'logs\server-state.json')
}
$exe = Resolve-ProjectPath $runner.exe
$model = Resolve-ProjectPath $runner.model
$cudaDir = Resolve-ProjectPath $runner.cuda_dir
foreach ($path in @($exe, $model, (Join-Path $cudaDir 'cudart64_12.dll'), (Join-Path $cudaDir 'cublas64_12.dll'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "缺少文件：$path。请先运行 .\setup.ps1。" }
}
$probe = [Net.Sockets.TcpClient]::new()
try {
    try { $null = $probe.ConnectAsync($clientAddress, $Port).Wait(1000) } catch { }
    if ($probe.Connected) { throw "端口 $Port 已被占用，请指定其他端口。" }
} finally { $probe.Dispose() }
$config = @{
    host=$ListenAddress; port=$Port; backend='cuda'; device=$Device; threads=$Threads
    lazy_load=$false; max_loaded_models=1; ui=$false; ui_management=$false
    models=@(@{
        id=$runner.model_id; family='breeze_tts'; path=$model; task='tts'; mode=$Mode
        default_request_options=@{instruct='请清晰自然地说话。'; seed=42}
    })
}
Write-ProjectJson 'logs\server-config.json' $config
$configPath = Resolve-ProjectPath 'logs\server-config.json'
$oldPath = $env:PATH
try {
    $env:PATH = $cudaDir + [IO.Path]::PathSeparator + $oldPath
    $process = Start-Process -FilePath $exe -ArgumentList @('--config', ('"' + $configPath + '"'), '--log') `
        -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Resolve-ProjectPath 'logs\server.stdout.log') `
        -RedirectStandardError (Resolve-ProjectPath 'logs\server.stderr.log')
} finally { $env:PATH = $oldPath }
$savedState = @{
    pid=$process.Id; started_ticks=$process.StartTime.ToUniversalTime().Ticks.ToString(); exe=$exe
    port=$Port; mode=$Mode; model_id=$runner.model_id; model=$model; device=$Device; threads=$Threads
    listen_address=$ListenAddress; client_address=$clientAddress
}
Write-ProjectJson 'logs\server-state.json' $savedState
$baseUrl = Get-ServerBaseUrl $savedState $Port
$timer = [Diagnostics.Stopwatch]::StartNew()
$nextNotice = 15
try {
    while ($timer.Elapsed.TotalSeconds -lt 180) {
        $process.Refresh()
        if ($process.HasExited) { throw '服务进程已退出，请检查 logs\server.stderr.log 和 logs\server.stdout.log。' }
        try {
            $health = Read-ServerJson "$baseUrl/health"
            $models = Read-ServerJson "$baseUrl/v1/models"
            $loaded = @($models.data | Where-Object { $_.id -eq $runner.model_id -and $_.loaded })
            if ($health.backend -eq 'cuda' -and $loaded.Count -eq 1) {
                $modeText = if ($Mode -eq 'streaming') { '流式' } else { '离线' }
                Write-Host "audio.cpp CUDA Q8_0 已加载显存：$baseUrl，监听地址=$ListenAddress，模式=$modeText，进程编号=$($process.Id)"
                return
            }
        } catch { }
        if ($timer.Elapsed.TotalSeconds -ge $nextNotice) {
            Write-Host ('正在将 Q8_0 加载到 CUDA 显卡……已等待 {0:N0} 秒' -f $timer.Elapsed.TotalSeconds)
            $nextNotice += 15
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'CUDA 模型加载超时，已等待 180 秒。'
} catch {
    & "$PSScriptRoot\stop-server.ps1"
    throw
}
