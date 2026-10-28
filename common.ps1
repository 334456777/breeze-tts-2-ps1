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

function New-PcmPlayer {
    # 通过 winmm waveOut 边接收边播放 24 kHz 单声道 16 位 PCM，不依赖第三方库。
    if (-not ('BreezePcmPlayer' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class BreezePcmPlayer : IDisposable {
    [StructLayout(LayoutKind.Sequential)]
    struct WAVEFORMATEX {
        public ushort wFormatTag; public ushort nChannels;
        public uint nSamplesPerSec; public uint nAvgBytesPerSec;
        public ushort nBlockAlign; public ushort wBitsPerSample; public ushort cbSize;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct WAVEHDR {
        public IntPtr lpData; public uint dwBufferLength; public uint dwBytesRecorded;
        public IntPtr dwUser; public uint dwFlags; public uint dwLoops;
        public IntPtr lpNext; public IntPtr reserved;
    }
    [DllImport("winmm.dll")] static extern uint waveOutOpen(out IntPtr hwo, uint device, ref WAVEFORMATEX fmt, IntPtr cb, IntPtr inst, uint flags);
    [DllImport("winmm.dll")] static extern uint waveOutPrepareHeader(IntPtr hwo, IntPtr hdr, uint size);
    [DllImport("winmm.dll")] static extern uint waveOutUnprepareHeader(IntPtr hwo, IntPtr hdr, uint size);
    [DllImport("winmm.dll")] static extern uint waveOutWrite(IntPtr hwo, IntPtr hdr, uint size);
    [DllImport("winmm.dll")] static extern uint waveOutPause(IntPtr hwo);
    [DllImport("winmm.dll")] static extern uint waveOutRestart(IntPtr hwo);
    [DllImport("winmm.dll")] static extern uint waveOutReset(IntPtr hwo);
    [DllImport("winmm.dll")] static extern uint waveOutClose(IntPtr hwo);

    const uint WHDR_DONE = 1;
    const long PrebufferBytes = 12000; // 约 250 ms，先攒一点再开播，避免开头卡顿

    class Item { public IntPtr Hdr; public IntPtr Data; }

    readonly int hdrSize = Marshal.SizeOf(typeof(WAVEHDR));
    readonly int flagsOffset = (int)Marshal.OffsetOf(typeof(WAVEHDR), "dwFlags");
    readonly List<Item> queue = new List<Item>();
    IntPtr dev;
    bool paused, hasCarry, disposed;
    byte carry;
    long buffered, total;

    public BreezePcmPlayer() {
        WAVEFORMATEX fmt = new WAVEFORMATEX();
        fmt.wFormatTag = 1; fmt.nChannels = 1; fmt.nSamplesPerSec = 24000;
        fmt.nAvgBytesPerSec = 48000; fmt.nBlockAlign = 2; fmt.wBitsPerSample = 16;
        uint rc = waveOutOpen(out dev, 0xFFFFFFFF, ref fmt, IntPtr.Zero, IntPtr.Zero, 0);
        if (rc != 0) throw new InvalidOperationException("无法打开音频输出设备（错误码 " + rc + "）。");
        waveOutPause(dev);
        paused = true;
    }

    public void Write(byte[] buf, int offset, int count) {
        int n = count + (hasCarry ? 1 : 0);
        byte[] data = new byte[n];
        int p = 0;
        if (hasCarry) { data[0] = carry; p = 1; hasCarry = false; }
        Buffer.BlockCopy(buf, offset, data, p, count);
        if ((n & 1) == 1) { carry = data[n - 1]; hasCarry = true; n--; }
        if (n == 0) return;
        Item item = new Item();
        item.Data = Marshal.AllocHGlobal(n);
        Marshal.Copy(data, 0, item.Data, n);
        WAVEHDR h = new WAVEHDR();
        h.lpData = item.Data; h.dwBufferLength = (uint)n;
        item.Hdr = Marshal.AllocHGlobal(hdrSize);
        Marshal.StructureToPtr(h, item.Hdr, false);
        waveOutPrepareHeader(dev, item.Hdr, (uint)hdrSize);
        waveOutWrite(dev, item.Hdr, (uint)hdrSize);
        queue.Add(item);
        buffered += n; total += n;
        Reap();
        if (paused && buffered >= PrebufferBytes) { waveOutRestart(dev); paused = false; }
    }

    void Reap() {
        while (queue.Count > 0) {
            Item item = queue[0];
            if ((((uint)Marshal.ReadInt32(item.Hdr, flagsOffset)) & WHDR_DONE) == 0) break;
            Release(item);
            queue.RemoveAt(0);
        }
    }

    void Release(Item item) {
        waveOutUnprepareHeader(dev, item.Hdr, (uint)hdrSize);
        Marshal.FreeHGlobal(item.Hdr);
        Marshal.FreeHGlobal(item.Data);
    }

    // 等待已提交的音频播完。
    public void Drain() {
        if (paused) { waveOutRestart(dev); paused = false; }
        DateTime deadline = DateTime.UtcNow.AddSeconds(total / 48000.0 + 10);
        while (queue.Count > 0 && DateTime.UtcNow < deadline) {
            Reap();
            Thread.Sleep(20);
        }
    }

    public void Dispose() {
        if (disposed) return;
        disposed = true;
        waveOutReset(dev);
        foreach (Item item in queue) Release(item);
        queue.Clear();
        waveOutClose(dev);
    }
}
'@
    }
    return New-Object BreezePcmPlayer
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
