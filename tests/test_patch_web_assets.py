import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stamp_web_assets", ROOT / "scripts/stamp_web_assets.py")
stamp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stamp)


class WebAssetVersionTest(unittest.TestCase):
    def prepare(self, directory):
        base = Path(directory)
        (base / "index.html").write_text((ROOT / "ports/web/shell/index.html").read_text(), encoding="utf-8")
        for name in ("game.js", "love.js", "love.wasm", "game.data"):
            (base / name).write_bytes(name.encode())
        return base

    def test_runtime_payload_and_loader_updates_invalidate_urls(self):
        with tempfile.TemporaryDirectory() as directory:
            base = self.prepare(directory)
            original = stamp.stamp(base)
            self.assertEqual(stamp.stamp(base), original)
            for name in ("game.js", "love.js", "love.wasm", "game.data"):
                (base / name).write_bytes(b"updated" + name.encode())
                current = stamp.stamp(base)
                self.assertNotEqual(current, original)
                page = (base / "index.html").read_text()
                self.assertIn('content="' + current + '"', page)
                self.assertIn('game.js?g1r-build=' + current, page)
                self.assertIn('love.js?g1r-build=' + current, page)
                original = current

    def test_split_payload_is_versioned_and_errors_preserve_page(self):
        with tempfile.TemporaryDirectory() as directory:
            base = self.prepare(directory)
            (base / "game.data").unlink()
            (base / "game.data.part000").write_bytes(b"one")
            first = stamp.stamp(base)
            (base / "game.data.part000").write_bytes(b"two")
            self.assertNotEqual(first, stamp.stamp(base))
            before = (base / "index.html").read_bytes()
            (base / "love.wasm").unlink()
            with self.assertRaises(FileNotFoundError):
                stamp.stamp(base)
            self.assertEqual((base / "index.html").read_bytes(), before)
            (base / "love.wasm").write_bytes(b"wasm")
            (base / "index.html").write_text("changed template", encoding="utf-8")
            with self.assertRaises(ValueError):
                stamp.stamp(base)
            self.assertEqual((base / "index.html").read_text(), "changed template")


if __name__ == "__main__":
    unittest.main()
