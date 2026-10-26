/// Android ABI（应用二进制接口）命名的规整与识别。
///
/// 存在的理由：`flutter build apk --split-per-abi` 会按 ABI 产出多个包，
/// 更新清单里对应写成 `android-arm64-v8a` 这类细分键。而 Android 通过
/// `getprop ro.product.cpu.abi` 回给我们的字符串**未必**与之一致
/// （可能带空白/换行、大小写不一、或多值逗号分隔），必须先规整再匹配，
/// 否则会静默匹配不上 → 用户收不到更新。
///
/// 纯逻辑、无副作用、不依赖 Flutter —— 与 [VersionUtils] 同层，可直接单测。
class AbiProperty {
  const AbiProperty._();

  /// Flutter 官方支持的 ABI 命名，**必须**与 `--split-per-abi` 生成的
  /// `app-<abi>-release.apk` 里的 `<abi>` 完全相同，否则永远匹配不上。
  static const List<String> knownAbis = [
    'arm64-v8a',
    'armeabi-v7a',
    'x86_64',
  ];

  /// 把 `getprop` 的原始输出规整成 [knownAbis] 之一；无法识别时返回 null。
  ///
  /// 处理三种现实情况：
  /// - 首尾空白 / 换行（`getprop` 输出必带 `\n`）；
  /// - 大小写不一致；
  /// - 多值逗号分隔（部分设备），取**第一个**能识别的。
  ///
  /// 返回 null 是**安全**的：调用方会回落到泛化下载键 `downloads[platform]`。
  static String? normalize(String? raw) {
    if (raw == null) return null;
    final lowered = raw.trim().toLowerCase();
    if (lowered.isEmpty) return null;
    for (final part in lowered.split(',')) {
      final candidate = part.trim();
      if (knownAbis.contains(candidate)) return candidate;
    }
    return null;
  }
}
