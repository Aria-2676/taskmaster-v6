# 规则卡 · 交付与发布

> 最后更新：2026-11-01
> 适用：准备提交、推送、发版、写验收清单。

## 四条红线

1. **未验收不推送。** 用户没说“过了/可以了”，只本地提交，不 push。
2. **带问号 = 征求意见。** 用户消息有“吗/？/是不是/能不能”时，先给判断与取舍，等定案。
3. **批量替换/脚本改配置必须验证。** `assert` 匹配数 + 改完 `grep`；配置改动有测试/build 兜底。
4. **不可复现 bug 不算修好。** 机制证明或“兜得住”的保险，且保险有自动化测试。
   “再试一次没出现”不是验收。

## 验收

- 写 `docs/acceptance/<日期>-<主题>.md`；机器判定 vs 人判定分层。
- 人判定 ≤10 条；能测试的不写进清单。
- 每条四件套：编号/路径/操作/可观察预期 + 排查线索。
- 禁止“正常/流畅/符合预期”；数量写死；一步一编号。
- 有 D 回归组；手感项标“需真机”并诚实写未验证。
- 没有验收清单，不要说“做完了”。

## 提交与推送

- 提交前：`flutter analyze lib` 无 error + 全量测试通过；验证不过不提交。
- 提交信息写“为什么”，不是文件清单。
- 推送前合并多个本地提交为 1 个（API 推送只做单提交快进）。
- 推送用 `tool/push_via_api.ps1`；推完 `git update-ref refs/remotes/origin/main <sha>`。
- 文件名 ASCII；PowerShell 带 BOM；`-Notes` 用纯 ASCII 包装 + UTF-8 JSON。

## 发版

- versionCode 只能涨；先传包，**最后**改 `update.json`。
- `downloads` 留空是安全中间态；`minSupported` 不能提到当前 major。
- 被引流入口写死的版本冻结，不再重发。
- 插件发版不需要 App 版本；打包幂等，索引 sha/size 脚本算。

## 环境

- 测试前清代理变量；`WebSocketException: Invalid WebSocket upgrade request` = 代理没清。
- 平台层/手感必须真机/模拟器；截图坐标先 dump 再点。

## 参考

`docs/conventions/delivery.md`
