<#
.SYNOPSIS
验证安装后的完整运行流程，结束后自动删除测试音频并卸载显存。
.PARAMETER IncludeStreaming
包含流式：额外验证流式模式，需要重新加载一次模型。
#>
[CmdletBinding()]
param([switch]$IncludeStreaming)
. "$PSScriptRoot\common.ps1"
$state = Get-ServerState
if ($state -and (Get-VerifiedServerProcess $state)) { throw '请先停止服务，再运行完整验证。' }
Initialize-ProjectEnvironment
$result = @{checked_at=[DateTime]::UtcNow.ToString('o'); tests=@(); success=$false}
$testDirectory = 'outputs\verification'
try {
    & "$PSScriptRoot\start-server.ps1"
    & "$PSScriptRoot\start-server.ps1"
    $text = '你好，这是本地语音测试。'
    $result.tests += & "$PSScriptRoot\speak.ps1" -Text $text -Instructions '一位语气平静、说普通话的成年女性。' -Output "$testDirectory\zh.wav"
    # 英文例句用于检查英文合成功能，也作为后续模仿的参考音频。
    $result.tests += & "$PSScriptRoot\speak.ps1" -Text 'Hello, this voice is generated on the local GPU.' -Output "$testDirectory\en.wav"
    $result.tests += & "$PSScriptRoot\speak.ps1" -Text 'This is a reference audio test.' `
        -VoiceRef (Resolve-ProjectPath "$testDirectory\en.wav") -ReferenceText 'Hello, this voice is generated on the local GPU.' `
        -Output "$testDirectory\clone.wav"
    & "$PSScriptRoot\stop-server.ps1"
    if ($IncludeStreaming) {
        & "$PSScriptRoot\start-server.ps1" -Mode streaming
        $result.tests += & "$PSScriptRoot\speak.ps1" -Text 'Hello, this is a streaming test.' -Output "$testDirectory\stream.wav"
    }
    $result.success = $true
} finally {
    & "$PSScriptRoot\stop-server.ps1"
    $testPath = Resolve-ProjectPath $testDirectory
    if (Test-Path -LiteralPath $testPath) { Remove-ProjectDirectory $testDirectory }
    Write-ProjectJson 'logs\verification.json' $result
}
Write-Host '验证通过，测试音频已删除，模型显存已释放。检查记录见 logs\verification.json。'
