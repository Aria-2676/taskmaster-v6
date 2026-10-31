"""把 plugins/src/<id>/ 打包成 assets/plugins/<id>_v<version>.zip，
并重新生成 assets/plugins/index.json。

为什么要有这个脚本：索引里的 sha256 必须与 zip 的字节完全一致，
手写一定会对不上。zip 的时间戳固定成 1980-01-01，保证同样的源
每次打出来的 hash 相同，不会产生无意义的 diff。

用法（在项目根目录）：
    python tool/make_demo_plugin.py
"""

import datetime
import glob
import hashlib
import json
import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 源码放 plugins/src/，**不放 assets/**：assets 底下每个字节都会被打进 APK，
# 而插件源码只是打包原料，不该进包。这个目录名以前叫 assets/plugins_src，
# 名字里带 assets 容易让人以为它会被打进去。
SRC_ROOT = os.path.join(ROOT, "plugins", "src")

# 包放哪儿 = 它怎么分发。这不是排版问题，是功能问题：
#   assets/plugins/        → 打进 APK，随包的离线兜底（断网也能装）
#   plugins/packages/      → 只从仓库分发，装的时候联网下载
# 同一个插件不要两边都有：两份同样内容放在两个地方，迟早有一份忘了重新打。
BUNDLED_DIR = os.path.join(ROOT, "assets", "plugins")
REPO_DIR = os.path.join(ROOT, "plugins", "packages")

# 只从仓库分发的插件（不进 APK）。改这里等于改"谁会随包发出去"。
REPO_ONLY = {"energy_currency"}

FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def pack(plugin_dir: str, manifest: dict) -> dict:
    plugin_id = manifest["id"]
    version = manifest["version"]
    name = f"{plugin_id}_v{version}.zip"
    out_dir = REPO_DIR if plugin_id in REPO_ONLY else BUNDLED_DIR
    dest = os.path.join(out_dir, name)
    os.makedirs(out_dir, exist_ok=True)

    # 反向清掉另一边的旧包：插件从"随包"改成"仓库分发"之后，
    # 留在 assets/ 里的那个旧 zip 还会被打进 APK，且索引已经不指向它 ——
    # 白占体积、还容易让人以为它还在随包。
    stale_dir = BUNDLED_DIR if plugin_id in REPO_ONLY else REPO_DIR
    for stale in glob.glob(os.path.join(stale_dir, f"{plugin_id}_v*.zip")):
        os.remove(stale)
        print(f"removed stale {stale}")

    files = []
    for current, _, names in os.walk(plugin_dir):
        for filename in names:
            absolute = os.path.join(current, filename)
            relative = os.path.relpath(absolute, plugin_dir).replace("\\", "/")
            files.append((relative, absolute))
    files.sort()

    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as archive:
        for relative, absolute in files:
            with open(absolute, "rb") as handle:
                data = handle.read()
            # **行尾必须归一化**。仓库开了 core.autocrlf，工作区里的 html/json
            # 是 CRLF，而入库的 blob 是 LF —— 同一份源码在不同检出状态下打出来的
            # zip 字节不一样，sha 就跟着变。表现是"我什么都没改，包却变了"，
            # 而版本号没 bump 时，线上索引的 sha 会和线上文件对不上。
            if relative.endswith((".html", ".json", ".css", ".js", ".txt", ".md")):
                data = data.replace(b"\r\n", b"\n")
            info = zipfile.ZipInfo(relative, date_time=FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)

    with open(dest, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()

    rel_dir = "plugins/packages" if plugin_id in REPO_ONLY else "assets/plugins"
    return {
        "path": f"{rel_dir}/{name}",
        "sha256": digest,
        "sizeBytes": os.path.getsize(dest),
    }


def main() -> None:
    entries = []

    for plugin_id in sorted(os.listdir(SRC_ROOT)):
        plugin_dir = os.path.join(SRC_ROOT, plugin_id)
        manifest_path = os.path.join(plugin_dir, "plugin.json")
        if not os.path.isfile(manifest_path):
            continue

        with open(manifest_path, encoding="utf-8") as handle:
            manifest = json.load(handle)

        package = pack(plugin_dir, manifest)
        entries.append(
            {
                "id": manifest["id"],
                "name": manifest["name"],
                "version": manifest["version"],
                "contract": manifest["contract"],
                "description": manifest.get("description", ""),
                "icon": manifest.get("icon", ""),
                # 权限必须写进索引：安装前要弹窗告知用户"它能干什么"，
                # 而那时候包还没下载，读不到 plugin.json。
                # 从 manifest 复制而不是手写，避免索引和包内声明对不上。
                "permissions": manifest.get("permissions", []),
                "package": package,
            }
        )
        print(f"packed {manifest['id']} v{manifest['version']} -> {package['path']} "
              f"({package['sizeBytes']} bytes, {package['sha256'][:12]}…)")

    # 索引永远随包（断网时它就是货架的全部内容）
    #
    # publishedAt 是给客户端**比新旧**用的：几个 CDN 节点里有的会缓存住旧的
    # （jsDelivr 对 @main 的解析结果缓存很久，purge 也不一定刷得掉），
    # 客户端并发取多份、挑 publishedAt 最大的那份，才不会被最慢的节点拖回去。
    index = {
        "schemaVersion": 1,
        "publishedAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "plugins": entries,
    }
    index_path = os.path.join(BUNDLED_DIR, "index.json")
    with open(index_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(index, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print(f"wrote {index_path} with {len(entries)} plugin(s)")


if __name__ == "__main__":
    main()
