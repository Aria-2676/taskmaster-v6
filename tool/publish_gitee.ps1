# Gitee 附件上传：把当前版本的 APK 传到 Gitee Release，作为国内第一顺位下载源。
#
# 为什么单独一个脚本：
#   publish_release.ps1 管的是 GitHub 那条链，`-AltBase` 只把 Gitee 地址**写进清单**，
#   不传文件。这一步长期靠手工，结果 6.0.3 之后连着几个版本都没传，
#   用户看到 Gitee 上还是旧包，以为配置失效了。既然有 token，就让它自动化。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tool\publish_gitee.ps1
#   powershell -ExecutionPolicy Bypass -File tool\publish_gitee.ps1 -Version 6.1.2
#
# 幂等：已存在的附件按名字跳过，可反复跑。
#
# **只传两个 ABI**（arm64-v8a、armeabi-v7a）：
#   Gitee 附件配额是 1GB **总量**，四个包全传只够放 8 个版本。
#   x86_64 只有模拟器用，fat 包不再发布 —— 缺的包客户端会自动退到 GitHub 代理
#   （MultiSourceDownloader 遇到 HTTP 4xx 清残包换下一个源），不影响下载成功。

[CmdletBinding()]
param(
    [string]$Version = '',

    [string]$OwnerRepo = 'yaozhenqian/taskmaster-release',

    # 只传这两个。要加包先读 docs/gitee-release.md 里的配额账。
    [string[]]$Assets = @(
        'app-arm64-v8a-release.apk',
        'app-armeabi-v7a-release.apk'
    ),

    [string]$AssetDir = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $AssetDir) {
    $AssetDir = Join-Path $repoRoot 'build\app\outputs\flutter-apk'
}

function Log($msg) {
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $msg"
}

# ---- token ----
$token = $env:GITEE_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
    $tokenFile = Join-Path $PSScriptRoot 'gitee_token.txt'
    if (Test-Path $tokenFile) {
        $token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    }
}
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "缺少 GITEE_TOKEN。任选其一：`n  1. 设置环境变量：`$env:GITEE_TOKEN = 'xxx'`n  2. 写入 tool/gitee_token.txt（已在 .gitignore 里）"
}

$apiBase = "https://gitee.com/api/v5/repos/$OwnerRepo"

# ---- 清单：版本号与更新说明 ----
$manifestPath = Join-Path $repoRoot 'update.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $manifest.latest.version
    Log "版本号取自 update.json：$Version"
}

# Gitee 建 Release 时 body 是**必填**（漏了会回 {"messages":["body is missing"]}），
# 之前用 curl 手传时随手写了说明所以没踩到。这里用清单里的 notes 拼。
$releaseBody = (@($manifest.latest.notes) | ForEach-Object { "- $_" }) -join "`n"
if ([string]::IsNullOrWhiteSpace($releaseBody)) { $releaseBody = $tag }
$tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
Log "目标 Release：$tag（$OwnerRepo）"

# ---- 本地包 ----
foreach ($name in $Assets) {
    $path = Join-Path $AssetDir $name
    if (-not (Test-Path $path)) {
        throw "缺少资产：$path`n先跑 tool\build_apk.ps1 构建。"
    }
    $size = (Get-Item $path).Length
    Log ("  {0}  {1:N1} MB" -f $name, ($size / 1MB))
}

# ---- 找 / 建 Release ----
Log '查找 Release'
$releases = Invoke-RestMethod -Method Get -Uri "$apiBase/releases?access_token=$token&per_page=100"
$release = $releases | Where-Object { $_.tag_name -eq $tag } | Select-Object -First 1

if ($null -eq $release) {
    Log '  未找到，创建中'
    $body = @{
        access_token     = $token
        tag_name         = $tag
        name             = $tag
        body             = $releaseBody
        target_commitish = 'main'
    }
    $release = Invoke-RestMethod -Method Post -Uri "$apiBase/releases" -Body $body
    Log "  已创建，id = $($release.id)"
} else {
    Log "  已存在，id = $($release.id)"
}

$releaseId = $release.id

# ---- 上传缺失的附件 ----
# 用 curl.exe 而不是 Invoke-RestMethod：PowerShell 5.1 的 Invoke-RestMethod
# 不支持 -Form（那是 PS 6+），传 multipart 很别扭；curl.exe 在 Win10 1803+ 自带。
$curl = 'curl.exe'
if (-not (Get-Command $curl -ErrorAction SilentlyContinue)) {
    throw '找不到 curl.exe（Windows 10 1803 起自带）。'
}

foreach ($name in $Assets) {
    $current = Invoke-RestMethod -Method Get -Uri "$apiBase/releases/$releaseId`?access_token=$token"
    # 必须用 @() 包住：Where-Object 只有一个结果时返回标量，
    # 标量的 .Count 在 PS 5.1 里不可靠 —— 判断错了会把同名附件再传一遍，
    # 而 Gitee **不拦同名重复**（第一次跑就撞上了，附件列表里出现两份）。
    $existingNames = @($current.assets | ForEach-Object { $_.name })
    if ($existingNames -contains $name) {
        Log "  跳过（已存在）：$name"
        continue
    }

    $path = Join-Path $AssetDir $name
    Log "  上传：$name"
    $resp = & $curl -s --max-time 900 -X POST "$apiBase/releases/$releaseId/attach_files" `
        -F "access_token=$token" -F "file=@$path"
    $obj = $resp | ConvertFrom-Json
    if ($obj.PSObject.Properties.Name -contains 'message') {
        # 配额满是最常见的一种：Gitee 用的是**总量**限制，删旧版本才能腾出来
        throw "上传失败（$name）：$($obj.message)"
    }
    Log ("    完成，{0:N0} 字节" -f $obj.size)
}

# ---- 回读核对 ----
Log '回读核对'
$final = Invoke-RestMethod -Method Get -Uri "$apiBase/releases/$releaseId`?access_token=$token"
$names = @($final.assets | ForEach-Object { $_.name })
foreach ($name in $Assets) {
    if ($names -notcontains $name) {
        throw "回读缺少附件：$name"
    }
}
Log "  Release $tag 现有附件：$($names -join ', ')"
Log "地址前缀：https://gitee.com/$OwnerRepo/releases/download/$tag/"
Log '完成'
