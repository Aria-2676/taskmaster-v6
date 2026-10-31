# 打包脚本的自检：重打包必须幂等。
#
# 为什么单独测这个：索引里的 sha256 指向 zip 的**字节**，而 zip 的字节不只是
# 内容决定的 —— deflate 的输出随 zlib 版本变。换台机器重打一次包，内容一个
# 字节没改，sha 也能变；这时索引和线上文件就对不上，新装用户校验失败，
# 报出来像网络问题。所以"同样的源打两次，第二次不许动字节"是硬要求。
#
# 跑法（仓库根目录，无需 pytest）：
#     python test/plugin_packaging/test_make_demo_plugin.py

import hashlib
import importlib.util
import io
import json
import shutil
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_SPEC = importlib.util.spec_from_file_location(
    "make_demo_plugin", ROOT / "tool" / "make_demo_plugin.py"
)
packer = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(packer)


class RepackIsIdempotent(unittest.TestCase):
    def setUp(self):
        self._originals = {
            name: getattr(packer, name)
            for name in ("SRC_ROOT", "BUNDLED_DIR", "REPO_DIR", "REPO_ONLY")
        }
        self.tmp = Path(tempfile.mkdtemp(prefix="pack_test_"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

        self.src = self.tmp / "src"
        self.bundled = self.tmp / "bundled"
        self.repo = self.tmp / "repo"
        self.plugin = self.src / "demo"
        self.plugin.mkdir(parents=True)
        self._write("plugin.json", json.dumps(
            {"id": "demo", "name": "示例", "version": "1.0.0", "contract": 1},
            ensure_ascii=False,
        ))
        self._write("index.html", "<h1>hello</h1>\n")

        packer.SRC_ROOT = str(self.src)
        packer.BUNDLED_DIR = str(self.bundled)
        packer.REPO_DIR = str(self.repo)
        packer.REPO_ONLY = set()

    def tearDown(self):
        for name, value in self._originals.items():
            setattr(packer, name, value)

    # ---- 工具 ----

    def _write(self, name: str, text: str, newline: str = "\n") -> None:
        path = self.plugin / name
        with open(path, "w", encoding="utf-8", newline=newline) as handle:
            handle.write(text)

    def _run(self) -> str:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            packer.main()
        return buffer.getvalue()

    @property
    def _zip(self) -> Path:
        return self.bundled / "demo_v1.0.0.zip"

    def _digest(self) -> str:
        return hashlib.sha256(self._zip.read_bytes()).hexdigest()

    def _index_entry(self) -> dict:
        raw = (self.bundled / "index.json").read_text(encoding="utf-8")
        return json.loads(raw)["plugins"][0]

    def _assert_index_matches_file(self) -> None:
        """索引里的 sha 必须等于磁盘上那个包的 sha —— 这是这套东西的全部意义。"""
        self.assertEqual(self._index_entry()["package"]["sha256"], self._digest())
        self.assertEqual(self._index_entry()["package"]["sizeBytes"], self._zip.stat().st_size)

    # ---- 断言 ----

    def test_第二次打包不动字节(self):
        self._run()
        first = self._digest()
        self._assert_index_matches_file()

        output = self._run()
        self.assertEqual(self._digest(), first, "内容没变，zip 字节就不该变")
        self.assertIn("reuse", output, "应该走「保留旧文件」那条路，而不是重写")
        self._assert_index_matches_file()

    def test_换行符不同也算同一份内容(self):
        # 仓库开了 core.autocrlf：同一份源码在不同检出状态下是 CRLF / LF 两种字节。
        # 打包器归一化之后，两者应该产出同一个包。
        self._run()
        first = self._digest()

        self._write("index.html", "<h1>hello</h1>\n", newline="\r\n")
        self._run()

        self.assertEqual(self._digest(), first, "CRLF 与 LF 必须打成同一个包")

    def test_内容真变了就重打且摘要变化(self):
        self._run()
        first = self._digest()

        self._write("index.html", "<h1>hello, world</h1>\n")
        output = self._run()

        self.assertNotIn("reuse", output)
        self.assertNotEqual(self._digest(), first, "内容变了必须重打")
        self._assert_index_matches_file()

    def test_旧包损坏会被覆盖(self):
        self.bundled.mkdir(parents=True)
        self._zip.write_bytes(b"not a zip")

        self._run()

        with zipfile.ZipFile(self._zip) as archive:
            self.assertEqual(archive.read("index.html"), b"<h1>hello</h1>\n")
        self._assert_index_matches_file()

    def test_新增或删除文件不会被当成同一份(self):
        self._run()
        first = self._digest()

        self._write("extra.txt", "more\n")
        self._run()
        self.assertNotEqual(self._digest(), first, "多一个文件就是新内容")
        self._assert_index_matches_file()


if __name__ == "__main__":
    unittest.main(verbosity=2)
