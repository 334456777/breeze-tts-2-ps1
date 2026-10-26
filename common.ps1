<#
.SYNOPSIS
共享的路径检查、项目环境、进程识别、文件校验和音频处理函数。
#>
$ErrorActionPreference = 'Stop'
$script:BreezeRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if ((Get-Item -LiteralPath $script:BreezeRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw '项目根目录不能是目录联接或符号链接。'
}

function Resolve-ProjectPath([string]$Path) {
    $resolved = [IO.Path]::GetFullPath((Join-Path $script:BreezeRoot $Path))
    if (-not $resolved.StartsWith($script:BreezeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "路径必须位于当前项目内：$Path"
    }
    # 拒绝通过目录联接或符号链接访问项目外部。
    $cursor = $resolved
    while ($cursor -ne $script:BreezeRoot) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "项目路径包含目录联接或符号链接：$cursor"
            }
        }
        $cursor = Split-Path -Parent $cursor
    }
    return $resolved
}

function Initialize-ProjectEnvironment {
    $env:CUDA_CACHE_PATH = Resolve-ProjectPath '.cache\cuda'
    $env:XDG_CACHE_HOME = Resolve-ProjectPath '.cache'
    $env:TEMP = Resolve-ProjectPath '.tmp'
    $env:TMP = $env:TEMP
    foreach ($relative in @('.cache\cuda', '.tmp', 'logs', 'outputs')) {
        New-Item -ItemType Directory -Force -Path (Resolve-ProjectPath $relative) | Out-Null
    }
}

function Remove-ProjectDirectory([string]$Path) {
    $target = Resolve-ProjectPath $Path
    if (-not (Test-Path -LiteralPath $target)) { return }
    $links = @(Get-ChildItem -LiteralPath $target -Force -Recurse -Attributes ReparsePoint)
    if ($links.Count) { throw "拒绝删除包含目录联接或符号链接的目录：$($links[0].FullName)" }
    Remove-Item -LiteralPath $target -Recurse
}

function Read-ProjectJson([string]$Path) {
    $data = Get-Content -LiteralPath (Resolve-ProjectPath $Path) -Raw -Encoding UTF8 | ConvertFrom-Json
    return $data
}

function Write-ProjectJson([string]$Path, $Data) {
    $target = Resolve-ProjectPath $Path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    $json = ($Data | ConvertTo-Json -Depth 16) + [Environment]::NewLine
    [IO.File]::WriteAllText($target, $json, [Text.UTF8Encoding]::new($false))
}

function Get-ServerState {
    $statePath = Resolve-ProjectPath 'logs\server-state.json'
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    return Read-ProjectJson 'logs\server-state.json'
}

function Get-ServerBaseUrl($State, [int]$Port) {
    $address = '127.0.0.1'
    if ($State -and $State.port -eq $Port -and $State.client_address) { $address = $State.client_address }
    if ($address.Contains(':')) { $address = '[' + $address + ']' }
    return "http://${address}:$Port"
}

function Read-ServerJson([string]$Uri, [int]$TimeoutMilliseconds = 2000) {
    # 直接访问本机监听地址，不经过系统 HTTP 代理。
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Proxy = $null
    $request.Timeout = $TimeoutMilliseconds
    $request.ReadWriteTimeout = $TimeoutMilliseconds
    $response = $request.GetResponse()
    try {
        $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $data = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        return $data
    } finally { $response.Dispose() }
}

function Get-VerifiedServerProcess($State) {
    $process = Get-Process -Id $State.pid -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    $runner = Read-ProjectJson 'config\runner.json'
    if ($process.Path -ne (Resolve-ProjectPath $runner.exe) -or
        $process.StartTime.ToUniversalTime().Ticks.ToString() -ne [string]$State.started_ticks) {
        throw '保存的进程编号已属于其他进程，拒绝操作。请检查日志中的进程状态文件。'
    }
    return $process
}

function Test-Asset($Asset, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne [long]$Asset.size) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Asset.sha256
}

function Write-WaveHeader([IO.Stream]$Stream, [long]$DataBytes) {
    if ($DataBytes -gt [uint32]::MaxValue - 36) { throw '音频超过普通 WAV 格式的大小上限。' }
    $Stream.Position = 0
    $writer = [IO.BinaryWriter]::new($Stream, [Text.Encoding]::ASCII, $true)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([uint32](36 + $DataBytes))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $writer.Write([uint32]16)
        $writer.Write([uint16]1)
        $writer.Write([uint16]1)
        $writer.Write([uint32]24000)
        $writer.Write([uint32]48000)
        $writer.Write([uint16]2)
        $writer.Write([uint16]16)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([uint32]$DataBytes)
        $writer.Flush()
    } finally { $writer.Dispose() }
}

function Get-WaveInfo([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'RIFF') { throw '返回数据不是 WAV 音频。' }
        $null = $reader.ReadUInt32()
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'WAVE') { throw '返回数据不是 WAV 音频。' }
        $rate = 0; $channels = 0; $bits = 0; $dataBytes = 0
        while ($reader.BaseStream.Position + 8 -le $reader.BaseStream.Length) {
            $kind = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
            $size = [long]$reader.ReadUInt32()
            $next = $reader.BaseStream.Position + $size + ($size % 2)
            if ($reader.BaseStream.Position + $size -gt $reader.BaseStream.Length) { throw '返回的 WAV 音频不完整。' }
            if ($kind -eq 'fmt ') {
                if ($size -lt 16) { throw 'WAV 格式信息损坏。' }
                if ($reader.ReadUInt16() -ne 1) { throw '音频必须为 PCM WAV 格式。' }
                $channels = $reader.ReadUInt16(); $rate = $reader.ReadUInt32()
                $null = $reader.ReadUInt32(); $null = $reader.ReadUInt16(); $bits = $reader.ReadUInt16()
            } elseif ($kind -eq 'data') { $dataBytes += $size }
            $reader.BaseStream.Position = $next
        }
        if ($rate -ne 24000 -or $channels -ne 1 -or $bits -ne 16 -or $dataBytes -le 0) {
            throw '音频必须为非空的 24 kHz、单声道、16 位 PCM 格式。'
        }
        return @{sample_rate=$rate; channels=$channels; bits_per_sample=$bits; duration_seconds=$dataBytes / 48000.0}
    } finally { $reader.Dispose() }
}
