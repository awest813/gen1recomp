import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "prepare_pages_site", ROOT / "scripts" / "prepare_pages_site.py"
)
prepare_pages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_pages)


class PagesSiteTest(unittest.TestCase):
    def site(self, directory, payload=b"data"):
        base = Path(directory)
        (base / "index.html").write_text("<html></html>", encoding="utf-8")
        (base / "game.data").write_bytes(payload)
        return base

    def test_writes_nojekyll_and_project_404(self):
        with tempfile.TemporaryDirectory() as directory:
            base = self.site(directory)
            prepare_pages.prepare(base)
            self.assertEqual((base / ".nojekyll").read_bytes(), b"")
            page = (base / "404.html").read_text(encoding="utf-8")
            self.assertIn('id="home"', page)
            self.assertIn("location.pathname", page)

    def test_pages_limit_names_the_oversized_file(self):
        with tempfile.TemporaryDirectory() as directory:
            base = self.site(directory, b"x" * 40)
            with self.assertRaises(ValueError) as caught:
                prepare_pages.prepare(base, max_bytes=16)
            self.assertIn("game.data", str(caught.exception))
            self.assertTrue((base / ".nojekyll").is_file())

    def test_missing_index_does_not_write_a_partial_site(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            with self.assertRaises(ValueError):
                prepare_pages.prepare(base)
            self.assertFalse((base / ".nojekyll").exists())
            self.assertFalse((base / "404.html").exists())


if __name__ == "__main__":
    unittest.main()
