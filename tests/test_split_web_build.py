"""ROM-free loader checks. Run with python -m unittest discover -s tests -p test_split_web_build.py."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("split_web_build", ROOT / "scripts/split_web_build.py")
split = importlib.util.module_from_spec(spec)
spec.loader.exec_module(split)


class SplitWebBuildTest(unittest.TestCase):
    def test_invalid_template_preserves_build(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "game.data").write_bytes(b"original")
            (base / "game.js").write_text("changed template", encoding="utf-8")
            (base / "game.data.part000").write_bytes(b"previous")
            result = subprocess.run([os.sys.executable, str(ROOT / "scripts/split_web_build.py"), directory], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((base / "game.data").read_bytes(), b"original")
            self.assertEqual((base / "game.data.part000").read_bytes(), b"previous")

    def test_rejects_zero_chunk_size(self):
        with self.assertRaises(ValueError):
            split.make_patched_fetch(0)

    def test_loader_completion_failure_and_concurrency(self):
        node = os.environ.get("NODE") or shutil.which("node")
        self.assertIsNotNone(node, "Set NODE to a Node.js executable to test the generated loader")
        loader = split.make_patched_fetch(4)
        script = loader + r'''
const assert = require('node:assert/strict');
let requests, successes, errors, value;
const Module = {};
class XMLHttpRequest {
  open(method, url) { this.url = url; }
  send() { requests.push(this); }
  abort() { this.aborted = true; }
}
function begin(size, name = 'game.data') {
  requests = []; successes = errors = 0;
  fetchRemotePackage(name, size, data => { successes++; value = new Uint8Array(data); }, () => errors++);
}
function complete(index, bytes, status = 200) {
  const xhr = requests[index]; xhr.status = status; xhr.response = new Uint8Array(bytes).buffer; xhr.onload();
}
begin(25);
assert.equal(requests.length, 4);
complete(2, [8,9,10,11]); complete(0, [0,1,2,3]); complete(3, [12,13,14,15]);
assert.equal(requests.length, 7);
complete(1, [4,5,6,7]); complete(6, [24]); complete(5, [20,21,22,23]); complete(4, [16,17,18,19]);
assert.equal(successes, 1); assert.equal(errors, 0);
assert.deepEqual([...value], Array.from({length:25}, (_, i) => i));
for (const bad of [[1,2], [1,2,3,4,5]]) {
  begin(17); complete(0, bad);
  assert.equal(errors, 1); assert.equal(successes, 0);
  assert.ok(requests.slice(1).every(xhr => xhr.aborted));
  complete(1, [4,5,6,7]); requests[2].onerror();
  assert.equal(errors, 1); assert.equal(requests.length, 4);
}
for (const event of ['onerror', 'ontimeout']) {
  begin(17); requests[0][event]();
  assert.equal(errors, 1); assert.ok(requests.every(xhr => xhr.aborted));
}
begin(17); complete(0, [0,1,2,3], 404); assert.equal(errors, 1);
begin(0); assert.equal(successes, 1); assert.equal(requests.length, 0);
begin(4004);
for (let i = 0; i < 1001; i++) complete(i, [0,0,0,0]);
assert.equal(requests[1000].url, 'game.data.part1000'); assert.equal(successes, 1);
begin(4, '/project/game.data?g1r-build=abc123');
assert.equal(requests[0].url, '/project/game.data.part000?g1r-build=abc123');
complete(0, [0,1,2,3]);assert.equal(successes, 1);
console.log('loader checks passed');
'''
        subprocess.run([node, "-e", script], check=True)


if __name__ == "__main__":
    unittest.main()
