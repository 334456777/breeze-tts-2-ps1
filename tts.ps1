<#
.SYNOPSIS
全局命令 tts 的实现，参数风格参考 whisperx：tts <文本或文件>... [--选项]。
用法见 tts --help。
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Show-Usage {
    @'
用法: tts <文本或.txt文件>... [选项]
      echo 你好 | tts [选项]

选项:
  -o, --output_dir DIR        输出目录，默认当前目录
  -n, --output_name NAME      输出文件名（不含扩展名）；仅一个输入时有效
  -i, --instruct TEXT         声音描述（音色、语气、风格）
  -v, --voice_ref WAV         参考音频，用于音色模仿
  -t, --reference_text TEXT   参考音频中实际说出的文字（与 --voice_ref 同时使用）
  -e, --seed N                随机种子，默认 42
  -m, --max_tokens N          最大声学帧数，默认 1500
  -P, --port N                服务端口，默认读取服务状态
  -p, --play                  生成后直接播放
  -s, --speak                 只朗读，不保留任何文件（自动播放）
  -N, --no_start              服务未运行时不自动启动
  -x, --stop                  停止服务、卸载模型释放显存；单独使用只卸载，
                              与文字一起使用则合成结束后再卸载
  -h, --help                  显示本帮助

示例:
  tts "你好，欢迎使用本地语音合成。" -p
  tts "只朗读不留文件" -s
  tts article.txt -o D:\audio
  tts "下午好" -i "一位说普通话、语气温暖的成年女性。"
  tts -x                  卸载模型，释放显存
'@ | Write-Host
}

# 解析 --key value 形式的参数
$inputs = [Collections.Generic.List[string]]::new()
$opt = @{ output_dir='.'; seed=42; max_tokens=1500 }
$flags = @{}
$valueOptions = 'output_dir','output_name','instruct','voice_ref','reference_text','seed','max_tokens','port'
$flagOptions = 'play','speak','no_start','stop','help'
# 短参数（区分大小写）
$shortOptions = [Collections.Generic.Dictionary[string,string]]::new()
foreach ($pair in 'o=output_dir','n=output_name','i=instruct','v=voice_ref','t=reference_text','e=seed','m=max_tokens',
                  'P=port','p=play','s=speak','N=no_start','x=stop','h=help') {
    $key, $long = $pair -split '=', 2
    $shortOptions[$key] = $long
}
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -eq '/?') { $flags.help = $true; continue }
    $name = $null; $inline = $null
    if ($a -cmatch '^--([A-Za-z_]+)(?:=(.*))?$') { $name = $Matches[1] -replace '-', '_'; $inline = $Matches[2] }
    elseif ($a -cmatch '^-([A-Za-z])(?:=(.*))?$') {
        if (-not $shortOptions.ContainsKey($Matches[1])) { throw "未知选项：$a（见 tts --help）" }
        $name = $shortOptions[$Matches[1]]; $inline = $Matches[2]
    }
    if ($name) {
        if ($name -in $flagOptions) { $flags[$name] = $true; continue }
        if ($name -notin $valueOptions) { throw "未知选项：$a（见 tts --help）" }
        if ($inline) { $opt[$name] = $inline }
        elseif ($i + 1 -lt $args.Count) { $opt[$name] = [string]$args[++$i] }
        else { throw "选项 $a 缺少取值。" }
        continue
    }
    $inputs.Add($a)
}
if ($flags.help) { Show-Usage; return }

# 没有位置参数时读取管道输入
if ($inputs.Count -eq 0 -or ($inputs.Count -eq 1 -and $inputs[0] -eq '-')) {
    $piped = $null
    if ([Console]::IsInputRedirected) {
        [Console]::InputEncoding = [Text.Encoding]::UTF8
        $piped = [Console]::In.ReadToEnd()
    }
    # 单独使用 --stop（没有要朗读的内容）：只停止服务、卸载模型
    if ($flags.stop -and [string]::IsNullOrWhiteSpace($piped)) {
        & "$PSScriptRoot\stop-server.ps1"
        return
    }
    if ([string]::IsNullOrWhiteSpace($piped)) { Show-Usage; return }
    $inputs.Clear(); $inputs.Add($piped)
}
if ($opt.output_name -and $inputs.Count -gt 1) { throw '--output_name 仅在单个输入时可用。' }
if ([bool]$opt.voice_ref -ne [bool]$opt.reference_text) { throw '--voice_ref 与 --reference_text 必须同时提供。' }

$root = $PSScriptRoot
$outDir = [IO.Path]::GetFullPath($opt.output_dir, (Get-Location).ProviderPath)
if (-not $flags.speak) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# 服务未运行时自动启动
if (-not $flags.no_start) {
    $startArgs = @{}
    if ($opt.port) { $startArgs.Port = [int]$opt.port }
    & "$root\start-server.ps1" @startArgs | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$n = 0
foreach ($item in $inputs) {
    $n++
    $speak = @{ Seed = [int]$opt.seed; MaxTokens = [int]$opt.max_tokens }
    if ($opt.instruct) { $speak.Instructions = $opt.instruct }
    if ($opt.port) { $speak.Port = [int]$opt.port }
    if ($opt.voice_ref) {
        $speak.VoiceRef = (Resolve-Path -LiteralPath $opt.voice_ref).Path
        $speak.ReferenceText = $opt.reference_text
    }

    # 既存的文件按文本文件读取，否则当作要朗读的文字
    if ($item.Length -lt 260 -and (Test-Path -LiteralPath $item -PathType Leaf)) {
        $speak.TextFile = (Resolve-Path -LiteralPath $item).Path
        $base = [IO.Path]::GetFileNameWithoutExtension($item)
    } else {
        $speak.Text = $item
        $base = if ($inputs.Count -gt 1) { "speech_${stamp}_$n" } else { "speech_$stamp" }
    }
    if ($opt.output_name) { $base = $opt.output_name }

    # speak.ps1 只允许写入项目目录，先写到临时位置再移到目标目录
    $tmpRel = "outputs\_tts_$([guid]::NewGuid().ToString('N')).wav"
    $speak.Output = $tmpRel
    $tmpWav = Join-Path $root $tmpRel
    try {
        $info = & "$root\speak.ps1" @speak
        if ($flags.speak) {
            # 只朗读：直接播放临时文件，随后由 finally 删除
            Write-Host ("正在朗读（音频 {0:N1} 秒，用时 {1:N1} 秒）" -f $info.'音频秒数', $info.'请求秒数')
            $player = [Media.SoundPlayer]::new($tmpWav)
            try { $player.PlaySync() } finally { $player.Dispose() }
        } else {
            $dest = Join-Path $outDir "$base.wav"
            Move-Item -LiteralPath $tmpWav -Destination $dest -Force
        }
    } finally {
        Remove-Item -LiteralPath $tmpWav, ([IO.Path]::ChangeExtension($tmpWav, '.json')) -ErrorAction SilentlyContinue
    }
    if ($flags.speak) { continue }
    Write-Host ("已生成 {0}（音频 {1:N1} 秒，用时 {2:N1} 秒）" -f $dest, $info.'音频秒数', $info.'请求秒数')

    if ($flags.play) {
        $player = [Media.SoundPlayer]::new($dest)
        try { $player.PlaySync() } finally { $player.Dispose() }
    }
}

if ($flags.stop) { & "$root\stop-server.ps1" | Out-Null }
