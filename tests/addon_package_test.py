#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('packager', ROOT/'tools/package-godot-plugin.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class AddonPackageTest(unittest.TestCase):
    def test_archive_and_drift_detection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ('addons/newt_bridge', 'examples/godot/addons/newt_bridge'):
                shutil.copytree(ROOT/name, root/name)
            (root/'tools').mkdir()
            cache = root/'addons/newt_bridge/__pycache__'
            cache.mkdir(exist_ok=True)
            (cache/'test.pyc').write_bytes(b'not-source')
            original = packager.ROOT
            packager.ROOT = root
            try:
                first, second = root/'one.zip', root/'two.zip'
                packager.package(first)
                packager.package(second)
                self.assertEqual(first.read_bytes(), second.read_bytes())
                with zipfile.ZipFile(first) as archive:
                    names = archive.namelist()
                    self.assertIn('addons/newt_bridge/plugin.cfg', names)
                    self.assertIn('addons/newt_bridge/LICENSE', names)
                    self.assertTrue(all(n.startswith('addons/newt_bridge/') for n in names))
                    self.assertFalse(any('__pycache__' in n for n in names))
                (root/'examples/godot/addons/newt_bridge/plugin.gd').write_text('stale')
                with self.assertRaisesRegex(ValueError, 'out of sync'):
                    packager.package(root/'bad.zip')
                (root/'addons/newt_bridge/newt.py').write_text('bundled manager copy')
                with self.assertRaisesRegex(ValueError, 'must not bundle newt.py'):
                    packager.package(root/'bad.zip')
            finally:
                packager.ROOT = original


if __name__ == '__main__':
    unittest.main()
