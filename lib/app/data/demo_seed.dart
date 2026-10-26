import '../models/task.dart';
import 'task_repository.dart';

/// 预览阶段的演示数据：**只在任务表为空时**写入，用户一旦有自己的任务就不再插手。
///
/// 正式的 v6 主包不该带这个，它只服务于 `main_v6_preview.dart`
/// 和"首次打开是空白页什么都看不出来"的困扰。
class DemoSeed {
  const DemoSeed._();

  static const List<String> tagNames = <String>['工作', '学习', '生活'];

  static Future<void> runIfEmpty(TaskRepository repo) async {
    if (await repo.countTasks() > 0) return;

    for (final name in tagNames) {
      await repo.insertTag(Tag(id: 0, name: name));
    }
    final tags = await repo.allTags();
    int idOf(String name) =>
        tags.firstWhere((t) => t.name == name, orElse: () => tags.first).id;

    final today = DateTime.now();
    final tomorrow = today.add(const Duration(days: 1));

    await repo.insert(
      title: '写完 v6 主包的第一屏',
      day: today,
      priority: 'red',
      estimatedMinutes: 60,
      tagIds: <int>[idOf('工作')],
    );
    await repo.insert(
      title: '整理插件契约的六件规格',
      day: today,
      priority: 'orange',
      estimatedMinutes: 30,
      tagIds: <int>[idOf('工作')],
    );
    await repo.insert(
      title: '读 30 页《设计心理学》',
      day: today,
      priority: 'blue',
      estimatedMinutes: 30,
      tagIds: <int>[idOf('学习')],
    );
    await repo.insert(
      title: '给番茄钟设计大圆环',
      day: tomorrow,
      priority: 'yellow',
      estimatedMinutes: 15,
      tagIds: <int>[idOf('工作')],
    );
    final done = await repo.insert(
      title: '散步 20 分钟',
      day: today,
      priority: 'white',
      estimatedMinutes: 15,
      tagIds: <int>[idOf('生活')],
    );
    await repo.setDone(done, true);
  }
}
