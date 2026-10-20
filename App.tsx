/**
 * 应用外壳。
 *
 * 这里只做两件事，别往里塞业务逻辑：
 *
 *  1) **OTA 启动健康**（别删）：启动时 `noteBoot()` 记一次，首屏渲染成功后
 *     `markHealthy()` 清零。连续 3 次启动没被标记健康，updater 会自动删掉外部
 *     bundle 回到包内版本——这是推了坏包之后唯一的自救手段，丢了就再也回不去。
 *
 *  2) 渲染栈导航。页面由各人分头写，写好了往 `registry` 里加一项；
 *     没注册的路由 Navigator 会渲染成「页面还没接上」的占位块，不影响别的页面跑。
 *
 * 数据库不需要初始化：`src/repo/base.ts` 的 `db()` 内部会自动 `openDatabase()`。
 */

import React, { useEffect } from 'react';
import { Navigator, type ScreenRegistry } from './src/nav/Navigator';
import { markHealthy, noteBoot } from './src/ota/updater';
import DevPanelScreen, { recordBootNotice } from './src/screens/DevPanelScreen';
import { ProfileScreen } from './src/screens/ProfileScreen';
import { SettingsScreen } from './src/screens/SettingsScreen';

/**
 * 首屏渲染成功 → 标记健康的延迟。
 *
 * 沿用 Spike 控制台的 3 秒：给首屏一次完整渲染 + 用户可交互的时间，
 * 早点标健康会让「一启动就崩」的包被误判成健康，安全网就白装了。
 */
const HEALTHY_DELAY_MS = 3000;

/** 只注册已经写完的页面。其余路由等各自的实现落地后往这里加。 */
const registry: ScreenRegistry = {
  Profile: ProfileScreen,
  Settings: SettingsScreen,
  DevPanel: DevPanelScreen,
};

export default function App(): React.JSX.Element {
  useEffect(() => {
    (async () => {
      try {
        const boot = await noteBoot();
        if (boot.rolledBack) {
          const text = `检测到连续 ${boot.count} 次启动未标记健康，已自动回滚到包内版本`;
          console.log('OTA_AUTO_ROLLBACK ' + text);
          recordBootNotice(text);
        }
      } catch (e) {
        // 记启动失败不能让 App 起不来：宁可少记一次，也不能崩在启动路径上。
        console.log('OTA_NOTE_BOOT_FAILED ' + String(e));
      }
    })();

    const timer = setTimeout(() => {
      markHealthy().catch((e) => console.log('OTA_MARK_HEALTHY_FAILED ' + String(e)));
    }, HEALTHY_DELAY_MS);
    return () => clearTimeout(timer);
  }, []);

  return <Navigator screens={registry} />;
}
