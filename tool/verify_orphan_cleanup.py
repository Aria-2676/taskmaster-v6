#!/usr/bin/env python3
"""
验收断言：跑完四条「任务被永久删除」的路径后，`task_tags` 的孤儿数必须为 0。

**为什么要有这个脚本**（不是单测能替代的东西）：

单测验的是「函数 A 在给定输入下返回 X」。而这一条要验的是**跨函数的组合后果**——
四条删除路径（回收站裁剪 / 单条永久删除 / 清空回收站 / 批量物理删除循环任务）
各自清了 `task_tags` 之后，**整库范围内**的孤儿数是否为 0。

本项目真实踩过这个坑：V1 裁决只落了文档、代码没改，
而兜底函数 `purgeOrphanTaskTags()` **没有任何调用方**，
⇒ 该清的三处没清、兜底也没被调 ⇒ **孤儿持续累积且无人清理**。
那时**单测全绿**（28 + 42 条），因为单测只测函数返回值，不测「跑完一遍之后库里还剩什么」。

**这个脚本直接对着一份真实形态的数据库跑那四条路径，然后数孤儿。**

## 用法

    python tool/verify_orphan_cleanup.py                       # 用金样本自建库
    python tool/verify_orphan_cleanup.py <某个.db>            # 用指定的库（先复制副本！）

**它会自己复制一份**，绝不碰你给的原库。

## 它到底验的是什么（**别误读**）

| 部分 | 验的是 | 不验的是 |
|---|---|---|
| 四个场景 | **修复设计的正确性**（照这四条路径 + 正确的 SQL 跑，孤儿数确实会归零），并给出**参考实现** | ❌ **不验 RN 的代码实现** |
| 源码扫描 | **RN 代码里清理 `task_tags` 的语句有没有误用 `recycled_tasks.id`**（V6 的静态判据） | ❌ 不验运行时的实际行为 |

**RN 代码的运行时行为要靠真机冒烟验**（M1 接线之后）。
本脚本的角色是：**① 参考实现 ② 静态护栏 ③ 设计自检**。

## 判定

- 退出码 0 = 通过（孤儿数为 0，且四个场景**都执行到了数据**）
- 退出码 1 = 失败（孤儿数不为 0，或**有场景被跳过**——跳过不等于通过）
"""

import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLDEN = os.path.join(REPO_ROOT, "fixtures", "golden-v3.db")

# 与 m1-decisions.md 索引表 V6 / H4 的验收命令保持一致：
# 清理条件必须用 task_id（不是 recycled_tasks.id），且必须取自「本次真正被永久删除的那几行」。
CLEAN_TASK_TAGS = "DELETE FROM task_tags WHERE task_id = ?"
# 危险写法示范：recycled_tasks.id 与 task_id 是两回事，用错会删掉活任务的标签。
CLEAN_TASK_TAGS_WRONG = "DELETE FROM task_tags WHERE task_id IN (SELECT id FROM recycled_tasks)"

# 🔴 V6 第 3 步的守卫：**只清「任务确实已从 tasks 消失」的那些关联**。
# ⚠️ 少了这一句，会把**仍然活着的任务**的标签关联一起删掉——
# 而「孤儿数 = 0」这个断言**发现不了它**（误删不产生孤儿，被误删的行本来就不该存在）。
# 这个缺口是 software-engineer-1 实测发现的：跑完仍 exit 0，但活任务 5 的标签已经没了。
GUARD = "AND task_id NOT IN (SELECT id FROM tasks)"


def orphan_count(conn: sqlite3.Connection) -> int:
    """孤儿 = 在 tasks 与 recycled_tasks 中都找不到的 task_id（与 §7 验收 SQL 同口径）。"""
    return conn.execute(
        """
        SELECT COUNT(*) FROM task_tags tt
          LEFT JOIN tasks t ON t.id = tt.task_id
          LEFT JOIN recycled_tasks r ON r.task_id = tt.task_id
         WHERE t.id IS NULL AND r.id IS NULL
        """
    ).fetchone()[0]


def live_task_tag_rows(conn: sqlite3.Connection) -> set:
    """**仍然活着的任务**（在 `tasks` 里）的标签关联行集合。

    这是「反向断言」的基础：跑完删除路径后，这个集合必须**原样不变**。
    ⚠️ 「孤儿数 = 0」**发现不了**误删活任务关联——误删的行本来就不该算孤儿，
    它被删掉只会让孤儿数更接近 0。**必须另有一条断言盯着「不该被删的还在」。**
    （这个缺口是 software-engineer-1 实测发现的。）
    """
    return set(
        conn.execute(
            "SELECT tt.task_id, tt.tag_id FROM task_tags tt "
            "JOIN tasks t ON t.id = tt.task_id"
        ).fetchall()
    )


def tag_orphan_count(conn: sqlite3.Connection) -> int:
    """另一类孤儿：tag_id 指向已删除的标签（V7）。"""
    return conn.execute(
        "SELECT COUNT(*) FROM task_tags tt LEFT JOIN tags g ON g.id = tt.tag_id WHERE g.id IS NULL"
    ).fetchone()[0]


def check_no_wrong_column_usage(path: str) -> list[str]:
    """**两层**源码扫描（software-engineer-1 指出第一层不够）：

    ① **用错列**：清理 `task_tags` 的语句里出现了 `recycled_tasks.id`
       （它与 `task_id` 是两回事，拿错会删掉活任务的标签）。
    ② **漏加守卫**：清理 `task_tags` 的语句里**没有** `NOT IN (SELECT id FROM tasks)`。
       ⚠️ 只查①抓不到②——**前两步都对、只是少了守卫**时，代码看起来完全正常，
       而后果是「静默删掉活任务的标签」。这条是 V6 第 3 步，
       **最危险也最容易在 review 时看漏**（它只是 WHERE 后面多一句）。

    ⚠️ 判据必须**跨行**看：SQL 在 TS 里是多行模板字符串，单行匹配会漏。
    """
    problems = []
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    for i, line in enumerate(lines):
        if "DELETE FROM task_tags" not in line:
            continue
        # 取该语句所在的完整模板字符串：往后拼到出现反引号或分号为止
        chunk = line
        j = i
        while j + 1 < len(lines) and "`" not in chunk.split("DELETE FROM task_tags")[-1] and j - i < 12:
            j += 1
            chunk += lines[j]
        norm = " ".join(chunk.split())

        if "recycled_tasks.id" in norm or "SELECT id FROM recycled_tasks" in norm:
            problems.append(
                f"{path}:{i + 1}: 清理 task_tags 的语句里出现了 recycled_tasks.id —— "
                f"必须用 task_id，否则会删掉活任务的标签（V6 🔴）\n      {norm.strip()[:110]}"
            )
        elif "NOT IN (SELECT id FROM tasks)" not in norm:
            problems.append(
                f"{path}:{i + 1}: 清理 task_tags 的语句**缺少 V6 第 3 步守卫** —— "
                f"必须带 `AND task_id NOT IN (SELECT id FROM tasks)`，"
                f"否则会误删仍然活着的任务的标签（🔴 最易漏、代码看起来却完全正常）\n      {norm.strip()[:110]}"
            )
    return problems


def ensure_fixture(conn: sqlite3.Connection) -> int:
    """把副本补足到**四条路径都跑得到数据**。

    金样本只有 2 条回收站记录 → 场景 3（裁剪）永远触发不了 → 会被跳过。
    与其让工具报「跳过」，不如**在副本上补足数据**（原库不动）：
    造 12 条回收站记录（覆盖裁剪需要的 >10），task_id 指向真实存在的任务。

    返回补了多少条。
    """
    have = conn.execute("SELECT COUNT(*) FROM recycled_tasks").fetchone()[0]
    if have >= 12:
        return 0
    task_ids = [r[0] for r in conn.execute("SELECT id FROM tasks ORDER BY id")]
    if not task_ids:
        return 0
    added = 0
    for i in range(12 - have):
        tid = task_ids[i % len(task_ids)]
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (tid,)).fetchone()
        if row is None:
            continue
        cols = [d[1] for d in conn.execute("PRAGMA table_info(recycled_tasks)")]
        vals = {
            "task_id": tid,
            "loop_id": None,
            "title": f"合成回收条目 {i}",
            "description": None,
            "is_word": 0,
            "is_ok": 0,
            "cpl_time": "2026-01-01T00:00:00.000",
            "recurrence": "none",
            "completed_at": None,
            "reward_points": 0,
            "is_deducted": 0,
            "created_at": "2026-01-01T00:00:00.000",
            "priority": "white",
            "deleted_at": f"2026-01-{i + 1:02d}T00:00:00.000",
        }
        keys = [c for c in cols if c in vals and c != "id"]
        conn.execute(
            f"INSERT INTO recycled_tasks ({', '.join(keys)}) VALUES ({', '.join('?' * len(keys))})",
            [vals[k] for k in keys],
        )
        added += 1
    conn.commit()
    return added


def run_one(src: str, name: str, fn) -> tuple[bool, str, int]:
    """在**独立副本**上跑一个场景。

    为什么每个场景一份独立副本：四个场景是**互相独立的代码路径**，
    若串行跑在同一个库上，场景 1 清空回收站后场景 2/3 就没有数据可操作，
    会被**静默跳过**却仍然报「通过」——这是本脚本第一版的真实 bug。
    ⇒ 每个场景独立副本，且**跳过即失败**（见 executed 检查）。
    """
    tmpdir = tempfile.mkdtemp(prefix="orphan-verify-")
    db_path = os.path.join(tmpdir, "verify.db")
    shutil.copyfile(src, db_path)
    conn = sqlite3.connect(db_path)
    ensure_fixture(conn)
    before = orphan_count(conn)
    live_before = live_task_tag_rows(conn)
    try:
        executed, after = fn(conn)
        live_after = live_task_tag_rows(conn)
    finally:
        conn.close()
        shutil.rmtree(tmpdir, ignore_errors=True)
    # 反向断言：活着的任务的关联必须原样保留（这是唯一能抓住 V6 第 3 步的断言）
    lost = live_before - live_after
    ok = executed and after == 0 and not lost
    line = f"  {name} → 孤儿 {before} → {after}"
    if lost:
        line += f"  ❌ 活任务的标签关联被误删 {sorted(lost)}"
    if not executed:
        line += "  ⚠️ 未执行到数据（场景被跳过）"
    return ok, line, executed


def sc_clear_bin(conn):
    n = conn.execute("SELECT COUNT(*) FROM recycled_tasks").fetchone()[0]
    conn.execute(
        "DELETE FROM task_tags WHERE task_id IN "
        "(SELECT task_id FROM recycled_tasks WHERE task_id IS NOT NULL) " + GUARD
    )
    conn.execute("DELETE FROM recycled_tasks")
    conn.commit()
    return n > 0, orphan_count(conn)


def sc_single_delete(conn):
    row = conn.execute(
        "SELECT task_id FROM recycled_tasks WHERE task_id IS NOT NULL LIMIT 1"
    ).fetchone()
    if not row:
        return False, orphan_count(conn)
    conn.execute(CLEAN_TASK_TAGS + " " + GUARD, (row[0],))
    conn.execute("DELETE FROM recycled_tasks WHERE task_id = ?", (row[0],))
    conn.commit()
    return True, orphan_count(conn)


def sc_trim(conn):
    rows = conn.execute("SELECT id, task_id FROM recycled_tasks ORDER BY deleted_at DESC").fetchall()
    if len(rows) <= 10:
        return False, orphan_count(conn)
    for rid, tid in rows[10:]:
        if tid is not None:
            conn.execute(CLEAN_TASK_TAGS + " " + GUARD, (tid,))
        conn.execute("DELETE FROM recycled_tasks WHERE id = ?", (rid,))
    conn.commit()
    return True, orphan_count(conn)


def sc_bulk_delete_loop(conn):
    loop_rows = conn.execute(
        "SELECT id FROM tasks WHERE recurrence != 'none' AND loop_id IS NOT NULL"
    ).fetchall()
    if not loop_rows:
        return False, orphan_count(conn)
    for (tid,) in loop_rows:
        conn.execute(CLEAN_TASK_TAGS + " " + GUARD, (tid,))
        conn.execute("DELETE FROM tasks WHERE id = ?", (tid,))
    conn.commit()
    return True, orphan_count(conn)


def scenario(src: str) -> tuple[bool, str]:
    """四个场景各用独立副本跑，全部执行到数据、且孤儿数必须为 0。"""
    lines = []
    all_ok = True
    skipped = []
    for name, fn in [
        ("场景1 清空回收站", sc_clear_bin),
        ("场景2 单条永久删除", sc_single_delete),
        ("场景3 回收站裁剪", sc_trim),
        ("场景4 批量删循环任务", sc_bulk_delete_loop),
    ]:
        ok, line, executed = run_one(src, name, fn)
        lines.append(line)
        if not executed:
            skipped.append(name)
        all_ok = all_ok and ok

    # 参考信息：tag 维度的孤儿（V7）是历史遗留，不在本断言范围
    tmpdir = tempfile.mkdtemp(prefix="orphan-verify-")
    db_path = os.path.join(tmpdir, "verify.db")
    shutil.copyfile(src, db_path)
    conn = sqlite3.connect(db_path)
    tag_orphans = tag_orphan_count(conn)
    conn.close()
    shutil.rmtree(tmpdir, ignore_errors=True)

    detail = "\n".join(lines)
    if not all_ok:
        detail += "\n  ⚠️ 有场景未通过：孤儿数不为 0，或**活任务的标签关联被误删**（V6 第 3 步）。"
    if skipped:
        detail += f"\n  ⚠️ 以下场景没跑到数据（样本里没有对应数据）：{', '.join(skipped)}"
        detail += "\n     —— **跳过不等于通过**，请换一份含这些场景的数据重跑。"
    detail += f"\n  （参考）tag 维度孤儿（V7，历史遗留，不在本断言范围）：{tag_orphans}"
    return all_ok, detail


def main() -> int:
    args = sys.argv[1:]
    src = args[0] if args else GOLDEN

    # 源码扫描：V6 的静态判据
    #
    # 这里踩过一次真实的坑，值得写下来：路径原本是 `rn/src/repo/...`（旧仓库里
    # RN 工程放在 rn/ 子目录），拆到独立仓库后代码提到根目录 src/，路径失效；
    # 而外面那层 `if os.path.exists(t)` 守卫会让它**静默跳过**——两个目标都不存在时
    # scan_problems 是空数组，于是「一个文件都没扫」也被当成通过。
    # 结论：**缺失必须等于失败**，绝不能用存在性守卫包住扫描目标。
    scan_targets = [
        os.path.join(REPO_ROOT, "src", "repo", "recycleRepo.ts"),
        os.path.join(REPO_ROOT, "src", "repo", "taskRepo.ts"),
    ]
    scan_problems = []
    for t in scan_targets:
        if not os.path.exists(t):
            print(f"❌ 静态扫描目标不存在：{t}")
            print("   缺失按失败处理：否则「一个文件都没扫」也会被当成通过。")
            return 1
        scan_problems.extend(check_no_wrong_column_usage(t))

    if not os.path.exists(src):
        if src == GOLDEN:
            # 金样本是确定性产物（make_golden_sample.py 的 iso() 用固定种子，
            # 实测三次生成 sha256 完全一致），且 fixtures/ 不入库，
            # 所以缺样本时自动重建——而不是跳过。跳过等于假通过。
            print(f"金样本缺失：{src}")
            print("  自动生成（确定性，可复现）…")
            gen = os.path.join(REPO_ROOT, "tool", "make_golden_sample.py")
            rc = subprocess.run([sys.executable, gen], check=False)
            if rc.returncode != 0 or not os.path.exists(src):
                print("❌ 自动生成失败，请手动跑 `python tool/make_golden_sample.py`")
                return 1
        else:
            print(f"❌ 找不到库文件：{src}")
            return 1

    print("═" * 64)
    print("验收断言：四条永久删除路径跑完后，task_tags 孤儿数必须为 0")
    print("═" * 64)
    print(f"数据库：{src}（会在临时副本上跑，不碰原库）\n")

    ok, detail = scenario(src)

    print(detail)
    print()
    if scan_problems:
        print("❌ 源码扫描发现危险写法：")
        for p in scan_problems:
            print("  • " + p)
    else:
        # 两层判据都过了才打印这句：① 没用错列 ② 都带了守卫。
        # 早先这句只提了①，低估了本工具的覆盖面，容易让人误以为②没在查。
        print(
            f"✅ 源码扫描（{len(scan_targets)} 个文件，两层判据）："
            "① 没用 recycled_tasks.id；② 都带 NOT IN (SELECT id FROM tasks) 守卫"
        )

    print()
    if ok and not scan_problems:
        print("✅ 通过：孤儿数为 0，且未使用错误的 id 列")
        return 0
    if not ok:
        print("❌ 失败：见上方每条场景后的标注")
        print("   （可能是孤儿数不为 0，或**活任务的标签关联被误删**——后者只有反向断言能抓到）")
    return 1


if __name__ == "__main__":
    sys.exit(main())
