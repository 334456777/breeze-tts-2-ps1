<#
.SYNOPSIS
调用本地 Q8_0 服务合成语音，支持声音描述、参考模仿、流式接收及实时播放。
.PARAMETER Text
文本：要朗读的内容，与文本文件二选一。
.PARAMETER TextFile
文本文件：UTF-8 编码的输入文件。
.PARAMETER Output
输出：项目内的 WAV 路径，默认 outputs/speech.wav。
.PARAMETER Instructions
声音描述：说话人的音色、背景、语气和表达风格。
.PARAMETER VoiceRef
参考音频：用于音色模仿的 WAV 文件。
.PARAMETER ReferenceText
参考文本：参考音频中实际说出的文字。
.PARAMETER Stream
流式：要求服务已使用流式模式启动；通常可自动识别。
.PARAMETER Play
实时播放：边接收流式音频边播放，同时照常保存 WAV；要求服务以流式模式启动。
.PARAMETER Seed
随机种子，默认 42。
.PARAMETER MaxTokens
最大声学帧数，默认 1500。
.PARAMETER Port
端口，默认从服务状态或配置读取。
#>
[CmdletBinding(DefaultParameterSetName='Text')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='Text')][string]$Text,
    [Parameter(Mandatory=$true, ParameterSetName='File')][string]$TextFile,
    [string]$Output = 'outputs\speech.wav',
    [string]$Instructions = '请清晰自然地说话。',
    [ValidateRange(0, 2147483647)][int]$Seed = 42,
    [ValidateRange(1, 10000)][int]$MaxTokens = 1500,
    [ValidateRange(1024, 65535)][int]$Port,
    [switch]$Stream,
    [switch]$Play,
    [string]$VoiceRef,
    [string]$ReferenceText
)
. "$PSScriptRoot\common.ps1"
Initialize-ProjectEnvironment
$runner = Read-ProjectJson 'config\runner.json'
$state = Get-ServerState
if (-not $Port) { $Port = if ($state) { $state.port } else { $runner.port } }
$baseUrl = Get-ServerBaseUrl $state $Port
$streaming = [bool]$Stream
if ($state -and $state.port -eq $Port) {
    if ($Stream -and $state.mode -ne 'streaming') {
        throw '请先停止服务，再使用 .\start-server.ps1 -Mode streaming 启动服务。'
    }
    $streaming = $state.mode -eq 'streaming'
}
if ($Play -and -not $streaming) {
    throw '实时播放需要流式模式：请先停止服务，再使用 .\start-server.ps1 -Mode streaming 启动服务。'
}
if ($TextFile) { $Text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $TextFile).Path, [Text.Encoding]::UTF8) }
if ([string]::IsNullOrWhiteSpace($Text)) { throw '输入文本不能为空。' }
if ([bool]$VoiceRef -ne [bool]$ReferenceText) { throw '必须同时提供 -VoiceRef 和 -ReferenceText。' }
$outputPath = Resolve-ProjectPath $Output
if ([IO.Path]::GetExtension($outputPath) -ne '.wav') { throw '输出文件必须使用 .wav 扩展名。' }
$payload = @{
    model=$runner.model_id; input=$Text; response_format='wav'
    options=@{instruct=$Instructions; seed=$Seed.ToString(); max_tokens=$MaxTokens.ToString()}
}
if ($VoiceRef) {
    $payload.voice_ref = (Resolve-Path -LiteralPath $VoiceRef).Path
    $payload.reference_text = $ReferenceText
}
if ($streaming) {
    $payload.response_format = 'pcm'
    $payload.stream = $true
    $payload.stream_format = 'audio'
}
New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
$partial = $outputPath + '.partial'
$response = $null; $inputStream = $null; $outputStream = $null; $player = $null
$timer = [Diagnostics.Stopwatch]::StartNew()
$firstAudio = $null
try {
    $request = [Net.HttpWebRequest]::Create("$baseUrl/v1/audio/speech")
    $request.Proxy = $null
    $request.Method = 'POST'
    $request.ContentType = 'application/json; charset=utf-8'
    $request.Timeout = 600000; $request.ReadWriteTimeout = 600000
    $body = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8))
    $request.ContentLength = $body.Length
    $bodyStream = $request.GetRequestStream()
    try { $bodyStream.Write($body, 0, $body.Length) } finally { $bodyStream.Dispose() }
    $response = $request.GetResponse()
    if ($response.ContentType -match 'json|text/event-stream') { throw '服务返回了结构化数据，没有返回音频。' }
    $inputStream = $response.GetResponseStream()
    $outputStream = [IO.File]::Open($partial, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if ($streaming) { Write-WaveHeader $outputStream 0 }
    if ($Play) { $player = New-PcmPlayer }
    $buffer = New-Object byte[] 4096
    $dataBytes = [long]0
    while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        if ($null -eq $firstAudio) { $firstAudio = $timer.Elapsed.TotalSeconds }
        $outputStream.Write($buffer, 0, $count)
        if ($player) { $player.Write($buffer, 0, $count) }
        $dataBytes += $count
    }
    $timer.Stop()
    if ($streaming) {
        if ($dataBytes % 2) { throw '16 位 PCM 音频流的字节数不正确。' }
        Write-WaveHeader $outputStream $dataBytes
    }
    # 生成结束后等剩余音频播完，请求秒数不含这段等待。
    if ($player) { $player.Drain() }
    $outputStream.Dispose(); $outputStream = $null
    $info = Get-WaveInfo $partial
    Move-Item -LiteralPath $partial -Destination $outputPath -Force
    $info.output = $outputPath
    $info.mode = if ($streaming) { 'streaming' } else { 'offline' }
    $info.request_seconds = $timer.Elapsed.TotalSeconds
    $info.first_audio_seconds = if ($streaming) { $firstAudio } else { $null }
    $report = @{} + $info
    $report.request = $payload
    $report.created_at = [DateTime]::UtcNow.ToString('o')
    Write-ProjectJson ([IO.Path]::ChangeExtension($Output, '.json')) $report
    [pscustomobject]@{
        '输出文件'=$info.output; '模式'=$(if ($streaming) { '流式' } else { '离线' })
        '采样率'=$info.sample_rate; '声道数'=$info.channels; '采样位数'=$info.bits_per_sample
        '音频秒数'=$info.duration_seconds; '请求秒数'=$info.request_seconds; '首段音频秒数'=$info.first_audio_seconds
    }
} catch {
    if ($_.Exception -is [Net.WebException] -and $_.Exception.Response) {
        $errorReader = [IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
        try { $detail = $errorReader.ReadToEnd() } finally { $errorReader.Dispose() }
        throw "语音合成请求失败：$detail"
    }
    if ($_.Exception -is [Net.WebException]) { throw '无法访问本地语音服务，请先运行 .\start-server.ps1，并检查端口。' }
    throw
} finally {
    if ($player) { $player.Dispose() }
    if ($inputStream) { $inputStream.Dispose() }
    if ($outputStream) { $outputStream.Dispose() }
    if ($response) { $response.Dispose() }
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
}
