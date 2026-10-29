# 发一个插件：打包 → 版本守卫 → 校验 → 提交 → 推送 → 刷缓存
#
# 为什么要有它：这套流程原来四步全靠手打（make_demo_plugin.py / commit /
# push_via_api.ps1 / purge_jsdelivr.ps1）。漏一步的后果不是报错，而是"看起来
# 发了、用户那边没有"—— 我第一次发的时候就漏了刷缓存，被 CDN 缓存坑了一轮。
#
# 里面有一条硬守卫：**同一个版本号下内容变了要拒绝**。
# 包路径里带版本号（<id>_v<version>.zip），改了 index.html 却忘了 bump version
# 时，路径不变、sha 变了 —— 线上索引里的 sha 和线上文件对不上，装的人必失败，
# 而且报出来像网络问题。这种错一定要在本地拦住。
#
# 用法（在项目根目录）：
#   powershell -ExecutionPolicy Bypass -File tool\publish_plugin.ps1
#   powershell -ExecutionPolicy Bypass -File tool\publish_plugin.ps1 -PluginId energy_currency
#   powershell -ExecutionPolicy Bypass -File tool\publish_plugin.ps1 -DryRun     # 只检查不推送
[CmdletBinding()]
param(
    # 只发某一个插件（不给就是全量重打包，索引里所有有变化的都会进这次提交）
    [string]$PluginId = '',
    # 提交信息。不给就用默认话术，仍然写清"为什么"
    [string]$Message = '',
    # 只做打包 + 守卫 + 校验，不提交/不推送/不刷缓存
    [switch]$DryRun,
    # 放行"版本没变但包变了"。只在**打包器本身改了**（比如行尾归一化）时用，
    # 而且要在提交信息里写清原因 —— 否则就是把守卫关掉了。
    [switch]$AllowRepack
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# 读 git 输出时要临时把控制台编码切到 UTF-8：PS 5.1 默认按 GBK 解，`git show`
# 出来的索引 JSON 会变成乱码，ConvertFrom-Json 直接崩（实测踩过）。
# **只在这一次调用前后切**——全局改会把整个脚本的中文输出写成 UTF-8，
# 而这套环境的上层是按 GBK 读的，反而全乱。
function Get-GitText([string]$GitArgs) {
    $previous = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        return (& git $GitArgs.Split(' ')) -join "`n"
    } finally {
        [Console]::OutputEncoding = $previous
    }
}
Push-Location $repoRoot
try {
    Write-Host '── 1/5 打包' -ForegroundColor Cyan
    & python tool/make_demo_plugin.py
    if ($LASTEXITCODE -ne 0) { throw '打包失败（make_demo_plugin.py 退出码非 0）' }

    Write-Host '── 2/5 版本守卫' -ForegroundColor Cyan
    $indexPath = 'assets/plugins/index.json'
    $newIndex = Get-Content $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $oldIndex = $null
    try {
        $oldRaw = Get-GitText "show HEAD:$indexPath"
        if ($oldRaw) { $oldIndex = $oldRaw | ConvertFrom-Json }
    } catch {
        # 第一次发插件时 HEAD 里还没有索引，正常
        Write-Host '  （HEAD 里没有旧索引，跳过守卫）'
    }

    $violations = @()
    foreach ($entry in $newIndex.plugins) {
        if ($PluginId -and $entry.id -ne $PluginId) { continue }
        if (-not $oldIndex) { continue }
        $old = $oldIndex.plugins | Where-Object { $_.id -eq $entry.id }
        if (-not $old) { continue }   # 新插件，没有可比的老版本
        if ($old.version -ne $entry.version) { continue }   # 版本变了，正常
        if ($old.package.sha256 -ne $entry.package.sha256) {
            $violations += "「$($entry.id)」版本仍是 $($entry.version)，但包内容变了（sha 不一致）"
        }
    }
    if ($violations.Count -gt 0) {
        Write-Host ''
        foreach ($v in $violations) { Write-Host "  [!] $v" -ForegroundColor Red }
        if (-not $AllowRepack) {
            throw '版本号没递增就改了内容。请先改 plugin.json 里的 version 再发；' +
                  '如果确实是打包器变了（不是内容变了），加 -AllowRepack 并在提交信息里写明原因。'
        }
        Write-Host '  -AllowRepack 已放行：请确认是打包器变化，不是内容变化' -ForegroundColor Yellow
    } else {
        Write-Host '  版本守卫通过'
    }

    Write-Host '── 3/5 校验' -ForegroundColor Cyan
    # 代理变量会劫持回环 WebSocket，导致 flutter_tester 起不来，报一句
    # "Invalid WebSocket upgrade request"，看着像测试代码坏了。必须先清。
    foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy')) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $env:NO_PROXY = '127.0.0.1,localhost'
    & flutter test test/app/asset_index_test.dart
    if ($LASTEXITCODE -ne 0) { throw '资产一致性测试没过，已中止' }

    $packagePaths = @($newIndex.plugins | ForEach-Object { $_.package.path })
    $purgeTargets = (@($indexPath) + $packagePaths) -join ','
    $commitMessage = if ($Message) {
        $Message
    } else {
        "发插件：$((($newIndex.plugins | Where-Object { -not $PluginId -or $_.id -eq $PluginId }) | ForEach-Object { "$($_.id) v$($_.version)" }) -join '、')"
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host '（DryRun）本应做的事：' -ForegroundColor Yellow
        Write-Host "  提交：$commitMessage"
        Write-Host "  推送：tool\push_via_api.ps1"
        Write-Host "  刷缓存：$purgeTargets"
        return
    }

    Write-Host '── 4/5 提交并推送' -ForegroundColor Cyan
    & git add -A
    if ($LASTEXITCODE -ne 0) { throw 'git add 失败' }
    $staged = & git diff --cached --name-only
    if (-not $staged) {
        Write-Host '  没有改动，无需提交（可能版本号没变、内容也没变）' -ForegroundColor Yellow
    } else {
        & git commit -m $commitMessage
        if ($LASTEXITCODE -ne 0) { throw 'git commit 失败' }
        & (Join-Path $PSScriptRoot 'push_via_api.ps1')
        if ($LASTEXITCODE -ne 0) { throw '推送失败（网络抖动重跑即可，脚本是幂等的）' }
    }

    Write-Host '── 5/5 刷 CDN 缓存' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'purge_jsdelivr.ps1') -Paths $purgeTargets

    Write-Host ''
    Write-Host '发完了。用户下次打开插件市场就能看到（索引是运行时拉的，不用发版）。' -ForegroundColor Green
} finally {
    Pop-Location
}
