import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("patch_voxel_mod", Path(__file__).resolve().parents[1] / "ports/web/patch_voxel_mod.py")
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


class PatchVoxelModTest(unittest.TestCase):
    def archive(self, path, version="1.9.6"):
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("manifest.json", json.dumps({"id": "potato_voxel", "version": version}))
            archive.writestr("lib/ShadowMap.lua", patch.OLD)
            archive.writestr("lib/ChunkMesher.lua", patch.MESH_OLD)
            archive.writestr("lib/QualityMode.lua", patch.QUALITY_OLD)
            archive.writestr("assets/example.bin", b"unchanged art")

    def test_only_targeted_sources_change(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.zip", Path(directory) / "output.zip"
            self.archive(source)
            before = source.read_bytes()
            patch.patch_zip(source, output)
            self.assertEqual(source.read_bytes(), before)
            with zipfile.ZipFile(source) as original, zipfile.ZipFile(output) as changed:
                for entry in original.namelist():
                    expected = {"lib/ShadowMap.lua": patch.NEW, "lib/ChunkMesher.lua": patch.MESH_NEW,
                                "lib/QualityMode.lua": patch.QUALITY_NEW}
                    self.assertEqual(changed.read(entry), expected.get(entry, original.read(entry)))
            with self.assertRaises(FileExistsError):
                patch.patch_zip(source, output)

    def test_refuses_other_versions_and_in_place_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.zip", Path(directory) / "output.zip"
            self.archive(source, "2.0.0")
            with self.assertRaises(ValueError):
                patch.patch_zip(source, output)
            self.assertFalse(output.exists())
            with self.assertRaises(ValueError):
                patch.patch_zip(source, source)
