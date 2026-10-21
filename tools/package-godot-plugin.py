#!/usr/bin/env python3
"""Build a deterministic Godot addon ZIP from the canonical addon source."""
import argparse
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def package(output):
    source = ROOT / 'addons/newt_bridge'
    example = ROOT / 'examples/godot/addons/newt_bridge'
    files = sorted(p for p in source.rglob('*') if p.is_file() and
                   '__pycache__' not in p.parts and not p.name.endswith('.pyc'))
    for name in ('plugin.cfg', 'plugin.gd', 'session.gd', 'export_plugin.gd', 'LICENSE'):
        if not (source / name).is_file():
            raise ValueError(f'Missing addon file: {name}')
    # The addon no longer bundles the session manager: plugin.gd/session.gd
    # locate the installed native `newtd` binary instead of a copied script.
    if (source / 'newt.py').exists():
        raise ValueError('Addon must not bundle newt.py; the native newtd binary is the session manager.')
    for path in files:
        copy = example / path.relative_to(source)
        if not copy.is_file() or copy.read_bytes() != path.read_bytes():
            raise ValueError(f'Example addon is out of sync: {copy}')
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            info = zipfile.ZipInfo(path.relative_to(ROOT).as_posix(), date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())
    print(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/newt-godot-plugin.zip')
    args = parser.parse_args()
    package(args.output.resolve())
