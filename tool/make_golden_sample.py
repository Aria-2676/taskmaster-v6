#!/usr/bin/env python3
"""生成数据库迁移用的「金样本」v3。

用途：给 RN 侧做迁移回归测试——同一份已知输入、已知期望输出。
样本只写入 `fixtures/`（已 gitignore），不包含任何真实用户数据。

用法：
    python tool/make_golden_sample.py
    python tool/make_golden_sample.py --out fixtures/golden-v3.db

产物：
    fixtures/golden-v3.db            金样本数据库
    fixtures/golden-v3.expected.json 期望值（行数 / 余额 / 流水净额 / 孤儿数）
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta

SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  loop_id TEXT,
  title TEXT NOT NULL,
  description TEXT,
  is_word INTEGER NOT NULL DEFAULT 0,
  is_ok INTEGER NOT NULL DEFAULT 0,
  cpl_time TEXT NOT NULL,
  recurrence TEXT NOT NULL DEFAULT 'none',
  completed_at TEXT,
  reward_points INTEGER NOT NULL DEFAULT 0,
  is_deducted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'white'
);
CREATE TABLE IF NOT EXISTS shop_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  price INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  icon_name TEXT NOT NULL DEFAULT 'shopping_bag',
  color_value INTEGER NOT NULL DEFAULT 4278190335
);
CREATE TABLE IF NOT EXISTS user_points (
  id INTEGER PRIMARY KEY DEFAULT 1,
  points INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS points_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  points INTEGER NOT NULL,
  type TEXT NOT NULL,
  description TEXT NOT NULL,
  related_id INTEGER,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS purchased_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  shop_item_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  price INTEGER NOT NULL,
  purchased_at TEXT NOT NULL,
  icon_name TEXT NOT NULL DEFAULT 'shopping_bag',
  color_value INTEGER NOT NULL DEFAULT 4278190335
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS recycled_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER,
  loop_id TEXT,
  title TEXT NOT NULL,
  description TEXT,
  is_word INTEGER NOT NULL DEFAULT 0,
  is_ok INTEGER NOT NULL DEFAULT 0,
  cpl_time TEXT NOT NULL,
  recurrence TEXT NOT NULL DEFAULT 'none',
  completed_at TEXT,
  reward_points INTEGER NOT NULL DEFAULT 0,
  is_deducted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'white',
  deleted_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS custom_prize_pool (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  value INTEGER NOT NULL,
  weight REAL NOT NULL DEFAULT 1.0,
  is_default INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS lottery_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  draw_time TEXT NOT NULL,
  prize_name TEXT NOT NULL,
  prize_type TEXT NOT NULL,
  prize_value INTEGER NOT NULL,
  cost_points INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tags (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  color TEXT NOT NULL DEFAULT '#2196F3',
  icon TEXT,
  is_system INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS task_tags (
  task_id INTEGER NOT NULL,
  tag_id INTEGER NOT NULL,
  PRIMARY KEY (task_id, tag_id),
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
  FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS pomodoro_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mode TEXT NOT NULL,
  duration_seconds INTEGER NOT NULL,
  actual_seconds INTEGER NOT NULL,
  start_time TEXT NOT NULL,
  end_time TEXT,
  related_task_id INTEGER,
  related_task_title TEXT,
  is_completed INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pomodoro_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  work_duration INTEGER NOT NULL DEFAULT 25,
  short_break_duration INTEGER NOT NULL DEFAULT 5,
  long_break_duration INTEGER NOT NULL DEFAULT 15,
  long_break_interval INTEGER NOT NULL DEFAULT 4,
  sound_enabled INTEGER NOT NULL DEFAULT 1,
  vibration_enabled INTEGER NOT NULL DEFAULT 1,
  notification_enabled INTEGER NOT NULL DEFAULT 1,
  auto_start_break INTEGER NOT NULL DEFAULT 0,
  auto_start_work INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS scratch_tickets (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cost_points INTEGER NOT NULL,
  prize_id TEXT NOT NULL,
  prize_name TEXT NOT NULL,
  prize_type TEXT NOT NULL,
  prize_value INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  is_scratched INTEGER DEFAULT 0,
  is_revealed INTEGER DEFAULT 0
);
"""

INDEXES = """
CREATE INDEX IF NOT EXISTS idx_tasks_cpl_time ON tasks(cpl_time);
CREATE INDEX IF NOT EXISTS idx_tasks_is_ok ON tasks(is_ok);
CREATE INDEX IF NOT EXISTS idx_tasks_recurrence ON tasks(recurrence);
CREATE INDEX IF NOT EXISTS idx_tasks_loop_id ON tasks(loop_id);
CREATE INDEX IF NOT EXISTS idx_tasks_completed_at ON tasks(completed_at);
CREATE INDEX IF NOT EXISTS idx_points_records_type_related ON points_records(type, related_id);
CREATE INDEX IF NOT EXISTS idx_pomodoro_start_time ON pomodoro_records(start_time);
CREATE INDEX IF NOT EXISTS idx_task_tags_tag_id ON task_tags(tag_id);
"""


def iso(days: int = 0, hour: int = 9, minute: int = 0) -> str:
    """生成 ISO8601 本地时间字符串，**复刻 Dart `toIso8601String()` 的精度规则**。

    为什么不能简单用 `timespec="seconds"`：真实库里的时间几乎都来自
    `DateTime.now().toIso8601String()`，实测规则是
    **微秒为 0 → 3 位毫秒；微秒非 0 → 6 位**。早期版本生成的是整秒无小数，
    等于 M0 验收根本没覆盖到真实数据的格式。

    小数部分由 (days, hour, minute) 确定性推导，保证样本可复现：
    同一份输入永远得到同一个字符串，不会出现「重跑一次结果就变了」。
    """
    base = datetime(2026, 1, 31, hour, minute, 0) + timedelta(days=days)
    seed = (days * 7919 + hour * 131 + minute * 17) % 1_000_000
    ms, us = divmod(abs(seed), 1000)
    # 每 4 行里强制约 1 行落在「微秒为 0」分支：真实库里两种精度都出现过
    # （手工构造的整秒时间是 3 位，`DateTime.now()` 是 6 位），样本必须两者都有。
    if abs(seed) % 4 == 0:
        us = 0
    if us == 0:
        # 与 Dart 一致：微秒为 0 时只写 3 位毫秒
        return base.strftime("%Y-%m-%dT%H:%M:%S") + f".{ms:03d}"
    return base.strftime("%Y-%m-%dT%H:%M:%S") + f".{ms:03d}{us:03d}"


def build(db_path: str) -> dict:
    if os.path.exists(db_path):
        os.remove(db_path)
    os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)

    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA)
    conn.executescript(INDEXES)
    cur = conn.cursor()

    # 任务：普通 / 已完成 / 逾期已扣 / 单词任务 / 循环实例 / 边界文本
    cur.executemany(
        """INSERT INTO tasks
        (id, loop_id, title, description, is_word, is_ok, cpl_time, recurrence,
         completed_at, reward_points, is_deducted, created_at, priority)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        [
            (1, None, "普通任务", "描述", 0, 0, iso(0), "none", None, 10, 0, iso(-5), "white"),
            (2, None, "已完成任务", None, 0, 1, iso(-1), "none", iso(-1, 20), 20, 0, iso(-6), "blue"),
            (3, None, "逾期已扣", "已过扣分点", 0, 0, iso(-2), "none", None, 30, 1, iso(-7), "red"),
            (4, None, "单词任务", "背单词", 1, 0, iso(1), "none", None, 15, 0, iso(-3), "yellow"),
            (5, "loop_1735689600000_42", "每日复盘", "循环实例", 0, 0, iso(0), "daily", None, 5, 0, iso(-10), "orange"),
            (6, "loop_1735689600000_42", "每日复盘", "循环实例", 0, 0, iso(1), "daily", None, 5, 0, iso(-10), "orange"),
            (7, "loop_1735689600000_42", "每日复盘", "循环实例", 0, 1, iso(-1), "daily", iso(-1, 22), 5, 0, iso(-10), "orange"),
            (8, None, "月末边界任务", "cpl_time 为 1/31，验证 monthly 取月末", 0, 0, iso(0), "monthly", None, 8, 0, iso(-1), "white"),
            (9, None, "超长标题" + "很长" * 120, "emoji 🧪🎯 与符号 <>&\"'", 0, 0, iso(2), "none", None, 0, 0, iso(0), "white"),
            (10, None, "零奖励任务", None, 0, 0, iso(3), "none", None, 0, 0, iso(0), "white"),
        ],
    )

    # 回收站：一条带 loop_id（v3 新增列），一条不带
    cur.executemany(
        """INSERT INTO recycled_tasks
        (id, task_id, loop_id, title, description, is_word, is_ok, cpl_time,
         recurrence, completed_at, reward_points, is_deducted, created_at,
         priority, deleted_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        [
            (1, 5, "loop_1735689600000_42", "每日复盘", "从回收站恢复后要继续生成", 0, 0,
             iso(-3), "daily", None, 5, 0, iso(-10), "orange", iso(-1)),
            (2, 99, None, "旧任务无 loop_id", None, 0, 0, iso(-9), "none", None, 0, 0, iso(-12), "white", iso(-2)),
        ],
    )

    # 标签：含系统标签；task_tags 故意留一条孤儿（tag_id=999），验证外键未开启
    cur.executemany(
        "INSERT INTO tags (id, name, color, icon, is_system, created_at) VALUES (?,?,?,?,?,?)",
        [
            (1, "工作", "#2196F3", "work", 0, iso(-20)),
            (2, "学习", "#FF9800", None, 0, iso(-20)),
            (3, "系统", "#9E9E9E", "settings", 1, iso(-20)),
        ],
    )
    cur.executemany(
        "INSERT INTO task_tags (task_id, tag_id) VALUES (?,?)",
        [(1, 1), (2, 2), (4, 2), (8, 999)],
    )

    # 积分：余额必须等于流水净额
    cur.execute(
        "INSERT INTO user_points (id, points, updated_at) VALUES (1, ?, ?)",
        (250, iso(0)),
    )
    cur.executemany(
        """INSERT INTO points_records (id, points, type, description, related_id, created_at)
        VALUES (?,?,?,?,?,?)""",
        [
            (1, 20, "task_complete", "完成任务: 已完成任务", 2, iso(-1)),
            (2, 30, "overdue_deduct", "逾期任务扣除: 逾期已扣", 3, iso(-2)),
            (3, 50, "scratch_win", "刮刮乐中奖: 50 积分", 1, iso(-3)),
            (4, 20, "scratch_refund", "刮刮乐退款", None, iso(-3)),
            (5, 170, "task_complete", "完成任务: 历史批量", None, iso(-30)),
            (6, -40, "task_uncomplete", "取消完成: 历史批量", None, iso(-29)),
        ],
    )

    # 商城 / 仓库（快照式）
    cur.executemany(
        "INSERT INTO shop_items (id, name, description, price, created_at, icon_name, color_value) VALUES (?,?,?,?,?,?,?)",
        [
            (1, "奶茶", "一杯奶茶", 100, iso(-20), "local_cafe", 4294940672),
            (2, "休息 30 分钟", "什么都不做", 50, iso(-20), "timer", 4278233088),
        ],
    )
    cur.execute(
        """INSERT INTO purchased_items
        (id, shop_item_id, name, description, price, purchased_at, icon_name, color_value)
        VALUES (1, 1, '奶茶（旧名）', '购买时的快照', 88, ?, 'local_cafe', 4294940672)""",
        (iso(-4),),
    )

    # 番茄钟
    cur.execute("INSERT INTO pomodoro_settings (id) VALUES (1)")
    cur.executemany(
        """INSERT INTO pomodoro_records
        (id, mode, duration_seconds, actual_seconds, start_time, end_time,
         related_task_id, related_task_title, is_completed, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)""",
        [
            (1, "work", 1500, 1500, iso(-1, 9), iso(-1, 9, 25), 1, "普通任务", 1, iso(-1, 9)),
            (2, "shortBreak", 300, 120, iso(-1, 9, 30), None, None, None, 0, iso(-1, 9)),
            (3, "longBreak", 900, 900, iso(-2, 21), iso(-2, 21, 15), None, None, 1, iso(-2, 21)),
        ],
    )

    # 刮刮乐：奖池含空奖；票据含 NULL 状态（验证可空列）
    cur.executemany(
        """INSERT INTO custom_prize_pool (id, name, type, value, weight, is_default)
        VALUES (?,?,?,?,?,?)""",
        [
            ("p_none", "谢谢参与", "none", 0, 60.0, 1),
            ("p_points_10", "10 积分", "points", 10, 30.0, 0),
            ("p_goods_tea", "奶茶", "goods", 0, 10.0, 0),
        ],
    )
    cur.execute(
        """INSERT INTO lottery_records
        (id, draw_time, prize_name, prize_type, prize_value, cost_points, created_at)
        VALUES (1, ?, '10 积分', 'points', 10, 20, ?)""",
        (iso(-3), iso(-3)),
    )
    cur.executemany(
        """INSERT INTO scratch_tickets
        (id, cost_points, prize_id, prize_name, prize_type, prize_value, created_at,
         is_scratched, is_revealed)
        VALUES (?,?,?,?,?,?,?,?,?)""",
        [
            (1, 20, "p_points_10", "10 积分", "points", 10, iso(-3), 0, 1),
            (2, 20, "p_none", "谢谢参与", "none", 0, iso(-2), 0, 0),
            (3, 0, "p_none", "谢谢参与", "none", 0, iso(-1), None, None),
        ],
    )

    # 设置：camelCase 键（v1 遗留风格）
    cur.executemany(
        "INSERT INTO settings (key, value) VALUES (?,?)",
        [
            ("taskViewMode", "simple"),
            ("taskCreateMode", "quick"),
            ("themeMode", "system"),
            ("rememberFilters", "true"),
            ("allowEditPastTasks", "false"),
            ("allowCompletePastTasks", "true"),
            ("priority", "white"),
            ("recurrence", "none"),
            ("rewardPoints", "10"),
            ("isWord", "false"),
            ("description", ""),
            ("date", iso(0)),
        ],
    )

    conn.commit()

    expected = {
        "schemaVersion": 3,
        "counts": {},
        "balance": 0,
        "ledgerSum": 0,
        "orphanTaskTags": 0,
        "orphanTagRefs": 0,
        "nullScratchTickets": 0,
    }
    for table in [
        "tasks", "recycled_tasks", "tags", "task_tags", "points_records",
        "shop_items", "purchased_items", "pomodoro_records",
        "custom_prize_pool", "lottery_records", "scratch_tickets", "settings",
    ]:
        expected["counts"][table] = cur.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

    expected["balance"] = cur.execute("SELECT points FROM user_points WHERE id = 1").fetchone()[0]
    expected["ledgerSum"] = cur.execute("SELECT COALESCE(SUM(points),0) FROM points_records").fetchone()[0]
    expected["orphanTaskTags"] = cur.execute(
        "SELECT COUNT(*) FROM task_tags tt LEFT JOIN tasks t ON t.id = tt.task_id WHERE t.id IS NULL"
    ).fetchone()[0]
    expected["orphanTagRefs"] = cur.execute(
        "SELECT COUNT(*) FROM task_tags tt LEFT JOIN tags g ON g.id = tt.tag_id WHERE g.id IS NULL"
    ).fetchone()[0]
    expected["nullScratchTickets"] = cur.execute(
        "SELECT COUNT(*) FROM scratch_tickets WHERE is_scratched IS NULL OR is_revealed IS NULL"
    ).fetchone()[0]

    conn.close()

    if expected["balance"] != expected["ledgerSum"]:
        print(
            f"[WARN] 余额({expected['balance']}) != 流水净额({expected['ledgerSum']})，请修种子数据",
            file=sys.stderr,
        )
    return expected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=os.path.join("fixtures", "golden-v3.db"))
    args = parser.parse_args()

    expected = build(args.out)
    exp_path = os.path.splitext(args.out)[0] + ".expected.json"
    with open(exp_path, "w", encoding="utf-8") as fh:
        json.dump(expected, fh, ensure_ascii=False, indent=2)

    print(f"db      -> {args.out}")
    print(f"expected-> {exp_path}")
    print(json.dumps(expected, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
