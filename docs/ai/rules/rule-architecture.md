# 规则卡 · 架构与边界

> 最后更新：2026-11-01
> 适用：跨 `lib/core/` 与 `lib/app/` 的改动、扩展位、新入口、新状态。

## 必须

- `lib/app/` 可以依赖 `lib/core/`，**反过来不行**。core 需要 app 数据时定义接口，由 app 注入。
- 新代码先判断归属：能在别的 App 复用 → `core`；只服务本 App 的界面/装配 → `app`。
- 新入口只加到 `AppDestination`，侧边栏和「我的」从它生成。
- 新任务字段只加到 `FieldCatalog` + 一列 + 迁移；编辑页/字段管理由表驱动。
- 新状态先找现成判据（`PluginMarketStore.active`、`HomeMode`、`CurrencyStore.providerId`）。
- 插件能力用三级扩展位；区域级只给数据，不给样式。

## 禁止

- core import app。
- 为“看起来完整”放一个点不动的占位入口；`ready == false` 必须灰显标「未接入」。
- 把设置项包装成插件（如日历条形态）；插件不能提供主包没有的东西就不做插件。
- 在小区域塞 WebView；做常驻隐藏 WebView。
- 钩子拦截主流程；插件报错/超时阻塞任务完成。
- 用文案盖住原始错误。

## 判据

| 问题 | 判据 |
|---|---|
| 放 core 还是 app？ | 能否在别的 App 复用 |
| 做插件还是设置？ | 插件能否提供主包没有的东西 |
| 区域级还是页面级？ | 40dp 级区域只能给数据；整页才用 WebView |
| 主包还是插件？ | 被两个以上插件依赖 / 需要系统能力 / 数据一致性唯一入口 → 主包 |

## 参考

`docs/conventions/architecture.md`
