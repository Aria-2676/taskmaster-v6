"""把 assets/plugins_src/<id>/ 打包成 assets/plugins/<id>_v<version>.zip，
并重新生成 assets/plugins/index.json。

为什么要有这个脚本：索引里的 sha256 必须与 zip 的字节完全一致，
手写一定会对不上。zip 的时间戳固定成 1980-01-01，保证同样的源
每次打出来的 hash 相同，不会产生无意义的 diff。

用法（在项目根目录）：
    python tool/make_demo_plugin.py
"""

import hashlib
import json
import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_ROOT = os.path.join(ROOT, "assets", "plugins_src")
OUT_DIR = os.path.join(ROOT, "assets", "plugins")

FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def pack(plugin_dir: str, manifest: dict) -> dict:
    plugin_id = manifest["id"]
    version = manifest["version"]
    name = f"{plugin_id}_v{version}.zip"
    dest = os.path.join(OUT_DIR, name)

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
            info = zipfile.ZipInfo(relative, date_time=FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)

    with open(dest, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()

    return {
        "path": f"assets/plugins/{name}",
        "sha256": digest,
        "sizeBytes": os.path.getsize(dest),
    }


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
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

    index = {"schemaVersion": 1, "plugins": entries}
    index_path = os.path.join(OUT_DIR, "index.json")
    with open(index_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(index, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print(f"wrote {index_path} with {len(entries)} plugin(s)")


if __name__ == "__main__":
    main()
