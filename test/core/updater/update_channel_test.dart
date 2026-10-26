// 更新渠道。
//
// 本仓库只有一条渠道，但仍要盯两件事：
//   1. 清单名与本地状态前缀都是预期的值（改错了会读不到清单 / 串到 V5 的键）
//   2. 与 V5 遗留的 SharedPreferences 键**不重叠** —— 用户从 V5 升级上来时，
//      同一份 prefs 里还留着 `app_update_asset_build` 等旧值；
//      串了会让 V6 永久静默跳过资源热更

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:v5_app/core/updater/services/app_update_service.dart';
import 'package:v5_app/core/updater/services/app_update_settings.dart';
import 'package:v5_app/core/updater/update_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('渠道定义', () {
    test('读仓库根目录的 update.json', () {
      expect(UpdateChannel.current.manifestPath, 'update.json');
      expect(UpdateChannel.current.createService().manifestPath, 'update.json');
    });

    test('本地状态带 v6 前缀（不能落回 V5 的键名）', () {
      expect(UpdateChannel.current.settingsScope, 'v6');
      expect(UpdateChannel.current.settingsScope, isNotEmpty,
          reason: '空前缀会与 V5 遗留键冲突，最硬的一条是资源包构建号');
    });

    test('默认 service 与渠道指向同一份清单', () {
      expect(AppUpdateService().manifestPath, UpdateChannel.current.manifestPath);
    });
  });

  group('候选地址', () {
    test('每条候选都指向本仓库的清单', () {
      final uris = AppUpdateService.candidatesFor('update.json');
      expect(uris, isNotEmpty);
      for (final uri in uris) {
        expect(uri.path.endsWith('/update.json'), isTrue);
        expect(uri.toString(), contains('taskmaster-v6'),
            reason: 'V6 的清单在新仓库，指回 note_study 就串到 V5 那条线了');
      }
    });

    test('Contents API 兜底地址也跟着清单名', () {
      expect(
        AppUpdateService.contentsApiUri('update.json').toString(),
        allOf(endsWith('/contents/update.json'), contains('taskmaster-v6')),
      );
    });
  });

  group('本地状态隔离', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('v6 前缀写自己的键', () async {
      const v6 = AppUpdateSettings(scope: 'v6');
      await v6.setIgnoredVersion('6.0.0');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_update_v6_ignored_version'), '6.0.0');
      expect(prefs.getString('app_update_ignored_version'), isNull,
          reason: 'V5 的键不能被写');
    });

    test('读不到 V5 留下的资源包构建号（否则会永久跳过热更）', () async {
      // 模拟"用户从 V5 升级上来"：旧键里已经有值
      SharedPreferences.setMockInitialValues(<String, Object>{
        'app_update_asset_build': 7,
        'app_update_ignored_version': '5.5.26',
      });

      const v6 = AppUpdateSettings(scope: 'v6');
      expect(await v6.assetBuild(), 0);
      expect(await v6.ignoredVersion(), isNull);
      expect(await v6.notificationsEnabled(), isTrue,
          reason: 'V5 里关过提醒，换成 V6 应该重新征求一次同意');
    });
  });
}
