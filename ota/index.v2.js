/**
 * OTA 验收用的假 bundle（v2）。
 *
 * 用途：验证「外部 bundle 真的能把 APK 里那份界面换掉」。
 * 打成一个独立 bundle 上传后，启动 App 应当看到绿屏 + 下面这行字，
 * 而不是包内的正常界面——**看到它，就证明 OTA 链路通了**。
 *
 * 这个文件**不参与 App 的正常构建**，只在手动验收时单独打。
 * 保留它是因为 OTA 是本项目的核心能力，丢了就没有低成本的验收手段了。
 *
 * 注册名必须与 `index.js` 一致（`TaskMasterV6`），否则覆盖不生效。
 * （原名 `TaskMasterSpike`，随 v6 包名一并改过来。）
 */

import React from 'react';
import { SafeAreaView, Text, StyleSheet } from 'react-native';
import { AppRegistry } from 'react-native';

function OtaV2() {
  return (
    <SafeAreaView style={styles.root}>
      <Text style={styles.big}>OTA BUNDLE v2 ACTIVE</Text>
      <Text style={styles.small}>这份界面来自外部 bundle，不是 APK 里的那份</Text>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0F6E56', alignItems: 'center', justifyContent: 'center' },
  big: { fontSize: 24, color: '#E1F5EE', fontWeight: '500' },
  small: { fontSize: 13, color: '#9FE1CB', marginTop: 12 },
});

AppRegistry.registerComponent('TaskMasterV6', () => OtaV2);
