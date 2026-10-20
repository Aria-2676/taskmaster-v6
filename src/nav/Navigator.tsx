/**
 * 栈导航渲染器。
 *
 * 为什么不直接 import 各个页面：界面层是几个人分头写的，页面是**逐个补齐**的。
 * 如果 Navigator 硬 import 所有页面，任何一个页面还没写完就会编译不过，
 * 大家只能串行等待。所以改成**注册表注入**——页面写好了就往 `screens` 里加一项，
 * 没写的路由渲染成一块「未注册」的占位，App 照样能跑起来看别的部分。
 *
 * 渲染规则：
 *   - 只渲染栈顶那一层（栈里的下层页面不渲染，够用且省重绘）
 *   - 栈顶是弹窗路由时，先渲染它下面那一层当背景，再用 RN Modal 盖上去
 *   - 底部 Tab 栏**只在 Tab 首页**显示
 */

import React, { useEffect } from 'react';
import { BackHandler, Modal, StyleSheet, Text, View } from 'react-native';
import { MODAL_ROUTES, type Route, type RouteName, type RouteParams } from './routes';
import { useNavStore } from './store';
import { TabBar } from './TabBar';
import { usePalette } from '../ui/usePalette';

export type ScreenProps = { params: RouteParams };
export type ScreenRegistry = Partial<Record<RouteName, React.ComponentType<ScreenProps>>>;

export function Navigator({ screens }: { screens: ScreenRegistry }): React.JSX.Element {
  const stack = useNavStore((s) => s.stack);

  // Android 返回键：栈能弹就自己处理，弹不动了（已在首页）交还给系统退 App。
  useEffect(() => {
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      return useNavStore.getState().pop();
    });
    return () => sub.remove();
  }, []);

  const top = stack[stack.length - 1];
  const isModal = MODAL_ROUTES.has(top.name);
  // 弹窗要有个背景页：取它下面那一层。栈里只有弹窗一个元素时退回首页路由。
  const base: Route = isModal ? (stack[stack.length - 2] ?? stack[0]) : top;

  const showTabBar = !isModal && stack.length === 1;

  return (
    <View style={styles.root}>
      {renderRoute(base, screens)}
      {isModal && (
        <Modal
          visible
          animationType="slide"
          onRequestClose={() => {
            useNavStore.getState().pop();
          }}
        >
          {renderRoute(top, screens)}
        </Modal>
      )}
      {showTabBar && <TabBar />}
    </View>
  );
}

function renderRoute(route: Route, screens: ScreenRegistry): React.JSX.Element {
  const Screen = screens[route.name];
  if (!Screen) return <UnregisteredRoute name={route.name} />;
  return <Screen params={route.params ?? {}} />;
}

/** 路由注册了但页面还没写。明说比白屏强——并行开发时天天会见到它。 */
function UnregisteredRoute({ name }: { name: RouteName }): React.JSX.Element {
  const palette = usePalette();
  return (
    <View style={[styles.missing, { backgroundColor: palette.bg }]}>
      <Text style={[styles.missingTitle, { color: palette.text }]}>页面还没接上</Text>
      <Text style={[styles.missingBody, { color: palette.textDim }]}>
        路由 {name} 已在 routes.ts 注册，但 screens 注册表里还没有对应页面。
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  missing: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24 },
  missingTitle: { fontSize: 17, marginBottom: 8 },
  missingBody: { fontSize: 13, textAlign: 'center' },
});
