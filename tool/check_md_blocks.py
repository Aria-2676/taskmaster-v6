#!/usr/bin/env python3
"""
检查 Markdown 的**渲染结构**问题（通则 8）。

为什么需要它：Markdown 的**渲染结果**与**源码**是两回事。
最常见的坑是「引用块后面缺一个空行」——源码看着对（`git diff` 里就是多一行），
渲染出来下一段普通文本被吞进引用块。**只读源码永远发现不了。**

本脚本检查三类问题：

1. **引用块吞段落**：`>` 行后面紧跟非空、非 `>` 的行 → 那一行会被渲染成引用块的一部分。
2. **未闭合的代码围栏**：``` 数量为奇数 → 后面全部内容都会被当代码。
3. **列表紧贴引用块**：引用块后面紧跟 `- ` / `1. ` 列表行 → 列表可能被并入引用块。

用法：
    python tool/check_md_blocks.py                     # 检查 docs/（递归）+ tool/ 下所有 .md
    python tool/check_md_blocks.py <文件> [<文件>…]   # 检查指定文件

退出码：有问题时为 1，否则为 0（可直接挂进 CI 或 pre-commit）。
"""

import sys
import os
import glob


def check_file(path: str) -> list[str]:
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")

    problems: list[str] = []
    in_code = False

    for i, line in enumerate(lines):
        stripped = line.strip()

        # 围栏代码块内部不参与检查（里面的 > 和 - 都是字面量）
        if stripped.startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue

        if stripped.startswith(">"):
            # 引用块的**内容行**后面紧跟普通段落 → 会被吞进引用块
            if i + 1 < len(lines):
                nxt = lines[i + 1]
                nxt_s = nxt.strip()
                if nxt_s and not nxt_s.startswith(">"):
                    # 引用块的最后一行内容（下一行是空行或 EOF）不算问题
                    problems.append(
                        f"{path}:{i + 1}: 引用块后紧跟普通文本，"
                        f"该行会被渲染成引用块的一部分 → 需在中间加一个空行"
                        f"\n      引用行: {line.rstrip()[:70]}"
                        f"\n      下一行: {nxt.rstrip()[:70]}"
                    )
            continue

        # 引用块之后紧跟列表 → 列表可能被并入引用块
        if stripped.startswith(("- ", "* ", "+ ")) or (
            stripped[:1].isdigit() and ". " in stripped[:4]
        ):
            if i > 0:
                prev = lines[i - 1].rstrip()
                if prev.startswith(">") and prev.strip():
                    problems.append(
                        f"{path}:{i + 1}: 引用块后紧跟列表行，列表可能被并入引用块 → 需加空行"
                        f"\n      上一行: {prev[:70]}"
                        f"\n      本行:   {line.rstrip()[:70]}"
                    )

    # 围栏未闭合
    if in_code:
        problems.append(f"{path}: 代码围栏 ``` 未闭合（数量为奇数）")

    return problems


def main() -> int:
    args = sys.argv[1:]
    if args:
        files = args
    else:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        files = sorted(glob.glob(os.path.join(root, "docs", "**", "*.md"), recursive=True))
        files += sorted(glob.glob(os.path.join(root, "tool", "*.md")))

    all_problems: list[str] = []
    for p in files:
        if not os.path.exists(p):
            print(f"跳过（不存在）: {p}")
            continue
        all_problems.extend(check_file(p))

    if all_problems:
        print(f"发现 {len(all_problems)} 处渲染结构问题：\n")
        for p in all_problems:
            print("• " + p)
        return 1

    print(f"✅ {len(files)} 个文件，渲染结构无问题")
    return 0


if __name__ == "__main__":
    sys.exit(main())
