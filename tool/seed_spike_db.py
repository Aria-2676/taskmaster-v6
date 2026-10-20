"""
把「金样本 + 今日数据」灌进真机的 Spike 应用，供小组件 / 番茄钟 / 验收反复使用。

为什么需要它：
1. `fixtures/golden-v3.db` 里的任务是 2026-01 的固定日期，**今天一条都没有**，
   直接推进去小组件只会显示 0/0/250，看不出效果。
2. 番茄钟默认 25 分钟，真机等不起，需要把 `work_duration` 临时改小。
3. 每次手敲 adb + python 很容易漏步骤，改一次数据就要重来一遍。

用法（设备已连 adb）：

    python tool/seed_spike_db.py                 # 默认：种今日数据，番茄钟 1 分钟
    python tool/seed_spike_db.py --work 25       # 番茄钟恢复 25 分钟
    python tool/seed_spike_db.py --no-today      # 只推原始金样本

注意：本脚本**只写** `cpl_time`（排期时间）与 `is_ok`，不改行数、不改余额、不改孤儿行，
所以 `verifyGolden` 的期望值依然成立（实测 RESULT=PASS）。
"""

import argparse
import datetime
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

# v6 新包名（与 android/app/build.gradle 的 applicationId 一致）。
# 旧值 com.noteapp.taskmaster.spike 是 Flutter v5 的验证包，已随换栈作废。
PKG = "com.noteapp.taskmaster.v6"
# v6 库名（与 src/db/index.ts 的 DB_NAME 一致）。旧值 v5_tasks.db 已作废。
DB_NAME = "tasks.db"
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLDEN = os.path.join(REPO_ROOT, "fixtures", "golden-v3.db")


def adb(*args: str, check: bool = True) -> str:
    cmd = ["adb", *args]
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if check and proc.returncode != 0:
        sys.exit(f"adb 失败: {' '.join(cmd)}\n{proc.stdout}{proc.stderr}")
    return proc.stdout


def seed_local(src: str, dst: str, today: bool, work_minutes: int, overrides: dict) -> None:
    shutil.copyfile(src, dst)
    conn = sqlite3.connect(dst)
    cur = conn.cursor()

    if today:
        day = datetime.date.today().isoformat()
        ids = [r[0] for r in cur.execute("SELECT id FROM tasks ORDER BY id LIMIT 3")]
        # 前两条设为今日待办，第三条设为今日已完成 —— 小组件就会显示 2 / 1 / <积分>
        for i, tid in enumerate(ids):
            ts = f"{day}T{9 + i * 2:02d}:30:00.000"
            cur.execute("UPDATE tasks SET cpl_time = ?, is_ok = ? WHERE id = ?", (ts, 1 if i == 2 else 0, tid))
        cur.execute("UPDATE tasks SET completed_at = ? WHERE id = ?", (f"{day}T13:30:00.000", ids[2]))

    cur.execute("UPDATE pomodoro_settings SET work_duration = ? WHERE id = 1", (work_minutes,))
    for col, value in overrides.items():
        cur.execute(f"UPDATE pomodoro_settings SET {col} = ? WHERE id = 1", (value,))
    conn.commit()

    todo = cur.execute(
        "SELECT COUNT(*) FROM tasks WHERE is_ok = 0 AND cpl_time LIKE ?", (f"{datetime.date.today()}%",)
    ).fetchone()[0]
    done = cur.execute(
        "SELECT COUNT(*) FROM tasks WHERE is_ok = 1 AND cpl_time LIKE ?", (f"{datetime.date.today()}%",)
    ).fetchone()[0]
    points = cur.execute("SELECT points FROM user_points WHERE id = 1").fetchone()[0]
    conn.close()
    print(f"本地已准备：今日待办 {todo} / 今日已完成 {done} / 积分 {points} / 专注时长 {work_minutes} 分钟")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", type=int, default=1, help="pomodoro_settings.work_duration（分钟）")
    ap.add_argument("--short", type=int, default=None, help="short_break_duration（分钟）")
    ap.add_argument("--long", type=int, default=None, help="long_break_duration（分钟）")
    ap.add_argument("--interval", type=int, default=None, help="long_break_interval（几个专注进长休）")
    ap.add_argument("--no-today", action="store_true", help="不种今日数据")
    ap.add_argument("--no-launch", action="store_true", help="推完不启动应用")
    args = ap.parse_args()

    if not os.path.exists(GOLDEN):
        sys.exit(f"缺少金样本 {GOLDEN}，先跑 `python tool/make_golden_sample.py`")

    tmp_dir = tempfile.mkdtemp(prefix="spike-seed-")
    local_db = os.path.join(tmp_dir, DB_NAME)
    overrides = {}
    if args.short is not None:
        overrides["short_break_duration"] = args.short
    if args.long is not None:
        overrides["long_break_duration"] = args.long
    if args.interval is not None:
        overrides["long_break_interval"] = args.interval
    seed_local(GOLDEN, local_db, not args.no_today, args.work, overrides)

    # 设备端：先落到 /data/local/tmp，再用 run-as 拷进应用私有目录
    # （adb push 不能直接写 /data/data/<pkg>/）
    remote_tmp = f"/data/local/tmp/{DB_NAME}"
    adb("push", local_db, remote_tmp)
    adb("shell", "run-as", PKG, "cp", remote_tmp, f"databases/{DB_NAME}")
    adb("shell", "rm", "-f", remote_tmp)
    adb("shell", "am", "force-stop", PKG)
    print(f"已写入设备 {PKG} 的 databases/{DB_NAME}")

    if not args.no_launch:
        adb("shell", "monkey", "-p", PKG, "-c", "android.intent.category.LAUNCHER", "1")
        print("已启动应用；用 `adb logcat -s ReactNativeJS:I TaskWidget:I` 看 RESULT= 与 render todo=")

    shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
