# tool/

一条命令能做完的事就别手打。这里的脚本按**角色**分三类，看第二列就知道该不该自己跑。

## 入口：你直接跑

| 脚本 | 干什么 | 什么时候跑 |
|---|---|---|
| `publish_release.ps1` | 发版一条命令：推送 → GitHub Release → 四个包上传校验 → 重写 `update.json` → 刷 CDN 缓存 | **要发新版本时，日常只跑这个** |

> 注意 `publish_release.ps1` 的 `-Notes` 是数组，**不能用
> `powershell -File ... -Notes @('a','b')` 传**：`-File` 不做表达式解析，
> `@(...)` 会被拆成普通字符串，多出来那截按位置绑到 `$OwnerRepo` 上，
> API 请求会打到 `repos/<一段中文>/releases`。要带 notes 就写一个纯 ASCII 的
> 包装脚本，或者用 `-Command` 调用。同理：**`.ps1` 一律存成带 BOM 的 UTF-8**，
> 否则 PowerShell 5.1 按 GBK 读，中文字符串会被截断成 ParserError。
| `publish_plugin.ps1` | 发插件一条命令：打包 → 版本守卫（同版本换内容直接拒） → 校验 → 提交 → 推送 → 刷缓存 | 改完插件要发布时 |
| `make_app_icon.py` | 从 `icon_src/app_icon.png` 生成 10 张图标（5 档传统 + 5 档自适应前景） | 换图标时。**不要去装 flutter_launcher_icons**，见 pubspec 里的注释 |
| `build_apk.ps1` | 只构建 + 出 `release-manifest.txt`（各包 sha256/大小），不发布 | 想先看看包多大、摘要多少，或排障时单独重跑构建 |

## 部件：被上面的脚本调用，正常情况下不用单独跑

| 脚本 | 被谁调 | 单独跑的场景 |
|---|---|---|
| `push_via_api.ps1` | `publish_release`、`publish_plugin` | 本网络 `git push` 被限速到不可用时，直接推一次 |
| `purge_jsdelivr.ps1` | 同上 | 手改了 `update.json` 或插件索引，想立刻让 CDN 生效 |
| `make_demo_plugin.py` | `publish_plugin` | 只想重新打包 zip + 生成索引，不提交 |

**`make_demo_plugin.py` 是幂等的**：同样一份源码打两次，第二次一个字节都不动
（内容一致就保留旧文件）。这不是洁癖——包名里的版本号不随重打包而变，
字节一变，索引里的 sha256 就和线上那份文件对不上，新装用户校验失败，
报出来像网络问题。自检（不需要 pytest）：

```
python test/plugin_packaging/test_make_demo_plugin.py
```

## 一次性 / 偶发：正常情况下永远不用跑

| 脚本 | 干什么 | 什么时候才有用 |
|---|---|---|
| `setup_android_keystore.ps1` | 生成 release 签名密钥库（密码你手输） | **换机器**、或密钥库丢了要重建。密钥库现在在 `D:\Dev\keystore\` |
| `setup_android_keystore_auto.ps1` | 同上，密码由脚本生成并写到 `PASSWORD.txt` | 仅在没有交互终端时用；和上一个功能重叠 |
| `backup_android_keystore.ps1` | 把密钥库 + `key.properties` 打成一个备份包 | 定期备份签名材料时 |

**签名材料丢了就再也发不出可以覆盖安装的包**（用户必须卸载重装，数据全丢）。这三个脚本存在的意义就是这个，别删。

## 不是脚本

- `github_token.txt` —— GitHub 凭证，已在 `.gitignore` 里，**永远不要提交**
- `icon_src/app_icon.png` —— 图标源图，改图标改它

## 一条判断

> 想知道"这个脚本我要不要跑"：看上表第二列。
> 只有「入口」那四个是给人用的，其余都是它们调用的部件或历史工具。
