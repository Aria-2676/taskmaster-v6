# Gitee：国内下载源的操作规程

> 最后更新：2026-11-03
>
> 定位：**只承载安装包的备用下载源**，不是代码镜像。GitHub 是权威源，
> Gitee 是给国内用户的第一顺位直链。

## 1. 仓库与地址

| 项 | 值 |
|---|---|
| 仓库 | `gitee.com/yaozhenqian/taskmaster-release` |
| 用途 | 只放 Release 附件（两个 ABI 的 APK），**不放代码、不放插件包** |
| 地址模板 | `https://gitee.com/yaozhenqian/taskmaster-release/releases/download/<tag>/<文件名>` |

`<tag>` 与 GitHub 的 tag **完全一致**（例如 `v6.1.2`），文件名也完全一致：

```
app-arm64-v8a-release.apk     必传（绝大多数真机）
app-armeabi-v7a-release.apk   必传（老设备兜底）
```

### 硬约束：附件配额 1 GB（总量）

Gitee 仓库的附件**总量**上限 1 GB，不是单文件。这是决定"传哪些包"的第一约束。

| 包 | 大小 | 传不传 |
|---|---|---|
| `app-arm64-v8a-release.apk` | 约 21 MB | **传** |
| `app-armeabi-v7a-release.apk` | 约 19 MB | **传** |
| `app-x86_64-release.apk` | 约 23 MB | 不传（只有模拟器用） |
| `app-release.apk`（fat） | 约 62 MB | 不传（**已停止发布**，见 `docs/decisions.md`） |

两个包 ≈ 40 MB/版本，1 GB 能放 **25 个版本**。四个全传是 125 MB/版本，只够 8 个。

少传的包**不会让用户下载失败**：客户端走多源逐个回退（`MultiSourceDownloader`，
HTTP 4xx 时清残包换下一个源），Gitee 404 会自动退到 `ghfast.top`。

> 前提是 `update.json` 里给缺的包**不要写** Gitee 地址 —— 写了会先白跑一次 404。
> 这一步由脚本按"实际传了哪些"生成，不手写。

## 2. 什么时候要动 Gitee

| 场景 | 要不要动 |
|---|---|
| 发新版（改了 `pubspec.yaml` 版本号并发布） | **要**，带 `-Gitee` 一条命令搞定 |
| 只改文档 / 只改插件 / 没发版 | 不用 |
| 上次漏传、需要补 | 单独跑 `publish_gitee.ps1` |

## 3. 发版：一条命令，Gitee 自动跟上

```
tool\publish_release.ps1 -Version 6.1.3 -Gitee `
  -AltBase 'https://gitee.com/yaozhenqian/taskmaster-release/releases/download' `
  -Notes $notes
```

`-Gitee` 让脚本在**写清单之前**调用 `publish_gitee.ps1` 把两个 ABI 包传上去。
顺序是刻意的：

```
步骤 4    上传 GitHub 资产并校验
步骤 4.5  上传 Gitee 附件（带 -Gitee 时）
步骤 5    才写 update.json
```

这样清单里出现的 Gitee 地址一定指向已经存在的文件。上传失败会直接中止，
清单保持原样 —— 宁可这个版本没有国内源，也不要给一个 404。

### 单独补传

漏传、或者先发版后补包，单独跑这条就够（幂等，已存在的附件按名字跳过）：

```
tool\publish_gitee.ps1                 # 版本号取自 update.json
tool\publish_gitee.ps1 -Version 6.1.2  # 指定版本
```

补完之后清单不会自动更新 —— 用 `-AltBase` 重跑一次发布，或者手工往
`update.json` 的 `mirrors` 里补一条（只补真正存在的包）。

### 清单里的镜像只写"真有的"

`publish_release.ps1` 在写 `mirrors` 之前会查 Gitee 上该 tag 的附件列表，
**只有附件真的存在才写 Gitee 地址**。缺的包走 `ghfast.top` 代理。

写一个 404 的地址不是"多一层保险"，是让用户多等一次失败 —— 首发命中率才重要。

## 4. 校验

传完回读，三个数必须对上：

| 来源 | 字段 |
|---|---|
| 本地 / update.json | `sha256`、`sizeBytes` |
| GitHub Release（脚本已校验） | 上传后回读的 size + digest |
| Gitee Release（脚本已校验） | 上传返回的 size，外加回读附件名集合 |

`publish_gitee.ps1` 最后会重新拉一次 Release，确认每个包都在。拿不准时再下一个
包回来算 sha256 —— **只比大小不够**，网页上传偶发截断，大小对上内容不对的情况存在过。

## 5. 密钥

| 项 | 值 |
|---|---|
| 位置 | `tool/gitee_token.txt`（已加入 `.gitignore`，不会入库） |
| 环境变量（优先） | `GITEE_TOKEN` |
| 权限 | 该仓库的**发布权限**即可，不要给全站 token |

放法：把 token 那一行粘进文件，不要带引号、不要带 `Bearer ` 前缀、前后不要留空行。

读取顺序：`$env:GITEE_TOKEN` → `tool/gitee_token.txt`。

`publish_gitee.ps1` 用它建 Release、传附件；`publish_release.ps1` 用它确认
"哪些附件真的存在"（决定要不要写 Gitee 镜像地址）。

## 6. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 用户报"下载 404" | 包没传，或 tag 名和 GitHub 不一致 | 跑 `publish_gitee.ps1` 补传 |
| 只有部分 ABI 能下 | 本来就只传了两个 ABI | 正常；x86_64 走代理 |
| 附件列表里同一个包出现两次 | 早先版本的去重判断有 bug（已修） | 删掉该 Release 重建 |
| `验证失败：文件大小已超出仓库附件配额：1 GB` | 附件总量满了 | 删旧版本的 Release，或确认只传了两个包 |
| `{"messages":["body is missing"]}` | 建 Release 时没给发布说明 | 脚本已用 update.json 的 notes 填 |
| 老客户端（6.0.0）收不到更新 | 它只认 `android` 键 | 脚本已保留该键，指向 arm64 包 |

## 7. 与其它文档的关系

- `docs/update-channels.md` §4 —— 发版总流程（Gitee 是其中一步）
- `docs/decisions.md` —— "不再发 fat 包、Gitee 只放两个 ABI"的取舍
- `tool/publish_release.ps1` —— `-Gitee` / `-AltBase` 两个参数
- `tool/publish_gitee.ps1` —— 传附件，幂等
