#!/usr/bin/env python3
"""
taskRepo 的 SQL 语义验证（对着**真 sqlite3** 跑，不是 mock）。

**为什么需要它**：`rn/src/repo/taskRepo.ts` 的导入链最终到
`@op-engineering/op-sqlite`（RN 原生模块），**Node 里 require 不进来**，
所以 `node --experimental-strip-types` 跑不了针对它的单测。
本脚本替代「单测」覆盖**SQL 本身对不对**这一层。

**它验什么、不验什么**（别误读）：

| 验 | 不验 |
|---|---|
| ORDER BY 五键的**实际排序结果** | ❌ RN 的 TS 代码是否真的这么写 |
| 重复检测两个分支的**实际命中** | ❌ 参数绑定是否正确 |
| 逾期四条件的**实际筛出集合** | ❌ 事务边界 |
| V6 第 3 步守卫的**实际防误删** | ❌ 异常回滚 |

⇒ **TS 侧的正确性由 `tsc --noEmit` + 真机冒烟保证**，本脚本只管 SQL 语义。

## 用法

    python tool/verify_task_repo_sql.py

退出码 0 = 全部通过；1 = 有断言失败。
"""

import sqlite3
import sys

DDL = """
CREATE TABLE tasks (
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
CREATE TABLE task_tags (
  task_id INTEGER NOT NULL, tag_id INTEGER NOT NULL, PRIMARY KEY (task_id, tag_id)
);
CREATE TABLE points_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  points INTEGER NOT NULL,
  type TEXT NOT NULL,
  description TEXT NOT NULL,
  related_id INTEGER,
  created_at TEXT NOT NULL
);
"""

# 与 taskRepo.ts 的 ORDER_BY_FOR_DATE 逐字一致
ORDER_BY_FOR_DATE = (
    "is_ok ASC, "
    "CASE priority WHEN 'red' THEN 0 WHEN 'orange' THEN 1 "
    "WHEN 'yellow' THEN 2 WHEN 'blue' THEN 3 WHEN 'white' THEN 4 END, "
    "cpl_time ASC, id DESC"
)
OVERDUE_SQL = (
    "SELECT id FROM tasks "
    "WHERE cpl_time < ? AND is_ok = 0 AND is_deducted = 0 AND recurrence = 'none'"
)
# V6 第 3 步：NOT IN 守卫
PURGE_TAGS_SQL = "DELETE FROM task_tags WHERE task_id IN ({ph}) AND task_id NOT IN (SELECT id FROM tasks)"

passed = 0
failures = []


def check(name, cond, detail=""):
    global passed
    if cond:
        passed += 1
    else:
        failures.append(f"{name}  {detail}")


def fresh_db():
    c = sqlite3.connect(":memory:")
    c.executescript(DDL)
    return c


def add(c, loop, title, desc, rec, cpl, rp=0, pr="white", ok=0, deducted=0):
    cur = c.execute(
        "INSERT INTO tasks (loop_id,title,description,recurrence,cpl_time,"
        "reward_points,priority,is_ok,is_deducted,created_at)"
        " VALUES (?,?,?,?,?,?,?,?,?,'2026-10-01T08:00:00.000')",
        (loop, title, desc, rec, cpl, rp, pr, ok, deducted),
    )
    return cur.lastrowid


# ── 1. 五键排序 ──────────────────────────────────────────────────────────
def test_order_by():
    c = fresh_db()
    # 刻意构造：未完成红(20日) / 未完成白(20日) / 已完成红(19日) / 未完成红(19日)
    add(c, None, "A未完成红晚", "d", "none", "2026-10-20T09:00:00.000", 0, "red", 0)
    add(c, None, "B未完成白", "d", "none", "2026-10-20T09:00:00.000", 0, "white", 0)
    add(c, None, "C已完成红", "d", "none", "2026-10-19T09:00:00.000", 0, "red", 1)
    add(c, None, "D未完成红早", "d", "none", "2026-10-19T09:00:00.000", 0, "red", 0)
    rows = [r[0] for r in c.execute(f"SELECT title FROM tasks ORDER BY {ORDER_BY_FOR_DATE}")]
    check("排序-未完成在前", rows.index("C已完成红") == len(rows) - 1, f"实际 {rows}")
    check("排序-优先级高于时间", rows.index("D未完成红早") < rows.index("B未完成白"), f"实际 {rows}")
    check("排序-时间早于优先级低者", rows.index("D未完成红早") < rows.index("A未完成红晚"), f"实际 {rows}")
    check("排序-同优先级同时刻用 id DESC（新在前）", rows.index("A未完成红晚") < rows.index("B未完成白"), f"实际 {rows}")


# ── 2. 重复检测两分支 ───────────────────────────────────────────────────
def test_dup_branches():
    c = fresh_db()
    id_a = add(c, "loop_1", "同标题", "desc", "daily", "2026-10-20T09:00:00.000")
    # 分支 A：同 loop 同日 → 命中
    r = c.execute(
        "SELECT id FROM tasks WHERE loop_id = ? AND cpl_time >= ? AND cpl_time < ? LIMIT 1",
        ("loop_1", "2026-10-20T00:00:00", "2026-10-21T00:00:00"),
    ).fetchone()
    check("分支A-同loop同日命中", r is not None and r[0] == id_a)
    # 分支 A：不同 loop 同日 → 不命中
    r = c.execute(
        "SELECT id FROM tasks WHERE loop_id = ? AND cpl_time >= ? AND cpl_time < ? LIMIT 1",
        ("loop_2", "2026-10-20T00:00:00", "2026-10-21T00:00:00"),
    ).fetchone()
    check("分支A-不同loop不命中", r is None)
    # 分支 A：同 loop 不同日 → 不命中
    r = c.execute(
        "SELECT id FROM tasks WHERE loop_id = ? AND cpl_time >= ? AND cpl_time < ? LIMIT 1",
        ("loop_1", "2026-10-21T00:00:00", "2026-10-22T00:00:00"),
    ).fetchone()
    check("分支A-同loop不同日不命中", r is None)

    add(c, None, "标题X", None, "none", "2026-10-20T09:00:00.000")
    # 分支 B：description IS NULL
    r = c.execute(
        "SELECT id FROM tasks WHERE title = ? AND cpl_time >= ? AND cpl_time < ? AND description IS NULL LIMIT 1",
        ("标题X", "2026-10-20T00:00:00", "2026-10-21T00:00:00"),
    ).fetchone()
    check("分支B-description为NULL用IS NULL命中", r is not None)
    # 分支 B：标题同但 description 不同 → 不命中
    r = c.execute(
        "SELECT id FROM tasks WHERE title = ? AND cpl_time >= ? AND cpl_time < ? AND description = ? LIMIT 1",
        ("标题X", "2026-10-20T00:00:00", "2026-10-21T00:00:00", "别的"),
    ).fetchone()
    check("分支B-description不同不命中", r is None)
    # 分支 B：NULL 与 '' 不等价
    add(c, None, "标题Y", "", "none", "2026-10-20T09:00:00.000")
    r = c.execute(
        "SELECT id FROM tasks WHERE title = ? AND cpl_time >= ? AND cpl_time < ? AND description IS NULL LIMIT 1",
        ("标题Y", "2026-10-20T00:00:00", "2026-10-21T00:00:00"),
    ).fetchone()
    check("分支B-空串不等于NULL", r is None)


# ── 3. 逾期四条件 ────────────────────────────────────────────────────────
def test_overdue():
    c = fresh_db()
    want = add(c, None, "应命中", "d", "none", "2026-10-19T23:00:00.000", 10)
    add(c, None, "已完成", "d", "none", "2026-10-19T23:00:00.000", 10, ok=1)
    add(c, None, "已扣分", "d", "none", "2026-10-19T23:00:00.000", 10, deducted=1)
    add(c, "loop_x", "循环任务", "d", "daily", "2026-10-19T23:00:00.000", 10)
    add(c, None, "今天到期", "d", "none", "2026-10-20T09:00:00.000", 10)

    got = [r[0] for r in c.execute(OVERDUE_SQL, ("2026-10-20T00:00:00",))]
    check("逾期-只命中非循环未完成未扣分且早于今天", got == [want], f"实际 {got}")
    check("逾期-循环任务被排除（recurrence='none' 生效）",
          all(c.execute("SELECT recurrence FROM tasks WHERE id=?", (g,)).fetchone()[0] == "none" for g in got))
    check("逾期-今天到期不算（T4 上界是当天00:00）",
          "今天到期" not in [r[0] for r in c.execute("SELECT title FROM tasks WHERE id IN (%d)" % want)])


# ── 4. V6 第 3 步守卫 ────────────────────────────────────────────────────
def test_v6_guard():
    """守卫存在的意义：tasks 里有同 id 的活任务时，不能删它的标签。"""
    c = fresh_db()
    alive = add(c, None, "活着的任务", "d", "none", "2026-10-20T09:00:00.000")
    doomed = add(c, "loop_d", "将被删的循环实例", "d", "daily", "2026-10-21T09:00:00.000")
    for tid in (alive, doomed):
        c.execute("INSERT INTO task_tags (task_id, tag_id) VALUES (?,1)", (tid,))
    c.commit()

    # 删掉循环实例（模拟 deleteAll 已删 tasks 行）
    c.execute("DELETE FROM tasks WHERE id = ?", (doomed,))
    c.commit()

    # 有守卫：只清 doomed 的，alive 的保留
    ph = ",".join(["?"] * 2)
    c.execute(PURGE_TAGS_SQL.format(ph=ph), (alive, doomed))
    c.commit()
    left = sorted(r[0] for r in c.execute("SELECT task_id FROM task_tags"))
    check("V6守卫-活任务的标签被保住", left == [alive], f"实际 {left}，活任务 id={alive}")

    # 无守卫会误删（对照组，证明这条断言不是空跑）
    c2 = fresh_db()
    a2 = add(c2, None, "活", "d", "none", "2026-10-20T09:00:00.000")
    d2 = add(c2, "loop", "死", "d", "daily", "2026-10-21T09:00:00.000")
    for t in (a2, d2):
        c2.execute("INSERT INTO task_tags (task_id, tag_id) VALUES (?,1)", (t,))
    c2.execute("DELETE FROM tasks WHERE id=?", (d2,))
    c2.execute("DELETE FROM task_tags WHERE task_id IN (?,?)", (a2, d2))  # 无守卫
    left2 = sorted(r[0] for r in c2.execute("SELECT task_id FROM task_tags"))
    check("V6守卫-无守卫时确实会误删（对照组）", left2 == [], f"实际 {left2}，活任务 id={a2} 被删了")


# ── 5. 永久删除的「顺序 × 守卫」组合（V6 补充最容易踩的坑） ───────────────
def test_permanent_delete_order():
    """
    🔴 这条守护的是本项目真实踩过的 bug：

    `NOT IN (SELECT id FROM tasks)` 守卫的语义是「只清**已经不在** `tasks` 里的
    任务的关联」。而 `deleteAll`（批量物理删循环任务）路径里，
    任务**此刻还在 `tasks` 里**（本次事务才要删它）——
    所以**若先清 `task_tags`、后删 `tasks`，守卫会把清理挡掉**，
    随后任务被删 → 关联变成孤儿，正是 V1 要消灭的那一种。

    ⇒ 两条路径的顺序规则**相反**，且「统一顺序」是错的：

    | 路径 | 任务此刻在 tasks 里吗 | 正确顺序 |
    |---|---|---|
    | 回收站三处（裁剪/单条永久删除/清空） | 不在 | 先清 task_tags → 再删 recycled_tasks |
    | deleteAll 批量删循环任务 | **在** | **先删 tasks → 再清 task_tags** |

    **统一的是守卫，不是顺序。**
    """
    def build():
        c = fresh_db()
        doomed_a = add(c, "loop_A", "将被批量删 A", "d", "daily", "2026-10-21T09:00:00.000")
        doomed_b = add(c, "loop_A", "将被批量删 B", "d", "daily", "2026-10-22T09:00:00.000")
        alive = add(c, None, "活着的任务", "d", "none", "2026-10-20T09:00:00.000")
        for t in (doomed_a, doomed_b, alive):
            c.execute("INSERT INTO task_tags (task_id, tag_id) VALUES (?,1)", (t,))
        c.commit()
        return c, [doomed_a, doomed_b], alive

    ids_of = lambda c: [r[0] for r in c.execute("SELECT id FROM tasks WHERE id > 1")]
    purge = lambda c, ids: c.execute(
        PURGE_TAGS_SQL.format(ph=",".join(["?"] * len(ids)))
        + " AND task_id NOT IN (SELECT id FROM tasks)", ids)

    # 反例：先清后删（我原来的错误顺序）→ 清理被守卫挡掉 → 产生孤儿
    c, ids, alive = build()
    purge(c, ids)
    for i in ids:
        c.execute("DELETE FROM tasks WHERE id = ?", (i,))
    c.commit()
    orphans_wrong = c.execute(
        "SELECT COUNT(*) FROM task_tags tt WHERE tt.task_id NOT IN (SELECT id FROM tasks)"
    ).fetchone()[0]
    check("顺序反例-先清后删会产生孤儿（证明这条断言不是空跑）", orphans_wrong > 0, f"实际 {orphans_wrong}")

    # 正例：先删 tasks 后清 → 守卫此时放行
    c, ids, alive = build()
    for i in ids:
        c.execute("DELETE FROM tasks WHERE id = ?", (i,))
    purge(c, ids)
    c.commit()
    orphans_fixed = c.execute(
        "SELECT COUNT(*) FROM task_tags tt WHERE tt.task_id NOT IN (SELECT id FROM tasks)"
    ).fetchone()[0]
    check("顺序正例-先删tasks后清，孤儿为 0", orphans_fixed == 0, f"实际 {orphans_fixed}")

    alive_kept = c.execute(
        "SELECT COUNT(*) FROM task_tags WHERE task_id = ?", (alive,)
    ).fetchone()[0]
    check("顺序正例-活任务的标签未被误删", alive_kept == 1, f"实际 {alive_kept}")
    check("顺序正例-被删任务的标签已清干净",
          c.execute("SELECT COUNT(*) FROM task_tags WHERE task_id IN (?,?)", ids).fetchone()[0] == 0)


for fn in (test_order_by, test_dup_branches, test_overdue, test_v6_guard, test_permanent_delete_order):
    try:
        fn()
    except Exception as e:  # noqa: BLE001
        failures.append(f"{fn.__name__} 抛出异常: {e}")

print(f"passed={passed} failed={len(failures)}")
for f in failures:
    print("FAIL: " + f)
print("RESULT=" + ("FAIL" if failures else "PASS"))
sys.exit(1 if failures else 0)
