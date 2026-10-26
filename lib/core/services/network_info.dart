import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// 当前接入网络是否适合「无人值守的自动下载」。
///
/// 只服务于「仅 WiFi 自动下载」这一个闸门，因此 API 刻意收窄成一个
/// [allowsUnmeteredDownload]：
/// - 返回 true：WiFi / 以太网，或无法判定（fail-open，见下）；
/// - 返回 false：蜂窝移动网络、无网络、或仅 VPN 且底层不是 WiFi/以太网。
///
/// **fail-open 原则**：插件异常、平台不支持时一律返回 true（放行）。
/// 原因是这个闸门只是帮用户省流量，绝不能因为一次判定失败就让资源热更
/// 永久静默停摆——下载本身还有多源重试与失败静默重试兜底。
class NetworkInfo {
  const NetworkInfo([Connectivity? connectivity])
    : _connectivity = connectivity;

  final Connectivity? _connectivity;

  Future<bool> allowsUnmeteredDownload() async {
    // Web / 桌面没有蜂窝流量概念，不拦截。
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return true;
    try {
      final results = await (
        _connectivity ?? Connectivity()
      ).checkConnectivity();
      // WiFi 或以太网任一在列即视为免流量。开 VPN 时结果会同时带上底层
      // 网络类型，因此这里仍能正确识别「VPN over WiFi」。
      if (results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet)) {
        return true;
      }
      // 其余情况（mobile / none / 仅 vpn）保守按计费网络处理，本次跳过，
      // 等下次检查（回前台、下个周期）到了 WiFi 再下。
      return false;
    } catch (_) {
      return true;
    }
  }
}
