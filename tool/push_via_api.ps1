# 任务管家「走 API 推送」（v5/v6 通用：仓库名从 origin 解析，不写死）：git push 被限速时的替代通道
#
# 存在的理由：
#   本网络（深信服）放行 TCP 握手，却把 git 智能 HTTP 的**写通道**限速到
#   <1KB/s，git push 报 "Operation too slow. Less than 1000 bytes/sec"，
#   POST 上去的 pack 永远传不完；而 api.github.com 实测 750ms 往返稳定可用
#   （发布工具上传 140MB APK 资产走的就是这条链路）。
#   因此把「提交」改由 REST API 完成：blob → tree → commit → 移动 ref。
#   只上传本次提交改动的文件，天然快进。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tool\push_via_api.ps1
#   powershell -ExecutionPolicy Bypass -File tool\push_via_api.ps1 -Branch main -Tag v5.5.25
#   powershell -ExecutionPolicy Bypass -File tool\push_via_api.ps1 -Force   # 远端已分叉时强制覆盖
#
# ⚠️ 推一个**全新的空仓库**时，GitHub 会让 git data API 全部返回
#    409 "Git Repository is empty" —— blob / tree / commit 无一例外，
#    本脚本会在上传第一个 blob 时就撞上。绕法：先用 Contents API 造一个提交
#    把仓库「激活」（PUT /repos/<owner>/<repo>/contents/.init，content 传 base64）。
#    激活之后本脚本即可直接推根提交：它会自动 force 覆盖那个占位提交，
#    占位提交随即变成悬空对象、由 GitHub 回收，不会留在历史里。
#
# 让「本地与远端 sha 逐位相同」的三个关键点（少一个就会分叉，
# 分叉后每次推送都要先 fetch，而 fetch 同样被这条烂链路卡住）：
#   1. blob 内容必须用 git 的**规范化对象字节**。本仓库 core.autocrlf=true，
#      检出到工作区的文件是 CRLF，而 git 入库的 blob 是 LF；直接读文件上传，
#      blob sha 会与本地不同，进而 tree / commit sha 全不同。
#      故改用 `git cat-file blob <sha>` 取原始对象字节。
#   2. 提交信息必须**逐字节**一致（git 的 commit 对象以单个 \n 结尾）。
#      从 `git cat-file commit` 里按首个空行切出 message，原样发送，不能 TrimEnd。
#   3. 时间戳 GitHub 会**归一化成 UTC**（本地 +08:00 会被改写成 +0000），
#      故发送前先把 author/committer 时间转成 UTC，本地重算时也用 UTC。
#   推送成功后脚本会用同样的内容在本地重建该提交（sha 逐位一致），
#   并把本地分支指向它，保证本地与远端始终同号。
#
# 认证：读取 tool\github_token.txt（需 repo 权限的 PAT），不落代码。
[CmdletBinding()]
param(
    [string]$Branch = 'main',
    [string]$Tag = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Log($message) { Write-Host $message }
function Warn($message) { Write-Host $message -ForegroundColor Yellow }

function ToJsonStr($value) {
    ConvertTo-Json -InputObject ([string]$value) -Compress
}

$script:token = ''
$script:ownerRepo = ''

function Invoke-GitHubApi {
    param([string]$Method, [string]$Path, [string]$Json = '')

    $headers = @{
        Authorization = "Bearer $script:token"
        'User-Agent'  = 'taskmaster-push'
        Accept        = 'application/vnd.github+json'
    }
    $uri = "https://api.github.com/repos/$script:ownerRepo/$Path"
    if ([string]::IsNullOrEmpty($Json)) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -TimeoutSec 60
    }
    # 必须显式转 UTF-8 字节：PS 5.1 直接传字符串会按 ISO-8859-1 编码，
    # 中文提交信息到 GitHub 侧就是乱码（发布工具踩过同一个坑）。
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 180
}

# 取 git 子命令的原始 stdout 字节。PS 的命令输出会把二进制当文本处理，
# 所以必须用 .NET 进程 + 原始流，否则 cat-file / cat-file blob 的内容会被改写。
function Invoke-GitRawBytes {
    param([string]$Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.WorkingDirectory = $repoRoot
    $psi.Arguments = $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    $proc.StandardOutput.BaseStream.CopyTo($ms)
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "git $Arguments 退出码 $($proc.ExitCode)" }
    return $ms.ToArray()
}

# git 对象里的规范化 blob 内容（本地 blob sha == 这就是内容）。
function Get-GitBlobBase64 {
    param([string]$Sha)
    $bytes = Invoke-GitRawBytes "cat-file blob $Sha"
    return [Convert]::ToBase64String($bytes)
}

# 从 commit 对象里切出精确的 message 字节（首个空行之后的部分，逐字节不加工）。
function Get-CommitMessageBytes {
    param([string]$Sha)
    $bytes = Invoke-GitRawBytes "cat-file commit $Sha"
    $idx = -1
    for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
        if ($bytes[$i] -eq 10 -and $bytes[$i + 1] -eq 10) { $idx = $i; break }
    }
    if ($idx -lt 0) { throw "无法解析提交对象 $Sha" }
    return , [byte[]]($bytes[($idx + 2)..($bytes.Length - 1)])
}

function Convert-ToUtc([string]$Iso) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $dt = [DateTimeOffset]::Parse($Iso, $inv).UtcDateTime
    return $dt.ToString('yyyy-MM-ddTHH:mm:ss', $inv) + '+00:00'
}

# ── 0. 读 token（常见根因就是它缺失，提示要明确）────────────────────────────
$tokenPath = Join-Path $PSScriptRoot 'github_token.txt'
if (-not (Test-Path $tokenPath)) {
    throw "缺少 $tokenPath。请到 GitHub 生成带 repo 权限的 PAT 并写入该文件（不要提交到仓库）。"
}
$script:token = (Get-Content $tokenPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($script:token)) {
    throw "$tokenPath 为空。请写入有效的 GitHub PAT。"
}

# ── 1. 从 origin 解析 owner/repo，避免把仓库名写死在脚本里 ──────────────────
$url = (& git -C $repoRoot remote get-url origin).Trim()
$m = [regex]::Match($url, 'github\.com[:/](?<o>[^/]+)/(?<r>[^/]+?)(\.git)?$')
if (-not $m.Success) { throw "无法从 origin 解析 owner/repo：$url" }
$script:ownerRepo = "$($m.Groups['o'].Value)/$($m.Groups['r'].Value)"
Log "仓库：$script:ownerRepo  分支：$Branch"

# ── 2. 本地待推送的提交（只支持「当前 HEAD 单提交快进」这一种情况）──────────
$headSha = (& git -C $repoRoot rev-parse HEAD).Trim()

# 根提交（没有父提交）也要能推：仓库刚建好、第一次推初始提交正是这个情况。
# 原本直接 `rev-parse HEAD^1` 在根提交上会报错退出，导致新仓库无法用本脚本起头。
$hasParent = $true
$parentSha = ''
try {
    $parentSha = (& git -C $repoRoot rev-parse --verify "$headSha^1").Trim()
} catch {
    $hasParent = $false
}

# git 的空树 sha：根提交用它当 base_tree（远端是空仓库，没有可复用的树）。
$EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
if ($hasParent) {
    # 父提交的 tree 是内容寻址的，本地/远端同一个 sha；直接取本地的，省一次 API 调用。
    $baseTree = (& git -C $repoRoot log -1 --format=%T $parentSha).Trim()
} else {
    $baseTree = $EMPTY_TREE
    Log '本次是根提交（没有父提交）→ 按初始提交处理'
}
$localTree = (& git -C $repoRoot log -1 --format=%T $headSha).Trim()

# message 必须逐字节一致：从 commit 对象里切，不要用 `git log --format=%B`（会多带换行）。
$msgBytes = Get-CommitMessageBytes $headSha
$message = [System.Text.Encoding]::UTF8.GetString($msgBytes)

$authorName = (& git -C $repoRoot log -1 --format=%an $headSha).Trim()
$authorEmail = (& git -C $repoRoot log -1 --format=%ae $headSha).Trim()
$committerName = (& git -C $repoRoot log -1 --format=%cn $headSha).Trim()
$committerEmail = (& git -C $repoRoot log -1 --format=%ce $headSha).Trim()
# GitHub 会把时间戳归一化成 UTC，故先本地转好，避免它替我们改。
$authorDate = Convert-ToUtc ((& git -C $repoRoot log -1 --format=%aI $headSha).Trim())
$committerDate = Convert-ToUtc ((& git -C $repoRoot log -1 --format=%cI $headSha).Trim())

# 空仓库上还没有这个分支，GET 会 404 —— 那正是初始提交的正常情况，不能当错误抛出。
$remoteSha = ''
try {
    $remoteRef = Invoke-GitHubApi -Method GET -Path "git/ref/heads/$Branch"
    $remoteSha = $remoteRef.object.sha
} catch {
    Warn "远端还没有 $Branch 分支（空仓库）→ 本次按「创建分支」处理"
}
if ($remoteSha) { Log "远端 $Branch = $remoteSha" } else { Log "远端 $Branch = （尚不存在）" }
Log "本地 HEAD     = $headSha"

if ($remoteSha -and $remoteSha -eq $headSha) {
    Log '远端已包含该提交，分支无需推送。'
    # 分支虽然同步，仍可能需要补推 tag（发版时常见：分支早已推好，tag 是新建的）。
    if (-not [string]::IsNullOrWhiteSpace($Tag)) {
        $tagSha = ToJsonStr $headSha
        try {
            $createTagJson = '{"ref":"refs/tags/' + $Tag + '","sha":' + $tagSha + '}'
            Invoke-GitHubApi -Method POST -Path 'git/refs' -Json $createTagJson | Out-Null
            Log "已创建 tag $Tag（轻量，指向 $headSha）"
        } catch {
            $updateTagJson = '{"sha":' + $tagSha + ',"force":true}'
            Invoke-GitHubApi -Method PATCH -Path "git/refs/tags/$Tag" -Json $updateTagJson | Out-Null
            Log "已更新 tag $Tag -> $headSha"
        }
        $sha = $headSha
        # 本地未必有这个对象：走 API 建出来的 commit 是远端独有的，而 git 协议
        # 在部分网络下被封、fetch 不了。直接 update-ref 会让 git 以
        # "nonexistent object" 失败，把整条发布流程打断（远端其实已经好了）。
        & git -C $repoRoot cat-file -e "$sha^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            & git -C $repoRoot update-ref "refs/tags/$Tag" $sha
        } else {
            Log "本地还没有 $($sha.Substring(0, 7))，跳过本地 tag 更新（远端已就绪）"
        }
    }
    exit 0
}
# 远端不存在分支（初始提交）或本地是根提交时，都没有「必须等于父提交」这回事。
if ($remoteSha -and $hasParent -and $remoteSha -ne $parentSha) {
    if (-not $Force) {
        throw "远端 $Branch（$remoteSha）不是本地 HEAD 的父提交（$parentSha）。" +
              '本工具只做快进推送；需要先对齐远端，或用 -Force 明确覆盖。'
    }
    Warn "警告：-Force 已跳过非快进校验（远端 $remoteSha ≠ 本地父提交 $parentSha）"
}

# ── 3. 逐个上传本次改动文件（其余文件复用 base_tree，不必重传）──────────────
if ($hasParent) {
    $rawChanged = & git -C $repoRoot -c core.quotepath=false diff-tree `
        -r --no-commit-id --name-status $parentSha $headSha
} else {
    # 根提交没有父提交可以 diff，改成列出整棵树；补成 diff-tree 的
    # 「状态<TAB>路径」格式，下面的循环就不用为它分叉。
    $rawChanged = & git -C $repoRoot -c core.quotepath=false ls-tree -r --name-only $headSha |
        ForEach-Object { "A`t$_" }
}
$entries = @()
$blobCount = 0
foreach ($line in $rawChanged) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split "`t"
    $status = $parts[0]
    # 重命名会带两个路径（R100<TAB>旧<TAB>新），按「删旧 + 增新」处理。
    $paths = @()
    if ($parts.Length -ge 3) { $paths = @($parts[1], $parts[2]) } else { $paths = @($parts[1]) }
    $isRename = ($status -like 'R*') -and ($parts.Length -ge 3)
    if ($status -eq 'D') {
        $entries += @{ path = $paths[0]; mode = $null; sha = $null }
        Log "  删除 $($paths[0])"
        continue
    }
    if ($isRename) {
        $entries += @{ path = $paths[0]; mode = $null; sha = $null }
    }
    $target = $paths[-1]
    $lsLine = ((& git -C $repoRoot ls-tree $headSha -- $target) -split '\s+')
    $mode = $lsLine[0]
    $localBlobSha = $lsLine[2]
    $content = Get-GitBlobBase64 $localBlobSha
    $blobJson = '{"content":' + (ToJsonStr $content) + ',"encoding":"base64"}'
    $blob = Invoke-GitHubApi -Method POST -Path 'git/blobs' -Json $blobJson
    if ($blob.sha -ne $localBlobSha) {
        throw "blob 内容不一致：$target 本地 $localBlobSha / GitHub $($blob.sha)。" +
              '若出现此错，说明取内容的方式被 CRLF 等转换污染了。'
    }
    $entries += @{ path = $target; mode = $mode; sha = $blob.sha }
    $blobCount++
    Log "  上传 $target（$mode）-> $($blob.sha.Substring(0, 8))"
}
if ($entries.Count -eq 0) { throw '本次提交没有任何文件改动，无需推送。' }

$treeItems = ($entries | ForEach-Object {
        $shaJson = if ($null -eq $_.sha) { 'null' } else { '"' + $_.sha + '"' }
        # 删除项（sha=null）**也必须带有效的 mode**：传 "mode":null 会被 GitHub 拒绝
        # （实测 422 "Must supply a valid tree.mode"）。本仓库要删的都是普通文件，
        # 故取 100644；若将来要删子模块(160000)/symlink(120000)，需改为从父 tree 查原 mode。
        $modeJson = if ($null -eq $_.mode) { '"100644"' } else { '"' + $_.mode + '"' }
        # 手拼 JSON：PS 5.1 的 ConvertTo-Json 会把单元素数组折叠成对象，
        # 而 git/trees 的 tree 字段必须是数组，一旦折叠就会被 GitHub 拒绝。
        '{"path":' + (ToJsonStr $_.path) + ',"mode":' + $modeJson +
        ',"type":"blob","sha":' + $shaJson + '}'
    }) -join ','
$treeJson = '{"base_tree":"' + $baseTree + '","tree":[' + $treeItems + ']}'
$tree = Invoke-GitHubApi -Method POST -Path 'git/trees' -Json $treeJson
Log "新 tree = $($tree.sha)"
if ($tree.sha -ne $localTree) {
    throw "tree 不一致：本地 $localTree / GitHub $($tree.sha)。内容已偏离，已中止以免写坏远端。"
}

$identityJson = ',"author":{"name":' + (ToJsonStr $authorName) + ',"email":' + (ToJsonStr $authorEmail) +
',"date":' + (ToJsonStr $authorDate) + '},"committer":{"name":' + (ToJsonStr $committerName) +
',"email":' + (ToJsonStr $committerEmail) + ',"date":' + (ToJsonStr $committerDate) + '}'
$parentsJson = if ($hasParent) { '[' + (ToJsonStr $parentSha) + ']' } else { '[]' }
$commitJson = '{"message":' + (ToJsonStr $message) + ',"tree":' + (ToJsonStr $tree.sha) +
    ',"parents":' + $parentsJson + $identityJson + '}'
$newCommit = Invoke-GitHubApi -Method POST -Path 'git/commits' -Json $commitJson
Log "新 commit = $($newCommit.sha)"

# ── 4. 移动分支 ref（默认 force=false：不接受非快进）────────────────────────
if ($remoteSha) {
    # 初始推送（本地是根提交）必须 force：远端那个提交只是用来把空仓库激活的占位，
    # 与本地历史毫无关系，结构上不可能构成快进。
    $forceJson = if ($Force -or -not $hasParent) { 'true' } else { 'false' }
    $refJson = '{"sha":' + (ToJsonStr $newCommit.sha) + ',"force":' + $forceJson + '}'
    Invoke-GitHubApi -Method PATCH -Path "git/refs/heads/$Branch" -Json $refJson | Out-Null
} else {
    # 分支还不存在：这不是「移动 ref」，而是「创建 ref」（git/refs 要求带完整 ref 名）。
    $refJson = '{"ref":"refs/heads/' + $Branch + '","sha":' + (ToJsonStr $newCommit.sha) + '}'
    Invoke-GitHubApi -Method POST -Path 'git/refs' -Json $refJson | Out-Null
    Log "已创建 refs/heads/$Branch"
}

# 回读校验：确认远端 ref 真的指向新提交，而不是「请求成功了但没生效」。
$verify = Invoke-GitHubApi -Method GET -Path "git/ref/heads/$Branch"
if ($verify.object.sha -ne $newCommit.sha) {
    throw "回读校验失败：远端 $Branch 仍是 $($verify.object.sha)，期望 $($newCommit.sha)"
}
Log "已更新 refs/heads/$Branch -> $($newCommit.sha)"

# ── 5. 可选：同步创建/更新 tag（发版时 tag 也常被 git push 卡住）────────────
if (-not [string]::IsNullOrWhiteSpace($Tag)) {
    $tagSha = ToJsonStr $newCommit.sha
    try {
        $createTagJson = '{"ref":"refs/tags/' + $Tag + '","sha":' + $tagSha + '}'
        Invoke-GitHubApi -Method POST -Path 'git/refs' -Json $createTagJson | Out-Null
        Log "已创建 tag $Tag（轻量，指向 $($newCommit.sha)）"
    } catch {
        $updateTagJson = '{"sha":' + $tagSha + ',"force":true}'
        Invoke-GitHubApi -Method PATCH -Path "git/refs/tags/$Tag" -Json $updateTagJson | Out-Null
        Log "已更新 tag $Tag -> $($newCommit.sha)"
    }
    $sha = $newCommit.sha
        # 本地未必有这个对象：走 API 建出来的 commit 是远端独有的，而 git 协议
        # 在部分网络下被封、fetch 不了。直接 update-ref 会让 git 以
        # "nonexistent object" 失败，把整条发布流程打断（远端其实已经好了）。
        & git -C $repoRoot cat-file -e "$sha^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            & git -C $repoRoot update-ref "refs/tags/$Tag" $sha
        } else {
            Log "本地还没有 $($sha.Substring(0, 7))，跳过本地 tag 更新（远端已就绪）"
        }
}

# ── 6. 本地对齐：用同样内容在本地重建该提交，使本地分支与远端同号 ───────────
# 本地提交的时间戳带 +08:00，GitHub 归一化成 +0000，两者 sha 必然不同；
# 用 UTC 时间戳在本地重算出的提交，与 GitHub 生成的**逐位一致**。
$tmpMsg = Join-Path ([System.IO.Path]::GetTempPath()) ("taskmaster-push-" + [Guid]::NewGuid().ToString('N') + ".txt")
[System.IO.File]::WriteAllBytes($tmpMsg, $msgBytes)
try {
    $env:GIT_AUTHOR_NAME = $authorName
    $env:GIT_AUTHOR_EMAIL = $authorEmail
    $env:GIT_AUTHOR_DATE = $authorDate
    $env:GIT_COMMITTER_NAME = $committerName
    $env:GIT_COMMITTER_EMAIL = $committerEmail
    $env:GIT_COMMITTER_DATE = $committerDate
    $ctArgs = @('commit-tree', $tree.sha)
    if ($hasParent) { $ctArgs += @('-p', $parentSha) }
    $ctArgs += @('-F', $tmpMsg)
    $localSha = (& git -C $repoRoot @ctArgs).Trim()
} finally {
    Remove-Item $tmpMsg -Force -ErrorAction SilentlyContinue
}

if ($localSha -ne $newCommit.sha) {
    Warn "本地重算提交 sha（$localSha）与远端（$($newCommit.sha)）不一致：本地与远端将分叉。"
} else {
    $headRef = ''
    try { $headRef = (& git -C $repoRoot symbolic-ref -q HEAD).Trim() } catch { $headRef = '' }
    if ($headRef -eq "refs/heads/$Branch") {
        & git -C $repoRoot update-ref "refs/heads/$Branch" $newCommit.sha
        Log "本地 $Branch 已对齐到 $($newCommit.sha)（内容不变，仅时间戳规范化）"
    } else {
        Warn "HEAD 不在 refs/heads/$Branch 上（$headRef），跳过本地对齐。"
    }
}

Log "完成：$Branch = $($newCommit.sha)（上传 $blobCount 个 blob）"
