# 刷 jsDelivr 缓存（发插件 / 改索引之后跑一次）
#
# 存在的理由：jsDelivr 对 gh/<repo>@<branch> 默认缓存约 12 小时。插件货架的
# 索引就是从这个路径读的，不刷的话"我明明 push 了"用户那边最长要等半天。
# 更要紧的是一种过渡窗口：新提交把某个包从 assets/ 挪到 plugins/packages/ 时，
# 远端索引可能还在缓存里指着旧路径，而旧文件已经删了 —— 那段时间点安装就是 404。
#
# 用法（在项目根目录）：
#   powershell -ExecutionPolicy Bypass -File tool\purge_jsdelivr.ps1
#   powershell -ExecutionPolicy Bypass -File tool\purge_jsdelivr.ps1 -Paths assets/plugins/index.json,plugins/packages/energy_currency_v1.0.0.zip
#
# 说明：purge 接口是公开的 GET，不需要 token；返回体里带 status 字段。
[CmdletBinding()]
param(
    # 逗号分隔的仓库相对路径。
    #
    # **故意用 [string] 而不是 [string[]]**：`-File` 方式传参时 `a,b,c` 不会被
    # 解析成数组，而是当成一个整串 —— 于是只会 purge 一个拼起来的假路径。
    # 实测踩过：三条路径被合成为一条，脚本还报"全部刷新完成"。
    [string]$Paths = 'assets/plugins/index.json',
    [string]$OwnerRepo = 'Aria-2676/taskmaster-v6',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Continue'
$failed = 0

$list = $Paths -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

foreach ($path in $list) {
    $url = "https://purge.jsdelivr.net/gh/$OwnerRepo@$Branch/$($path.TrimStart('/'))"
    try {
        $resp = Invoke-RestMethod -Method GET -Uri $url -TimeoutSec 60
        Write-Host "purged  $path  ->  $($resp.status)"
    } catch {
        $failed++
        Write-Host "FAILED  $path  ->  $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($failed -gt 0) {
    Write-Host "有 $failed 个路径没刷成功。稍等重跑即可（这个接口偶发 5xx）。" -ForegroundColor Yellow
    exit 1
}
Write-Host '全部刷新完成。'
