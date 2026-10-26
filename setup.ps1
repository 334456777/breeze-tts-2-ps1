<#
.SYNOPSIS
下载并校验 Q8_0 模型及 CUDA 安装包，安装本地运行器。
.PARAMETER AssetDirectory
离线文件夹：可提供已下载的同名模型和两个压缩包。
.PARAMETER Offline
仅离线：缺失或校验失败时直接报错，不访问网络。
.PARAMETER DownloadOnly
仅下载：完成下载及校验，不解压，不停止已有服务。
#>
[CmdletBinding()]
param(
    [string]$AssetDirectory,
    [switch]$Offline,
    [switch]$DownloadOnly
)
. "$PSScriptRoot\common.ps1"
if (-not [Environment]::Is64BitProcess -or $env:OS -ne 'Windows_NT') {
    throw '请使用 64 位 Windows PowerShell 5.1 或 PowerShell 7 运行此脚本。'
}
Initialize-ProjectEnvironment
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$assets = @(Read-ProjectJson 'config\assets.json')

function Get-PinnedAsset($Asset) {
    $target = Resolve-ProjectPath $Asset.path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    if (Test-Asset $Asset $target) { Write-Host "校验通过：$($Asset.path)"; return }
    if ($AssetDirectory) {
        $cached = Join-Path ([IO.Path]::GetFullPath($AssetDirectory)) ([IO.Path]::GetFileName($target))
        if (Test-Asset $Asset $cached) {
            Copy-Item -LiteralPath $cached -Destination $target -Force
            Write-Host "已导入并校验：$($Asset.path)"
            return
        }
    }
    if ($Offline) { throw "离线文件缺失或校验失败：$($Asset.path)" }
    $partial = $target + '.partial'
    if ((Test-Path -LiteralPath $partial) -and (Get-Item -LiteralPath $partial).Length -ge [long]$Asset.size) {
        if (Test-Asset $Asset $partial) {
            Move-Item -LiteralPath $partial -Destination $target -Force
            return
        }
        [IO.File]::WriteAllBytes($partial, [byte[]]@())
    }
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $response = $null; $inputStream = $null; $outputStream = $null
        try {
            $offset = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { 0 }
            $request = [Net.HttpWebRequest]::Create($Asset.url)
            $request.UserAgent = 'Breeze-audio.cpp-Q8-setup/1.0'
            $request.Timeout = 120000
            $request.ReadWriteTimeout = 120000
            $request.KeepAlive = $false
            if ($offset -gt 0) { $request.AddRange([long]$offset) }
            $response = $request.GetResponse()
            $resume = [int]$response.StatusCode -eq 206 -and $offset -gt 0
            if ($resume -and -not $response.Headers['Content-Range'].StartsWith("bytes $offset-")) {
                throw '下载服务器返回的字节范围不正确。'
            }
            if (-not $resume) { $offset = 0 }
            $mode = if ($resume) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
            $outputStream = [IO.File]::Open($partial, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $inputStream = $response.GetResponseStream()
            $buffer = New-Object byte[] (4 * 1024 * 1024)
            $downloaded = [long]$offset
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outputStream.Write($buffer, 0, $count)
                $downloaded += $count
                if ($downloaded -gt [long]$Asset.size) { throw '下载内容超过固定版本的文件大小。' }
                if ($timer.Elapsed.TotalSeconds -ge 10) {
                    Write-Host ('下载进度：{0}，{1:N2} / {2:N2} GiB' -f $target, ($downloaded / 1GB), ($Asset.size / 1GB))
                    $timer.Restart()
                }
            }
            $outputStream.Dispose(); $outputStream = $null
            if (-not (Test-Asset $Asset $partial)) {
                if ((Get-Item -LiteralPath $partial).Length -ge [long]$Asset.size) {
                    [IO.File]::WriteAllBytes($partial, [byte[]]@())
                }
                throw '下载文件的大小或 SHA-256 校验失败。'
            }
            Move-Item -LiteralPath $partial -Destination $target -Force
            Write-Host "下载及校验完成：$($Asset.path)"
            return
        } catch {
            if ($attempt -eq 6) { throw }
            Write-Host "下载失败，准备第 $attempt/6 次重试：$($_.Exception.Message)"
            Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 10))
        } finally {
            if ($inputStream) { $inputStream.Dispose() }
            if ($outputStream) { $outputStream.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
}

foreach ($asset in $assets) { Get-PinnedAsset $asset }
if ($DownloadOnly) { Write-Host '所有固定版本文件均已校验通过。'; return }
& "$PSScriptRoot\stop-server.ps1"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($asset in $assets | Where-Object { $_.extract_to }) {
    $target = Resolve-ProjectPath $asset.extract_to
    $staging = Resolve-ProjectPath ($asset.extract_to + '.installing')
    if (Test-Path -LiteralPath $staging) { Remove-ProjectDirectory ($asset.extract_to + '.installing') }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-ProjectPath $asset.path))
    try {
        $files = @()
        foreach ($entry in $archive.Entries) {
            # 只安装 HTTP 服务程序、依赖 DLL 和上游许可证。
            if ($entry.FullName -ne $entry.Name -or -not $entry.Name) { continue }
            if ($entry.Name -notmatch '\.dll$' -and $entry.Name -notin @('audiocpp_server.exe', 'LICENSE')) { continue }
            $file = Join-Path $staging $entry.Name
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $file, $true)
            $files += $entry.Name
        }
        if (-not $files.Count) { throw "压缩包中没有可用的运行文件：$($asset.path)" }
        if ($asset.extract_to -eq 'runtime/audio.cpp' -and 'audiocpp_server.exe' -notin $files) {
            throw '固定版本安装包中缺少服务程序。'
        }
    } finally { $archive.Dispose() }
    if (Test-Path -LiteralPath $target) { Remove-ProjectDirectory $asset.extract_to }
    Move-Item -LiteralPath $staging -Destination $target
    Write-ProjectJson ($asset.extract_to + '/installed.json') @{archive_sha256=$asset.sha256; files=$files}
    Write-Host "安装完成：$($asset.extract_to)"
}
Write-Host '安装完成。请先运行 .\start-server.ps1，再运行 .\speak.ps1 -Text "你好"。当前尚未加载显存。'
