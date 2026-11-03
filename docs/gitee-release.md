# Gitee：国内下载源的操作规程

> 最后更新：2026-11-03
>
> 定位：**只承载安装包的备用下载源**，不是代码镜像。GitHub 是权威源，
> Gitee 是给国内用户的第一顺位直链。

## 1. 仓库与地址

| 项 | 值 |
|---|---|
| 仓库 | `gitee.com/yaozhenqian/taskmaster-release` |
| 用途 | 只放 Release 附件（四个 APK），**不放代码、不放插件包** |
| 地址模板 | `https://gitee.com/yaozhenqian/taskmaster-release/releases/download/<tag>/<文件名>` |

`<tag>` 与 GitHub 的 tag **完全一致**（例如 `v6.1.2`），文件名也完全一致：

```
app-release.apk              （fat 包，含全部 ABI）
app-arm64-v8a-release.apk
app-armeabi-v7a-release.apk
app-x86_64-release.apk
```

四个都要传。少一个，对应 ABI 的用户就会落到代理链路上。

### 为什么不做代码镜像

代码镜像要额外维护一条同步链路（force push、分支保护、冲突），而分发只需要包。
插件包走 jsDelivr（`assets/plugins/`），本身已经是国内可访问的，不需要 Gitee 再复制一份。

## 2. 什么时候要动 Gitee

| 场景 | 要不要动 |
|---|---|
| 发新版（改了 `pubspec.yaml` 版本号并发布） | **要**，四个包全传 |
| 只改文档 / 只改插件 / 没发版 | 不用 |
| 补发某个 ABK 包 | 只传那一个，tag 用同一个 |

## 3. 每次发版的固定顺序

`publish_release.ps1` 一条命令跑完 GitHub 侧全链路（建 tag → Release → 传包 →
写 `update.json` → 提交推送 → 刷缓存），但**它不碰 Gitee**：`-AltBase` 只负责把
Gitee 地址写进清单，不会替你传文件。

所以固定顺序是：

```
1. 跑 publish_release.ps1 -AltBase 'https://gitee.com/yaozhenqian/taskmaster-release/releases/download'
2. 脚本结束后，立刻去 Gitee 建同名 tag 的 Release，传四个包
3. 回读每个包的 size 与 sha256，和 update.json 里那份对齐
```

**第 2 步别拖。** 清单一旦推出去，`update.json` 里 Gitee 地址就已经是用户的第一顺位。
这个窗口期内点下载会 404，然后客户端退到 `ghfast.top` 代理 —— 功能不坏，但体验差，
而且用户不会试第二次。

> 如果要先发版、过一阵再补包，那就**别带 `-AltBase`**：不写 Gitee 地址，
> 用户直接走代理，等包传完再补一次清单。宁可少一个源，不要给死链。

## 4. 校验

传完回读，三个数必须对上：

| 来源 | 字段 |
|---|---|
| 本地/update.json | `sha256`、`sizeBytes` |
| GitHub Release（脚本已校验） | 上传后回读的 size + digest |
| Gitee Release（要人工核对） | 附件大小、下载后算 sha256 |

只比大小不够：网盘/网页上传偶发截断，大小对上但内容不对的情况存在过。
拿不准就下一个包回来算一次 sha256。

## 5. 密钥

| 项 | 值 |
|---|---|
| 位置 | `tool/gitee_token.txt`（已加入 `.gitignore`，不会入库） |
| 环境变量（优先） | `GITEE_TOKEN` |
| 权限 | 该仓库的**发布权限**即可，不要给全站 token |

放法：把 token 那一行粘进文件，不要带引号、不要带 `Bearer ` 前缀、前后不要留空行。

**当前脚本不读它。** 它现在只有两个用途：

1. 将来把"传四个包"这一步自动化（Gitee 有上传附件的 OpenAPI）；
2. 如果仓库改成私有的，访问需要它。

自动化这一步**没做**，原因是没验证过接口参数，写上就是猜。真要做的时候，
先拿一个测试 tag 跑通再进脚本。

## 6. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 用户报"下载 404" | 包没传，或 tag 名和 GitHub 不一致 | 对齐 tag，补传 |
| 只有部分 ABI 能下 | 漏传某个包 | 补传那一个 |
| 下下来的包装不上 | 上传截断 | 重传，回读 sha256 |
| Gitee 提示单个附件超限 | 包太大 | 当前最大包 59MB，离平台单文件上限还有余量；真超了只能拆 ABI 或退回代理链路 |

## 7. 与其它文档的关系

- `docs/update-channels.md` §4 —— 发版总流程（Gitee 是其中一步）
- `tool/publish_release.ps1` —— `-AltBase` 参数把地址写进 `update.json` 的 `mirrors`
- `docs/ai/skills/release/SKILL.md` —— 发版时的检查清单
