"""从一张源图生成 Android 图标的所有尺寸。

**为什么要有这个脚本**：之前那 10 张图是用一串临时命令生成的，源图和参数都没
留下。结果是 `pubspec.yaml` 里的 `flutter_launcher_icons` 配置指向一张**旧图**，
而真正生效的 10 张图没有任何配置指向 —— 谁按配置跑一次生成命令，图标就静默
退回旧版。这个脚本把"从哪张图、用什么参数、生成哪些文件"全部固定下来。

用法（改图标时）：

    1. 替换 tool/icon_src/app_icon.png（建议 1024×1024、白底、图案居中留白充足）
    2. python tool/make_app_icon.py
    3. 看一眼 android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png 是否正常
    4. 重新构建

产出（共 10 个文件，两种形态各 5 档密度）：

    mipmap-{m,h,x,xx,xxx}dpi/ic_launcher.png              传统图标（含白底，铺满）
    drawable-{m,h,x,xx,xxx}dpi/ic_launcher_foreground.png 自适应前景（透明底，缩进安全区）

10 个不是 10 版设计 —— Android 每种屏幕密度都要各一份，否则低密度机上会糊。
"""

import os
import sys

from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tool", "icon_src", "app_icon.png")
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")

# 生成时统一用 900 见方的中间画布，最后再缩到目标尺寸。
# 先大后小是为了让边缘走 LANCZOS 抗锯齿，直接从 1024 缩到 48 会带锯齿。
CANVAS = 900

# 源图外圈有一道极淡的边框（生成图自带的），裁掉。按 1024 的 62px 估的。
CROP_INSET = 62

# 墨色。不用纯黑：纯黑在深色壁纸上会显得像"挖了个洞"。
INK = (18, 18, 22)

# 传统图标各密度边长
LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}

# 自适应前景各密度边长（108dp 基准）
ADAPTIVE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

# 自适应图标的安全区：内容只占中间 66%，否则圆形/水滴形遮罩会切到笔画。
SAFE_ZONE = 0.66


def build_ink():
    """把源图变成"白底上的一层墨"，返回带 alpha 的 RGBA 画布。"""
    raw = Image.open(SRC).convert("RGB")
    side = raw.size[0]
    art = raw.crop(
        (CROP_INSET, CROP_INSET, side - CROP_INSET, side - CROP_INSET)
    ).resize((CANVAS, CANVAS), Image.LANCZOS)

    # 用亮度当 alpha：越黑越不透明。除以 215 而不是 255，让笔画边缘更快到全黑，
    # 否则缩到 48px 时整体会发灰。
    alpha = art.convert("L").point(
        lambda v: max(0, min(255, int((255 - v) * 255 / 215)))
    )

    # **加一档重量**。源图的笔画偏细，直接缩到 48px 会"发飘"，挨着别的图标像虚的。
    # 做法是先膨胀（MaxFilter）再轻微模糊回补，得到"变粗但仍柔和"的边缘，
    # 而不是硬阈值切出来的毛边。
    alpha = (
        alpha.filter(ImageFilter.MaxFilter(19))
        .filter(ImageFilter.GaussianBlur(3))
        .point(
            lambda v: 255
            if v > 110
            else max(0, int(v * 255 / 110 * 0.35))
            if v > 40
            else 0
        )
    )

    ink = Image.new("RGBA", (CANVAS, CANVAS), INK + (255,))
    ink.putalpha(alpha)
    return ink


def write_legacy(ink):
    for density, size in LEGACY.items():
        canvas = Image.new("RGB", (CANVAS, CANVAS), (255, 255, 255))
        canvas.paste(ink, (0, 0), ink)
        out = os.path.join(RES, f"mipmap-{density}", "ic_launcher.png")
        canvas.resize((size, size), Image.LANCZOS).save(out)
        print(f"  legacy   {size:>3}px  {os.path.relpath(out, ROOT)}")


def write_adaptive(ink):
    inner = int(CANVAS * SAFE_ZONE)
    scaled = ink.resize((inner, inner), Image.LANCZOS)
    for density, size in ADAPTIVE.items():
        canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        canvas.alpha_composite(scaled, ((CANVAS - inner) // 2, (CANVAS - inner) // 2))
        out = os.path.join(RES, f"drawable-{density}", "ic_launcher_foreground.png")
        canvas.resize((size, size), Image.LANCZOS).save(out)
        print(f"  adaptive {size:>3}px  {os.path.relpath(out, ROOT)}")


def main():
    if not os.path.exists(SRC):
        sys.exit(f"找不到源图：{SRC}")
    print(f"源图 {SRC}")
    ink = build_ink()
    write_legacy(ink)
    write_adaptive(ink)
    print("完成。自适应背景色在 res/values/colors.xml（ic_launcher_background）。")


if __name__ == "__main__":
    main()
