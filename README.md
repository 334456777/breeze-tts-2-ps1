# audio.cpp CUDA + Breeze TTS 2 Q8_0

部署和使用 **audio.cpp CUDA + Breeze TTS 2 Q8_0** 进行文字转语音（Text to Speak）

## 环境与磁盘空间

需要 64 位 Windows、PowerShell 5.1 或 7，以及支持 CUDA 12.4 的 NVIDIA 驱动。本机 RTX 3060 Ti 8 GB 已验证可运行。

**首次安装建议至少预留 10 GiB（约 10.7 GB）可用磁盘空间。** 首次下载约 6.15 GB，当前固定版本的实际占用如下：

| 内容 | 磁盘占用 |
| --- | --- |
| Q8_0 模型 | 约 4.73 GiB（5.08 GB） |
| audio.cpp 及 CUDA 运行库 | 约 1.91 GiB（2.05 GB） |
| 两个下载压缩包 | 约 1.00 GiB（1.07 GB） |
| 完整安装合计 | **约 7.64 GiB（8.20 GB）** |

10 GiB 包含解压及少量缓存余量。删除安装包后约占 **6.64 GiB（7.13 GB）**。已有安装重新部署时，建议另外留出 **2 GiB** 临时空间。生成的 24 kHz 单声道 16 位 WAV，每分钟约 **2.88 MB**，需另算空间。

## 安装与启动

在本文件夹打开 PowerShell：

```powershell
# 下载或复用固定版本文件，校验大小和 SHA-256，安装运行器
.\setup.ps1

# 后台启动，确认 Q8_0 已通过 CUDA 加载到显卡
.\start-server.ps1

# 查看服务、加载状态和整卡显存
.\status.ps1

# 停止服务并释放模型显存
.\stop-server.ps1
```

`setup.ps1` 可以在本目录重复运行，复用已有且校验通过的文件，缺失时下载，下载中断后续传，失败自动重试。重新安装运行器前会停止已有服务；安装完成不自动加载模型。

默认只监听 `127.0.0.1:8088`。启动脚本返回后，后台进程继续运行；重复启动不创建第二个实例。以下启动配置任选一种，调整已运行的服务前先执行 `stop-server.ps1`：

```powershell
.\start-server.ps1 -Port 8089 -Device 0 -Threads 4

# 监听所有 IPv4 网卡，供局域网客户端访问
.\start-server.ps1 -ListenAddress 0.0.0.0 -Port 8088

# 只监听指定网卡的 IP，请替换为本机实际地址
.\start-server.ps1 -ListenAddress 192.168.1.100 -Port 8088
```

修改运行中的服务参数前先停止服务。`status.ps1` 和 `speak.ps1` 自动跟随保存的监听地址；监听全部网卡时，本机客户端使用回环地址，远程客户端使用这台电脑的实际 IP。脚本不修改防火墙规则。没有设置系统服务或开机自启，没有安装全局依赖；脚本不会修改系统 PATH，只有你按“全局 tts 命令”一节手动操作时才会添加 `bin` 目录。

## 生成语音

```powershell
# 中文
.\speak.ps1 -Text '你好，欢迎使用本地语音合成。' -Output outputs\hello.wav

# 英文
.\speak.ps1 -Text 'Hello, this model is running on the local GPU.' -Output outputs\hello-en.wav

# 描述说话人的音色、背景、语气和表达风格
.\speak.ps1 -Text '下午好，欢迎收听今天的节目。' `
    -Instructions '一位说普通话、语气温暖放松的成年女性。' `
    -Output outputs\style.wav

# UTF-8 文本文件
.\speak.ps1 -TextFile .\input.txt -Output outputs\article.wav

# 参考音频模仿；参考文本必须与参考音频实际内容一致
.\speak.ps1 -Text '这是希望用参考音色说出的新句子。' `
    -VoiceRef .\reference.wav `
    -ReferenceText '这里填写参考音频中实际说出的完整文字。' `
    -Instructions '请自然平静地说话。' -Output outputs\clone.wav
```

输出必须位于本项目内，默认为 `outputs/speech.wav`。每次保存 24 kHz、单声道、16 位 PCM WAV 和同名 JSON，记录请求参数、用时及音频时长。`-Seed` 默认 42，`-MaxTokens` 默认 1500。

`-VoiceRef` 与 `-ReferenceText` 必须同时提供。参考 WAV 只读取，不复制到项目外。模仿效果取决于参考录音质量；自动验证不代替人工评估音色相似度。

## 全局 tts 命令

`bin\tts.cmd` 让你在任意目录、任意终端（cmd、PowerShell、Git Bash、Windows Terminal）直接运行 `tts`，参数风格参考 whisperx。服务未运行时会自动启动并加载模型。

在本项目目录中打开 PowerShell，把 `bin` 目录加入用户 PATH（只需一次，之后新开的终端生效）：

```powershell
$bin = Join-Path $PWD 'bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', $userPath.TrimEnd(';') + ';' + $bin, 'User')
}
```

重复执行不会重复添加。移动项目文件夹后需要重新执行，并删掉旧的 PATH 条目。

```powershell
tts "你好，欢迎使用本地语音合成。" -p          # 生成到当前目录并播放
tts "只朗读，不留文件" -s                      # 朗读后不保存任何文件
tts article.txt -o D:\audio                    # 读取文本文件，指定输出目录
echo 你好 | tts -n hello                       # 管道输入，指定文件名
tts "下午好" -i "一位说普通话、语气温暖的成年女性。"
tts "新句子" -v ref.wav -t "参考音频里的原话"
```

| 短 | 长 | 说明 |
| --- | --- | --- |
| `-o` | `--output_dir` | 输出目录，默认当前目录 |
| `-n` | `--output_name` | 输出文件名（不含扩展名），仅单个输入时有效 |
| `-i` | `--instruct` | 声音描述（音色、语气、风格） |
| `-v` | `--voice_ref` | 参考音频，需同时提供 `-t` |
| `-t` | `--reference_text` | 参考音频中实际说出的文字 |
| `-e` | `--seed` | 随机种子，默认 42 |
| `-m` | `--max_tokens` | 最大声学帧数，默认 1500 |
| `-P` | `--port` | 服务端口 |
| `-p` | `--play` | 生成后播放 |
| `-s` | `--speak` | 只朗读，不保留任何文件（自动播放） |
| `-N` | `--no_start` | 服务未运行时不自动启动，直接报错 |
| `-x` | `--stop` | 合成结束后停止服务，释放显存 |
| `-h` | `--help` | 显示帮助 |

短参数区分大小写（`-p` 播放、`-P` 端口），不支持 `-sp` 这类合并写法。`tts` 是对 `speak.ps1` 的封装，输出先写入项目内的临时文件再移到目标目录。

模型加载进显存后常驻（没有空闲自动卸载），直到执行 `stop-server.ps1` 或 `tts -x`。

## 让 AI 开口说话（Claude skill）

`skills\speak\SKILL.md` 是一个 Claude Code skill，装上后 Claude 可以在你要求“读给我听”“做完叫我一声”时调用 `tts -s` 开口说话，并按场合（完成、出错、提醒、讲解等）用 `-i` 调整语气。

安装：先完成上面的 `tts` 全局命令配置，再把 skill 复制到 Claude Code 的用户级技能目录，然后重启 Claude Code：

```powershell
Copy-Item -Recurse skills\speak $HOME\.claude\skills\speak
```

安装后可输入 `/speak` 手动调用，也可以直接说“念给我听”让 Claude 自动调用。`SKILL.md` 中的 `<项目目录>` 是占位符，只在备用调用和停止服务时用到，请改成本项目的实际路径。

## 流式生成

```powershell
.\stop-server.ps1
.\start-server.ps1 -Mode streaming
.\speak.ps1 -Text '你好，这是一段流式生成的语音。' -Output outputs\stream.wav

# 切回完整响应模式
.\stop-server.ps1
.\start-server.ps1 -Mode offline
```

每次服务只配置一种模式，切换时明确重启，避免请求时隐式重新加载。客户端自动读取服务模式，连续接收 PCM 后封装成 WAV，并记录首音频到达用时；本脚本保存文件，不提供实时播放器。

模型加载约需数十秒。此前相同固定版本在本机预热后，完整生成约 1.92 倍实时、流式中文/英文首音频约 75 / 77 ms，整卡峰值约 5.61 GiB；不包含冷启动，不保证其他文本和机器的速度。

## HTTP 接口

```powershell
Invoke-RestMethod http://127.0.0.1:8088/health
Invoke-RestMethod http://127.0.0.1:8088/v1/models

$body = @{
    model = 'breeze'
    input = '你好，这是通过本地接口生成的语音。'
    response_format = 'wav'
    options = @{ instruct = '请清晰自然地说话。'; seed = '42' }
} | ConvertTo-Json -Depth 5
Invoke-WebRequest -Uri http://127.0.0.1:8088/v1/audio/speech `
    -Method Post -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) -OutFile outputs\http.wav
```

流式模式的模型 ID 也是 `breeze`，请求设置 `stream: true`、`response_format: "pcm"`、`stream_format: "audio"`。返回 24 kHz、单声道、16 位有符号小端 PCM，需要客户端持续读取；不能直接当 WAV 或 SSE 使用。参考模仿可增加 `voice_ref`（服务所在机器的绝对路径）和 `reference_text`。

## 离线安装与验证

```powershell
# 只下载和校验，不解压，也不停止已有服务
.\setup.ps1 -DownloadOnly

# 导入同名模型和安装包，禁止访问网络
.\setup.ps1 -AssetDirectory 'D:\offline-assets' -Offline

# 验证重复启动、中英文合成、参考模仿和流式接口
.\verify.ps1 -IncludeStreaming

# 查看脚本中文帮助
Get-Help .\speak.ps1 -Full
```

离线文件夹提供 `breeze-tts-2-q8_0.gguf`、`audiocpp.zip`、`audiocpp-cudart.zip`。缺失或哈希不匹配时，`-Offline` 直接报错。验证结束后删除测试音频并释放显存，只保留 `logs/verification.json` 检查记录。

## 清理和卸载

```powershell
# 仅预览，不停止服务、不删除文件
.\cleanup.ps1 -All -Preview

# 停止服务，仅删除项目缓存和临时文件
.\cleanup.ps1

# 删除生成的音频和请求 JSON
.\cleanup.ps1 -RemoveOutputs

# 删除安装压缩包，保留可运行的程序和模型
.\cleanup.ps1 -RemoveDownloads

# 卸载所有下载、程序、模型、音频、日志和缓存，只保留源码
.\cleanup.ps1 -All
```

还可以单独使用 `-RemoveRuntime`、`-RemoveModels`、`-RemoveLogs`。清理只处理本项目内明确列出的目录，拒绝符号链接和目录联接。项目管理的缓存和临时文件都位于本目录，没有新增的外部安装目录需要清理；Windows 和显卡驱动自行维护的系统缓存不在本项目管理范围内。

## 文件与版本

```text
setup.ps1          下载、校验、安装
start-server.ps1   CUDA 加载与后台启动
stop-server.ps1    停止服务、卸载显存
status.ps1         服务与显存状态
speak.ps1          语音合成、声音描述、参考模仿、流式接收
tts.ps1            全局 tts 命令的实现（whisperx 风格参数）
bin/tts.cmd        tts 命令入口，把 bin 加入 PATH 后可在任意终端使用
skills/speak/      让 Claude 开口说话的 skill
verify.ps1         完整验证，结束后删除测试音频
cleanup.ps1        缓存清理与卸载
common.ps1         共享辅助函数
config/            固定下载地址、SHA-256、运行配置
models/            内置所需音频组件的 Q8_0 GGUF
runtime/audio.cpp/ 最小服务程序、GGML 和依赖 DLL
runtime/cuda/      本地 CUDA DLL
downloads/         两个 ZIP 安装包
outputs/           WAV 及请求 JSON
logs/              服务配置、进程状态、日志和验证报告
.cache/ .tmp/      项目缓存和临时文件
```

运行器固定为 `v0.9.2-drama3-base-small`、CUDA 12.4。模型固定于提交 `462b4cec041e06ffb3d8fcf0d8c655051b1cd9f5`，文件大小 5,079,670,336 字节（4.73 GiB）。脚本不自动追随最新版。

来源：[运行器发布版](https://github.com/0xShug0/audio.cpp/releases/tag/v0.9.2-drama3-base-small)、[对应模型文档](https://github.com/0xShug0/audio.cpp/blob/v0.9.2-drama3-base-small/docs/models/breeze_tts.md)、[固定模型文件](https://huggingface.co/audio-cpp/audio.cpp-gguf/blob/462b4cec041e06ffb3d8fcf0d8c655051b1cd9f5/Breeze-TTS-2-GGUF/breeze-tts-2-q8_0.gguf)。模型许可证和声明见 `LICENSE`、`NOTICE`；运行器许可证随安装保存在 `runtime/audio.cpp/LICENSE`。
