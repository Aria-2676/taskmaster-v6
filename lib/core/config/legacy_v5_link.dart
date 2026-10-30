/// 旧版（V5）的下载入口。
///
/// 为什么 V6 里要放 V5 的下载：两个 App 包名不同（`com.noteapp.taskmaster` /
/// `.v6`），可以同时装在一台手机上。V6 是从空白开始的（V5 的任务不会带过来），
/// 所以"想回到旧版"是个真实存在的需求，不该逼人自己去翻 GitHub。
///
/// V5 已经冻结在 5.5.26，不再发版 —— 这个地址是固定的，不需要跟着更新。
/// 如果哪天解冻 V5，改这里就行。
class LegacyV5Link {
  const LegacyV5Link._();

  static const String version = '5.5.26';

  /// V5 的最后一个整包（fat APK，任何机型都能装）
  static const String apkUrl =
      'https://github.com/Aria-2676/note_study/releases/download/v5.5.26/app-release.apk';

  /// 出问题时可以让人自己去挑（分 ABI 的包更小）
  static const String releasesUrl = 'https://github.com/Aria-2676/note_study/releases';
}
