---
name: release
description: 发布 taskmaster-v6 App 版本或插件版本时使用。固定“先传包、最后改清单”的顺序，覆盖签名、Release、update.json、CDN 与冻结版本纪律。
---

# 发版

> 最后更新：2026-11-01

## 什么时候用

- 发 App 新版本（`6.x.y+versionCode`）
- 发插件新版本（`plugins/packages/`）
- 改 `update.json` / 插件索引 / 引流入口

**不适用于**：日常功能开发（`feature-dev`）、插件实现（`plugin-dev`）。

## App 发版步骤

1. **前置检查**
   - 用户已签收本轮交付；没有未验收的改动混在里面。
   - `flutter analyze lib` 无 error；全量 `flutter test` 通过。
   - `pubspec.yaml` 的 `version` build 号已抬，**versionCode 只能涨**。
2. **构建与验签**
   - 构建 release（分架构包由脚本处理）；确认签名是仓库外那把 keystore。
   - 产物：fat / arm64 / armeabi / x86_64 四个包（以 `build_apk.ps1` 实际输出为准）。
3. **上传**
   - 建 tag / 推分支（本网络走 `tool/push_via_api.ps1`）。
   - 建/取 GitHub Release，上传四个包，回读 size + digest 双核对。
   - **Gitee 要手动传四个包**：`-AltBase` 只写地址，不会帮你传。
4. **最后改清单**
   - 重写 `update.json`：`latest.version` + 每个包的 url / sha256 / sizeBytes / mirrors。
   - **顺序不能反**：清单先改、包没传 → 用户点更新是死链。
   - `downloads` 留空是安全中间态（客户端判定“无更新”，不报错）。
5. **刷缓存**
   - `tool/purge_jsdelivr.ps1`；知道 gcore 可能刷不掉，客户端按 `updatedAt` 取最新。
6. **验证**
   - 从 GitHub/Gitee 回读包 size/digest；从 CDN 读清单，确认最新。
   - 必要时装一台设备走“检查更新 → 下载 → 安装”链路。
7. **记录**
   - 更新 `docs/update-channels.md` 的现状（版本号、远端 sha、已知缓存状态）。
   - 发版踩的坑写进当日记录/任务文件。

## 插件发版步骤

1. 改 `plugins/src/<id>/plugin.json` 的 `version`（`x.y.z`）。
2. `python tool/make_demo_plugin.py` 打包并重算索引 sha/size；确认打包幂等。
3. 决定随包/仓库：默认仓库；随包只允许“断网必须可用且没它 App 不能用”。
4. `tool/publish_plugin.ps1`：打包 → 版本守卫（同版本换内容拒） → 提交 → 推送 → 刷缓存。
5. 用户刷新市场即可看到/升级；**不需要发 App 版本**。

## 硬规则

- **未签收不推送。** 本地提交可以，推送要等用户说“过了”。
- **推送前合并**：多个本地提交合成 1 个（API 推送只做单提交快进）。
- 被引流入口写死的版本 + sha 是冻结目标：发布后**不能再重发**；
  要改指向就发下一个版本。
- `minSupported` 不能提到当前 major：提了就是强制更新，“跳过此版本”失效。
- 文件名只用 ASCII；中文路径会让 API 推送的 git 调用失败。
- PowerShell 脚本存 UTF-8 **带 BOM**；`-Notes` 数组用纯 ASCII 包装脚本 + UTF-8 JSON。
- 不要先改 `update.json` 后传包；不要用 `git push`（被限速），走 API 脚本。
- 不要提交 token/keystore/真实数据；提交前 `git status --untracked-files=all`。

## 输出

- 四个 App 包（或插件 zip）+ Release + 更新后的 `update.json`/索引
- 发版记录（版本号、sha、远端状态、已知缓存问题）
- 验收/回归说明

## 参考

- `docs/update-channels.md`
- `docs/two-way-channel.md`
- `docs/conventions/delivery.md` §5
- `tool/README.md`
- `docs/ai/rules/rule-delivery.md`
