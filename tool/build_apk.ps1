# 任务管家 release APK 构建脚本（只构建 + 出摘要，不发布）
#
# 存在的理由：`flutter build apk --release` 有几个「必须记得加」的参数和
# 「必须记得做」的收尾动作，手打很容易漏：
#
#   1. --split-per-abi         fat APK 约 62MB，分 ABI 后每个仅 21~25MB。
#                              自更新是用户流量，没必要让他们下 3 倍体积。
#   2. sha256 + sizeBytes      写 update.json 必需，手工算容易抄错。
#
# 与 publish_release.ps1 的分工：
#   本脚本只产包 + 出 release-manifest.txt，不动 update.json、也不发布。
#   要发版直接用 tool\publish_release.ps1（它内部会构建、传资产、写清单、刷缓存）。
#   这里只用于先看看包多大、摘要多少，或排障时单独重跑构建。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tool\build_apk.ps1
#   powershell -ExecutionPolicy Bypass -File tool\build_apk.ps1 -Flavor fat
#   powershell -ExecutionPolicy Bypass -File tool\build_apk.ps1 -Flavor both   # 过渡期推荐
#   powershell -ExecutionPolicy Bypass -File tool\build_apk.ps1 -SkipTests
#
# Flavor 三选一：
#   split  只出分 ABI 包（每个 21~25MB）—— 新客户端最优
#   fat    只出单包全 ABI（约 62MB）
#   both   两者都出，并生成**含泛化 android 回落键**的完整 JSON —— 过渡期用
#
# 产出：
#   build\app\outputs\flutter-apk\app-<abi>-release.apk     （split / both）
#   build\app\outputs\flutter-apk\app-release.apk           （fat / both）
#   build\app\outputs\release-manifest.txt                  sha256 / 大小 / 可直接粘贴的 JSON

[CmdletBinding()]
param(
    # split = 每个 ABI 一个包（默认，推荐分发）；fat = 单包全 ABI（体积大）；
    # both  = 两者都构建，并生成**含泛化 android 回落键**的完整 JSON 片段。
    #
    # 为什么需要 both：客户端 AppRelease.resolveTarget 的匹配顺序是
    # `<platform>-<abi>` → `<platform>`。已经装了老版本的用户，代码里没有 ABI
    # 逻辑，只会查泛化的 `android` 键 —— 如果只发布 split 键，老用户会
    # **静默收不到更新（不报错）**。过渡期必须同时提供一个泛化 android 键
    # （指向 fat 包）。both 就是把这个过渡态一次做出来。
    [ValidateSet('split', 'fat', 'both')]
    [string]$Flavor = 'split',

    # 跳过 flutter test。默认会跑，因为「签名错了」这类问题只有构建才暴露，
    # 而「逻辑错了」应该在上传前拦住。
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$apkDir = Join-Path $repoRoot 'build\app\outputs\flutter-apk'
$manifestPath = Join-Path $repoRoot 'build\app\outputs\release-manifest.txt'

function Write-Step($text) {
    Write-Host ''
    Write-Host "=== $text ===" -ForegroundColor Cyan
}

Write-Step 'release APK build'

# ---- 前置检查 ----------------------------------------------------------------

$keyProps = Join-Path $repoRoot 'android\key.properties'
if (-not (Test-Path -LiteralPath $keyProps)) {
    Write-Host 'android/key.properties 不存在 —— 构建会回落到 DEBUG key。' -ForegroundColor Yellow
    Write-Host '那不能用于分发（签名不匹配会导致用户无法覆盖安装）。' -ForegroundColor Yellow
    Write-Host '先跑 tool\setup_android_keystore_auto.ps1 生成，或在下面确认继续。' -ForegroundColor Yellow
    $answer = Read-Host '仍要继续？(y/N)'
    if ($answer -ne 'y') { throw 'Aborted: 缺少 release 签名配置。' }
} else {
    # 校验 storeFile 的转义。java.util.Properties.load() 把反斜杠当转义符，
    # 单反斜杠会被静默读坏（'\t' 变 TAB），构建报「Keystore file ... not found」。
    # 详见 skill windows-agent-env-workarounds 坑 12。
    $storeLine = (Get-Content -LiteralPath $keyProps |
        Where-Object { $_ -match '^\s*storeFile\s*=' } | Select-Object -First 1)
    if ($storeLine) {
        $storeValue = ($storeLine -split '=', 2)[1]
        if ($storeValue -match "`t") {
            throw ("key.properties 的 storeFile 含 TAB —— 路径用了单反斜杠。" +
                   "请改成双反斜杠，例如 storeFile=D:\\Dev\\keystore\\taskmaster-release.jks")
        }
        # 把 \\ 还原成 \ 后判断文件是否存在
        $resolved = $storeValue -replace '\\\\', '\'
        if (-not (Test-Path -LiteralPath $resolved)) {
            throw "key.properties 指向的密钥库不存在：$resolved"
        }
        Write-Host "keystore : $resolved" -ForegroundColor Green
    }
}

# ---- 测试 --------------------------------------------------------------------

if (-not $SkipTests) {
    Write-Step 'flutter test'
    & flutter test
    if ($LASTEXITCODE -ne 0) { throw "测试未通过（exit $LASTEXITCODE），已中止构建。" }
} else {
    Write-Host '(已跳过测试)' -ForegroundColor Yellow
}

# ---- 构建 --------------------------------------------------------------------

# 图标树摇（font-subset.exe）现已可用：本机 Smart App Control 早前的拦截
# 已解除，--no-tree-shake-icons 不再需要，保留默认树摇可省约 1.5MB 字形。
# 若某台构建机又出现拦截（构建报 font-subset 失败），再加回该 flag 即可。
#
# both 模式要构建两次：先 split（会清掉旧的 app-release.apk），再 fat。
# 顺序不能反 —— `flutter build apk` 每次都会清理 flutter-apk 目录里
# 与本次模式不匹配的产物，若先 fat 再 split，fat 包会被第二次构建删掉。
$buildPasses = if ($Flavor -eq 'both') { @('split', 'fat') } else { @($Flavor) }

foreach ($pass in $buildPasses) {
    Write-Step "flutter build apk --release（$pass）"
    $buildArgs = @('build', 'apk', '--release')
    if ($pass -eq 'split') { $buildArgs += '--split-per-abi' }

    Write-Host "flutter $($buildArgs -join ' ')"
    & flutter @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "构建失败（exit $LASTEXITCODE，pass=$pass）。" }
}

# ---- 收集产物 ----------------------------------------------------------------
#
# both 模式下 split 与 fat 的产物**同时存在**于 flutter-apk 目录
# （fat 用 app-release.apk，split 用 app-<abi>-release.apk，文件名不冲突）。

Write-Step 'release manifest'

$wanted = if ($Flavor -eq 'both') { 'both' } else { $Flavor }
# 显式初始化为空数组：未启用 StrictMode 时，未赋值的变量是 $null，
# 而 @($null) 会得到一个「含一个 null 元素」的数组，让后面的 .Count 判断失真。
$splitApks = @()
$fatApks = @()
if ($wanted -eq 'split' -or $wanted -eq 'both') {
    $splitApks = @(Get-ChildItem -LiteralPath $apkDir -Filter 'app-*-release.apk' |
        Sort-Object Name)
}
if ($wanted -eq 'fat' -or $wanted -eq 'both') {
    $fatApks = @(Get-ChildItem -LiteralPath $apkDir -Filter 'app-release.apk')
}
$apks = @($splitApks) + @($fatApks)

if ($apks.Count -eq 0) { throw "在 $apkDir 没找到构建产物（flavor=$Flavor）。" }

# ---- 签名归属校验（关键）-----------------------------------------------------
#
# 为什么必须做：`flutter build apk --release` 在 key.properties 缺失/写坏时
# 会**静默回落到 debug key**，构建照样成功、APK 照样产出，只是签名是
# "Android Debug"。这种包一旦发出去，用户装上后用真 release key 签的新版本
# 会因签名不一致而**无法覆盖安装**（INSTALL_FAILED_UPDATE_INCOMPATIBLE），
# 只能卸载重装（丢数据）。所以「构建成功」不等于「可以分发」。
#
# 本机就踩过：build-apk 目录里躺着 2026-10-09 的三个 split APK，是
# key.properties 修好之前产的，签的是 Android Debug —— 体积/命名都跟正常
# 产物一模一样，极易误传。这里用 apksigner 读真实签名，从源头拦住。
$apksigner = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools') -Filter 'apksigner.bat' -Recurse -ErrorAction SilentlyContinue |
    Sort-Object { [version]($_.Directory.Name) } -Descending |
    Select-Object -First 1
if (-not $apksigner) {
    # 也试试 sdk.dir 指向的机器级 SDK
    $localProps = Join-Path $repoRoot 'android\local.properties'
    if (Test-Path -LiteralPath $localProps) {
        $sdkDir = (Get-Content -LiteralPath $localProps |
            Where-Object { $_ -match '^\s*sdk\.dir\s*=' } |
            Select-Object -First 1) -replace '^\s*sdk\.dir\s*=\s*', '' -replace '\\\\', '\'
        if ($sdkDir -and (Test-Path -LiteralPath $sdkDir)) {
            $apksigner = Get-ChildItem -Path (Join-Path $sdkDir 'build-tools') -Filter 'apksigner.bat' -Recurse -ErrorAction SilentlyContinue |
                Sort-Object { [version]($_.Directory.Name) } -Descending |
                Select-Object -First 1
        }
    }
}

$expectCn = 'TaskMaster'
if ($apksigner) {
    Write-Step 'verify signing cert'
    foreach ($apk in $apks) {
        # apksigner 会往 stderr 打 JVM 的 "A restricted method in java.lang.System
        # has been called" 警告。本脚本开着 $ErrorActionPreference = 'Stop'，这条
        # stderr 会被 PowerShell 包成 NativeCommandError **直接终止脚本** ——
        # 表现是"包全构建成功，验签第一行就死"，看着像签名有问题，实际是
        # 检查它的人自己崩了。所以这一段单独把错误策略降成 Continue，
        # 只看退出码和 stdout。
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $verifyOutput = & $apksigner.FullName 'verify' '--print-certs' $apk.FullName 2>$null
            $verifyCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($verifyCode -ne 0) {
            throw "apksigner 校验 $($apk.Name) 失败（exit $verifyCode）。"
        }
        # 两个坑叠在一起，都不能靠"贴一行正则"绕：
        #   1. 措辞随 build-tools 变过 —— 老版本 `Signer #1 certificate DN:`，
        #      build-tools 37 是 `V2 Signer: certificate DN:`，前缀认死就匹配不上；
        #   2. apksigner.bat 的行为 `\r`（只有回车没有换行），PowerShell 抓到的是
        #      一坨没有行结构的字符串，Select-String 按行匹配等于什么都没匹配到。
        # 所以先把输出拼成一整段，只认 `certificate DN:` 后面那截。
        $text = ($verifyOutput -join "`n")
        $dnMatch = [regex]::Match($text, 'certificate DN:\s*(.+)')
        if (-not $dnMatch.Success) {
            throw "无法读取 $($apk.Name) 的签名证书（apksigner 输出：$text）"
        }
        $subject = $dnMatch.Groups[1].Value
        if ($subject -notmatch $expectCn) {
            throw ("$($apk.Name) 的签名不是 $expectCn —— 实际是：$subject`n" +
                   "  这通常意味着构建回退到了 debug key（key.properties 缺失或写坏）。`n" +
                   "  这种包**绝对不能分发**：与已发布版本签名不一致，用户无法覆盖安装。`n" +
                   "  请先跑 tool\setup_android_keystore_auto.ps1 生成 key.properties 再重新构建。")
        }
        Write-Host "$($apk.Name) 签名 OK（$expectCn）" -ForegroundColor Green
    }
} else {
    Write-Host '未找到 apksigner —— 跳过签名归属校验。' -ForegroundColor Yellow
    Write-Host '请在能访问 Android SDK build-tools 的终端手动确认签名是 TaskMaster。' -ForegroundColor Yellow
}

$version = (Select-String -LiteralPath (Join-Path $repoRoot 'pubspec.yaml') -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$appVersion = ($version -split '\+')[0]        # 5.5.19+0 -> 5.5.19
$buildNumber = ($version -split '\+')[1]       # 5.5.19+0 -> 0

$usedFlags = ''
if ($Flavor -eq 'split' -or $Flavor -eq 'both') {
    $usedFlags = $usedFlags + ' --split-per-abi'
}

$lines = @(
    "TaskMaster release APK manifest",
    "generated   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "version     : $appVersion",
    "versionCode : $buildNumber",
    "flavor      : $Flavor",
    "flags       : $usedFlags",
    "",
    "---- 可直接粘贴进 update.json 的 latest（下载键已按 ABI 生成）----",
    ""
)

# 从文件名 app-<abi>-release.apk 里取出 ABI，拼成 downloads 的键。
# 客户端按 <platform>-<abi> 优先匹配，匹配不到再回落 <platform>
# （见 AppRelease.resolveTarget）；因此 split 模式下键必须是 android-<abi>。
function Get-DownloadKey($fileName) {
    if ($fileName -match '^app-(?<abi>[A-Za-z0-9_\-]+)-release\.apk$') {
        return "android-$($Matches['abi'])"
    }
    # fat 包：泛化键，兼容旧客户端
    return 'android'
}

# fat 的泛化键排在最前，读起来更像「默认 + 细分」，也便于确认过渡键在位。
$orderedApks = @(
    @($apks | Where-Object { $_.Name -eq 'app-release.apk' })
    @($apks | Where-Object { $_.Name -ne 'app-release.apk' } | Sort-Object Name)
)

$jsonEntries = @()
Write-Host ''
foreach ($apk in $orderedApks) {
    $hash = (Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLower()
    $size = $apk.Length
    $key = Get-DownloadKey $apk.Name
    $jsonEntries += ('      "{0}": {{ "url": "<CDN>/releases/{1}", "sha256": "{2}", "sizeBytes": {3} }}' -f $key, $apk.Name, $hash, $size)
    Write-Host ("{0}  {1,12:N0} 字节  {2}" -f $apk.Name, $size, $hash)
    Write-Host ("   {0,-31} -> {1:N1} MB   key={2}" -f '', ($size / 1MB), $key)
}

$lines += ('    "version": "{0}",' -f $appVersion)
$lines += '    "notes": [],'
$lines += '    "downloads": {'
$lines += ($jsonEntries -join ",`n")
$lines += '    }'

$hasFallbackKey = $jsonEntries -match '"android"'
$lines += @(
    "",
    "---- 提醒 ----",
    "  - 更新包必须与已安装包**同签名**，否则用户安装报 INSTALL_FAILED_UPDATE_INCOMPATIBLE。",
    "  - 上传与发布已自动化：构建后跑 tool\publish_release.ps1（建 Release、传资产、",
    "    回读 size/digest、更新 update.json、刷 CDN），不要手工网页上传。",
    "  - 上传时**文件名不要改**：上面的键是从文件名推导的，改名会让键与产物对不上。",
    "  - fat APK（单包）约 62MB；split 后每个约 21~25MB。自更新优先给用户 arm64-v8a。"
)
if ($hasFallbackKey) {
    $lines += "  - [OK] 已包含泛化 android 键（指向 fat 包）—— 未升级的老客户端也能收到更新。"
} else {
    $lines += "  - [注意] **没有**泛化 android 键：只有 ABI 键时，尚未升级的老客户端"
    $lines += "          会静默查不到产物（不报错）。过渡期请用 -Flavor both 补一个 fat 包，"
    $lines += "          或在 downloads 里手工加回泛化 android 键。"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifestPath) | Out-Null
Set-Content -LiteralPath $manifestPath -Value $lines -Encoding UTF8

Write-Host ''
Write-Host "清单已写入: $manifestPath" -ForegroundColor Green
