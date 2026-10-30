# 任务管家（V5）整包发布工具：一条命令完成「推送 → Release → 资产 → 清单 → CDN 刷新」
#
# 存在的理由（全是真踩过的坑）：
#   1. PowerShell 5.1 用 curl.exe 内联 -d 传 JSON 会被剥掉双引号，GitHub
#      直接回 400 —— 本工具所有 JSON 一律写临时文件 --data-binary "@file"。
#   2. 手写 sha256 进脚本/清单会丢字符（63 位 vs 64 位肉眼根本分不出），
#      导致正确的上传被循环删除 —— 摘要一律运行时从 APK 现算。
#   3. 本机到 GitHub 间歇性不可达 —— 所有网络操作按错误类型重试到成功
#      （4xx 业务错误不重试，立刻进入幂等处理）。
#   4. Release 资产必须 size + digest 双核对，避免半截包被当成发布完成。
#
# 用法（先手工完成代码提交，再跑本工具）：
#   $env:GITHUB_TOKEN = 'ghp_xxx'   # 经典 token，需 repo 权限；不落盘、不进命令行历史
#   powershell -ExecutionPolicy Bypass -File tool\publish_release.ps1 -Version 5.5.23
#
# 默认流程（全部幂等，可重复执行）：
#   0. 校验 4 个 APK 在位，现算 sha256/size
#   1. 本地缺 tag 时在 HEAD 建附注 tag
#   2. git push 分支 + tag（网络抖动无限重试）
#   3. 创建 GitHub Release（已存在则复用）
#   4. 上传/核对 4 个 APK（同名资产 size/digest 不符则删后重传）
#   5. 重写 update.json（version/updatedAt/url/sha/size/mirrors，notes 保留）
#   6. update.json 单独提交（UTF-8 文件 -F，遵守 rule-7）并推送
#   7. 通知 purge.jsdelivr.net 刷新清单缓存
#
# 可选项：
#   -Notes @('本次更新内容1','2')   更新 update.json 的 notes（不传则保留原文）
#   -Branch main                    跟踪分支名
#   -AssetDir <path>                APK 目录（默认 build\app\outputs\flutter-apk）
#   -SkipPurge / -SkipManifestCommit
#   -MaxAttempts 50                 网络重试上限（0 = 无限，默认）

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$OwnerRepo = 'Aria-2676/taskmaster-v6',

    [string]$Branch = 'main',

    [string]$AssetDir,

    [string[]]$Notes,

    # 清单 mirrors 字段热下发的镜像前缀，顺序即客户端尝试顺序，
    # 与 lib/core/config/download_mirrors.dart 的内置列表保持一致；
    # 老客户端不识别该字段会直接忽略，无兼容问题。
    [string[]]$MirrorPrefixes = @('https://ghfast.top', 'https://gh-proxy.com'),

    # 备用直链基址（例如 Gitee Release）：按 `<AltBase>/<tag>/<文件名>` 拼出每个资产的
    # 镜像地址，并**排在 MirrorPrefixes 之前**——国内用户第一顺位走它，GitHub 和
    # 公共代理退成备选。传空表示不启用。
    [string]$AltBase = '',

    [switch]$SkipPurge,
    [switch]$SkipManifestCommit,

    [int]$MaxAttempts = 0
)

$ErrorActionPreference = 'Stop'

function Log($msg) {
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $msg"
}

# 版本号清洗：自动剥离常见前后缀，兼容 pubspec.yaml 里的 "5.5.23+0" 和 "v5.5.23"
$Version = $Version.Trim() -replace '^[vV]', '' -replace '\+.*$', ''
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "版本号格式错误：'$Version'。请使用纯数字三段式，如 5.5.23（自动清洗后仍不符合）。"
}

# GitHub Token：优先从环境变量读取，其次从 tool/github_token.txt（已加入 .gitignore）
if (-not $env:GITHUB_TOKEN) {
    $tokenFile = Join-Path $PSScriptRoot 'github_token.txt'
    if (Test-Path $tokenFile) {
        # 用 -Encoding UTF8 读取（PS5.1 会自动剥离 BOM）；再去掉可能的残留 U+FEFF 与首尾空白，
        # 否则 token 会带上脏字符，GitHub 直接回 401 Bad credentials。
        $tokenContent = Get-Content $tokenFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($tokenContent) {
            $env:GITHUB_TOKEN = $tokenContent.TrimStart([char]0xFEFF).Trim()
            Log '已从 tool/github_token.txt 读取 GITHUB_TOKEN'
        }
    }
}
if (-not $env:GITHUB_TOKEN) {
    throw "缺少 GITHUB_TOKEN。请任选其一：`n  1. 设置环境变量：`$env:GITHUB_TOKEN = 'ghp_xxx'`n  2. 将 token 写入 tool/github_token.txt（不会被提交）"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $AssetDir) {
    $AssetDir = Join-Path $repoRoot 'build\app\outputs\flutter-apk'
}

$apkFiles = @(
    'app-release.apk',
    'app-arm64-v8a-release.apk',
    'app-armeabi-v7a-release.apk',
    'app-x86_64-release.apk'
)

function Invoke-Retry {
    param(
        [scriptblock]$Action,
        [string]$Desc,
        [int]$MaxAttempts = 0
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            & $Action
            return
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match '__NOTFOUND__') { throw }
            if ($msg -match '__TRANSIENT__') {
                if ($MaxAttempts -gt 0 -and $attempt -ge $MaxAttempts) {
                    throw "已达最大重试次数（$MaxAttempts）：$Desc"
                }
                Log "  [重试 $attempt] $Desc"
                Start-Sleep -Seconds ([Math]::Min(5 * $attempt, 60))
                continue
            }
            throw
        }
    }
}

function Api-Get($url) {
    $headers = @{
        'Authorization' = "token $env:GITHUB_TOKEN"
        'Accept'        = 'application/vnd.github.v3+json'
        'User-Agent'    = 'v5-publish-tool'
    }
    $tmp = Join-Path $env:TEMP "v5_api_$(Get-Random).json"
    try {
        # -w 的 http 码走 stdout，-o 把响应体写进文件；必须直接捕获 stdout，
        # 否则管道给 Out-Null 会把 http 码丢掉，404 会被误当成“成功”。
        $httpCode = (curl.exe -s -o $tmp -w '%{http_code}' -H "Authorization: token $env:GITHUB_TOKEN" -H 'Accept: application/vnd.github.v3+json' -H 'User-Agent: v5-publish-tool' $url 2>$null | Out-String).Trim()
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "__TRANSIENT__ curl exit $code" }
        if (-not $httpCode) { $httpCode = '000' }
        # 必须按 UTF-8 读响应体：PS5.1 默认按 ANSI(GBK) 读会把中文拆坏，甚至吃掉 JSON 的引号
        $body = Get-Content $tmp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($httpCode -eq '404') { throw "__NOTFOUND__ $url" }
        if ([int]$httpCode -ge 400) { throw "HTTP $httpCode : $body" }
        return $body | ConvertFrom-Json
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Api-Json($method, $url, $bodyObj) {
    $tmpBody = Join-Path $env:TEMP "v5_api_body_$(Get-Random).json"
    $tmpResp = Join-Path $env:TEMP "v5_api_resp_$(Get-Random).json"
    try {
        $json = $bodyObj | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($tmpBody, $json, [System.Text.UTF8Encoding]::new($false))
        $httpCode = (curl.exe -s -o $tmpResp -w '%{http_code}' -X $method `
            -H "Authorization: token $env:GITHUB_TOKEN" `
            -H 'Accept: application/vnd.github.v3+json' `
            -H 'User-Agent: v5-publish-tool' `
            -H 'Content-Type: application/json' `
            --data-binary "@$tmpBody" `
            $url 2>$null | Out-String).Trim()
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "__TRANSIENT__ curl exit $code" }
        if (-not $httpCode) { $httpCode = '000' }
        $body = Get-Content $tmpResp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($httpCode -eq '404') { throw "__NOTFOUND__ $url" }
        if ([int]$httpCode -ge 400) { throw "HTTP $httpCode : $body" }
        return $body | ConvertFrom-Json
    } finally {
        Remove-Item $tmpBody, $tmpResp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GitRetry {
    param([string[]]$GitArgs, [string]$Desc)
    Invoke-Retry -Desc $Desc -MaxAttempts $MaxAttempts -Action {
        # git 把进度（如 Everything up-to-date）写到 stderr；在 $ErrorActionPreference='Stop'
        # 下这会被当成 NativeCommandError 终止性错误，逃逸出重试环。此处局部降级为 Continue。
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & git @GitArgs 2>&1 | Out-Host
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($code -ne 0) { throw "__TRANSIENT__ git exit $code" }
    }
}

Log "=== V5 发布工具 v$Version ==="

# 步骤 0：校验 APK
Log '步骤 0：校验 APK 文件'
$apkInfo = @{}
foreach ($name in $apkFiles) {
    $path = Join-Path $AssetDir $name
    if (-not (Test-Path $path)) { throw "APK 缺失：$path" }
    $hash = (Get-FileHash $path -Algorithm SHA256).Hash.ToLower()
    $size = (Get-Item $path).Length
    $apkInfo[$name] = @{ path = $path; sha256 = $hash; size = $size }
    Log "  $name : $([Math]::Round($size/1MB,2)) MB, sha256=$($hash.Substring(0,16))..."
}

# 用 aapt 确认 versionName 真的是 $Version，杜绝「拿旧包发新版」。
Log '  核对 fat 包 versionName...'
$aapt2 = $null
foreach ($bt in @(
    "$env:LOCALAPPDATA\Android\Sdk\build-tools",
    'D:\Dev\SDK\AndroidSdk\build-tools'
)) {
    if (Test-Path $bt) {
        $aapt2 = Get-ChildItem $bt -Directory | Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName 'aapt2.exe' }
        if ($aapt2 -and (Test-Path $aapt2)) { break }
    }
}
if ($aapt2 -and (Test-Path $aapt2)) {
    $dump = & $aapt2 dump badging $apkInfo['app-release.apk'].path 2>$null
    $m = $dump | Select-String -Pattern "versionName='([^']+)'" | Select-Object -First 1
    $vn = $m.Matches.Groups[1].Value
    if ($vn -and $vn -ne $Version) {
        throw "fat 包 versionName='$vn' 与 -Version '$Version' 不符 —— 先在 pubspec.yaml 改版本号并重新构建。"
    }
    if ($vn) { Log "  versionName 核对：$vn" }
} else {
    Log '  [警告] 未找到 aapt2，跳过 versionName 核对。'
}

# 步骤 1：tag
$tag = "v$Version"
Log "步骤 1：tag $tag"
& git rev-parse -q --verify "refs/tags/$tag" | Out-Null
if ($LASTEXITCODE -ne 0) {
    & git tag -a $tag -m "V$Version release"
    if ($LASTEXITCODE -ne 0) { throw "git tag 失败" }
    Log "  已创建 tag $tag"
} else {
    Log "  tag $tag 已存在"
}

# 步骤 2：push
# 企业网把 github.com 的 git 智能 HTTP 通道双向限速到 <1KB/s，git push 必挂，
# 且上面的 Invoke-GitRetry 默认无限重试会永远卡死发版流程。
# 改走 push_via_api.ps1（REST API：blob→tree→commit→ref），一次调用同时推分支和 tag，
# 并自动把本地分支重建对齐到远端同号 commit，不需要 git fetch。
Log '步骤 2：推送分支与 tag（API 通道）'
$pushApiScript = Join-Path $PSScriptRoot 'push_via_api.ps1'
if (-not (Test-Path $pushApiScript)) { throw "缺少 $pushApiScript" }
& powershell -NoProfile -ExecutionPolicy Bypass -File $pushApiScript -Branch $Branch -Tag $tag
if ($LASTEXITCODE -ne 0) { throw 'API 推送分支/tag 失败' }

# 步骤 3：Release
Log '步骤 3：创建/获取 Release'
$release = $null
try {
    $release = Api-Get "https://api.github.com/repos/$OwnerRepo/releases/tags/$tag"
    Log "  Release 已存在（id=$($release.id)）"
} catch {
    if ($_.Exception.Message -match '__NOTFOUND__') {
        Log '  Release 不存在，创建中...'
        $release = Api-Json 'POST' "https://api.github.com/repos/$OwnerRepo/releases" @{
            tag_name         = $tag
            target_commitish = $Branch
            name             = "V$Version"
            body             = "V$Version 自动发布（tool/publish_release.ps1）"
            draft            = $false
            prerelease       = $false
        }
        Log "  已创建 Release（id=$($release.id)）"
    } else { throw }
}
$releaseId = $release.id

# 步骤 4：上传/核对资产
Log '步骤 4：上传/核对 APK 资产'
foreach ($name in $apkFiles) {
    $info = $apkInfo[$name]
    $uploadUrl = "https://uploads.github.com/repos/$OwnerRepo/releases/$releaseId/assets?name=$name"
    $needUpload = $true
    $existing = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($existing) {
        $remoteSize = $existing.size
        $remoteDigest = $existing.digest -replace '^sha256:', ''
        if ($remoteSize -eq $info.size -and $remoteDigest -eq $info.sha256) {
            Log "  $name 已存在且校验通过，跳过"
            $needUpload = $false
        } else {
            Log "  $name 已存在但不符（size: $remoteSize vs $($info.size), digest: $remoteDigest vs $($info.sha256)），删除后重传"
            try {
                Api-Json 'DELETE' "https://api.github.com/repos/$OwnerRepo/releases/assets/$($existing.id)" @{}
            } catch { Log "  [警告] 删除旧资产失败：$_" }
        }
    }
    if ($needUpload) {
        Log "  上传 $name ..."
        Invoke-Retry -Desc "上传 $name" -MaxAttempts $MaxAttempts -Action {
            $tmp = Join-Path $env:TEMP "v5_upload_$(Get-Random).json"
            try {
                $httpCode = (curl.exe -s -o $tmp -w '%{http_code}' -X POST `
                    -H "Authorization: token $env:GITHUB_TOKEN" `
                    -H 'Accept: application/vnd.github.v3+json' `
                    -H 'User-Agent: v5-publish-tool' `
                    -H 'Content-Type: application/vnd.android.package-archive' `
                    --data-binary "@$($info.path)" `
                    $uploadUrl 2>$null | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) { throw "__TRANSIENT__ curl exit $LASTEXITCODE" }
                if (-not $httpCode) { $httpCode = '000' }
                $body = Get-Content $tmp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ([int]$httpCode -ge 400) { throw "HTTP $httpCode : $body" }
            } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
        Log "  $name 上传完成"
    }
}

# 最终回读核对
Log '  最终回读核对...'
$release = Api-Get "https://api.github.com/repos/$OwnerRepo/releases/$releaseId"
$allOk = $true
foreach ($name in $apkFiles) {
    $info = $apkInfo[$name]
    $asset = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $asset) { Log "  [错误] $name 缺失"; $allOk = $false; continue }
    $remoteSize = $asset.size
    $remoteDigest = $asset.digest -replace '^sha256:', ''
    if ($remoteSize -ne $info.size -or $remoteDigest -ne $info.sha256) {
        Log "  [错误] $name 校验失败：size $remoteSize vs $($info.size), digest $remoteDigest vs $($info.sha256)"
        $allOk = $false
    }
}
if (-not $allOk) { throw '资产校验未通过，请检查日志后重试。' }
Log '  全部资产校验通过'

# 步骤 5：更新 update.json
Log '步骤 5：更新 update.json'
# 结构必须与 lib/core/updater/models/app_update_manifest.dart 对齐：
#   顶层 schemaVersion/updatedAt/minSupported/assets；latest.{version,notes,level,publishedAt,downloads}
#   downloads.<平台>.{url,mirrors,sha256,sizeBytes}
# 必须保留泛化 'android' 键（老客户端只查它），同时写 ABI 细分键供新客户端优先匹配。
$updateJsonPath = Join-Path $repoRoot 'update.json'
$prev = $null
if (Test-Path $updateJsonPath) {
    $prev = Get-Content $updateJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Get-Field($obj, $name) {
    if ($null -ne $obj -and $null -ne $obj.PSObject) {
        $prop = $obj.PSObject.Properties[$name]
        if ($prop) { return $prop.Value }
    }
    return $null
}

$prevLatest = Get-Field $prev 'latest'
$notes = $Notes
if (-not $notes) { $notes = Get-Field $prevLatest 'notes' }
$level = Get-Field $prevLatest 'level'
$publishedAt = Get-Field $prevLatest 'publishedAt'

# APK 文件名 -> 清单 downloads 键（含泛化 android 兜底）
$abiKeys = [ordered]@{
    'app-arm64-v8a-release.apk'   = 'android-arm64-v8a'
    'app-armeabi-v7a-release.apk' = 'android-armeabi-v7a'
    'app-x86_64-release.apk'      = 'android-x86_64'
    'app-release.apk'             = 'android'
}
$downloads = [ordered]@{}
foreach ($key in $abiKeys.Keys) {
    $info = $apkInfo[$key]
    $url = "https://github.com/$OwnerRepo/releases/download/$tag/$key"
    $mirrorUrls = @()
    if (-not [string]::IsNullOrWhiteSpace($AltBase)) {
        $mirrorUrls += ($AltBase.TrimEnd('/') + "/$tag/$key")
    }
    foreach ($prefix in $MirrorPrefixes) { $mirrorUrls += "$prefix/$url" }
    $downloads[$abiKeys[$key]] = [ordered]@{
        url       = $url
        mirrors   = $mirrorUrls
        sha256    = $info.sha256
        sizeBytes = $info.size
    }
}

$latestObj = [ordered]@{ version = $Version }
if ($notes -and $notes.Count -gt 0) { $latestObj['notes'] = @($notes) }
if ($level) { $latestObj['level'] = $level }
if ($publishedAt) { $latestObj['publishedAt'] = $publishedAt }
$latestObj['downloads'] = $downloads

$out = [ordered]@{}
$comment = Get-Field $prev '_comment'
if ($comment) { $out['_comment'] = $comment }
$out['schemaVersion'] = 1
$out['updatedAt'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$minSupported = Get-Field $prev 'minSupported'
if ($minSupported) { $out['minSupported'] = $minSupported }
$assets = Get-Field $prev 'assets'
if ($assets) { $out['assets'] = $assets }
$out['latest'] = $latestObj

# 中文转 \uXXXX 再还原，避免 UTF-8 BOM 问题
$jsonText = $out | ConvertTo-Json -Depth 10
$jsonText = [System.Text.RegularExpressions.Regex]::Replace($jsonText, '\\u([0-9a-fA-F]{4})', { param($m) [char][int]"0x$($m.Groups[1].Value)" })
[System.IO.File]::WriteAllText($updateJsonPath, $jsonText, [System.Text.UTF8Encoding]::new($false))
Log "  update.json 已重写"

# 步骤 6：提交并推送 update.json
if (-not $SkipManifestCommit) {
    Log '步骤 6：提交并推送 update.json'
    & git add -- update.json
    if ($LASTEXITCODE -ne 0) { throw "git add 失败" }
    $commitMsg = "V${Version}: 更新发布清单（version/url/sha256/sizeBytes/mirrors）`n"
    $msgFile = Join-Path $env:TEMP "v5_commit_$(Get-Random).txt"
    [System.IO.File]::WriteAllText($msgFile, $commitMsg, [System.Text.UTF8Encoding]::new($false))
    & git commit -F $msgFile
    Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) { throw "git commit 失败" }
    # 同步骤 2：git push 走 API 通道，避免在企业网限速下挂死。
    & powershell -NoProfile -ExecutionPolicy Bypass -File $pushApiScript -Branch $Branch
    if ($LASTEXITCODE -ne 0) { throw 'API 推送 update.json 失败' }
} else {
    Log '  跳过 update.json 提交（-SkipManifestCommit）'
}

# 步骤 7：CDN 刷新
if (-not $SkipPurge) {
    Log '步骤 7：刷新 jsDelivr 缓存'
    $purgeUrl = "https://purge.jsdelivr.net/gh/$OwnerRepo@$Branch/update.json"
    try {
        Invoke-Retry -Desc 'purge jsDelivr' -MaxAttempts 3 -Action {
            $resp = Invoke-WebRequest -Uri $purgeUrl -UseBasicParsing -TimeoutSec 30
            if ($resp.StatusCode -ne 200) { throw "__TRANSIENT__ HTTP $($resp.StatusCode)" }
        }
        Log "  已通知 purge.jsdelivr.net"
    } catch { Log "  [警告] CDN 刷新失败：$_" }
} else {
    Log '  跳过 CDN 刷新（-SkipPurge）'
}

Log '=== 发布完成 ==='
Log "Release: https://github.com/$OwnerRepo/releases/tag/$tag"
Log "update.json: https://gcore.jsdelivr.net/gh/$OwnerRepo@$Branch/update.json"
