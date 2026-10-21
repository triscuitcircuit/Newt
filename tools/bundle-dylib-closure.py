#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Copy the non-system dylib closure of given libraries into a directory.

Each copied dylib is relinked so it and its non-system dependencies resolve
via @loader_path, making the directory self-contained and relocatable.
Generalized from the proven otool/install_name_tool chase in Pippin's
bundle-monado-runtime.sh; used by `newtd bundle` at standalone-export
time (developer Mac only). No binaries are supplied: callers pass explicit
source dylibs they built themselves.

Usage: bundle-dylib-closure.py [--search-dir DIR ...] DEST_DIR DYLIB [...]
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

OTOOL = "/usr/bin/otool" if os.path.exists("/usr/bin/otool") else "otool"
INSTALL_NAME_TOOL = ("/usr/bin/install_name_tool"
                     if os.path.exists("/usr/bin/install_name_tool")
                     else "install_name_tool")
CODESIGN = "/usr/bin/codesign" if os.path.exists("/usr/bin/codesign") else "codesign"

DEFAULT_SEARCH_DIRS = [
    Path("/opt/homebrew/lib"),
    Path("/usr/local/lib"),
]


def load_commands(path):
    output = subprocess.check_output([OTOOL, "-L", str(path)], text=True)
    deps = []
    for line in output.splitlines():
        # Dependency lines are indented; architecture headers are not. This
        # also keeps paths containing spaces intact.
        if line[:1].isspace() and " (compatibility" in line:
            deps.append(line.strip().split(" (compatibility", 1)[0])
    return deps


def is_system(path):
    return path.startswith(("/usr/lib/", "/System/"))


def install_basename(path):
    # Version symlinks often resolve libfoo.1.dylib -> libfoo.1.2.3.dylib.
    # The destination must use the LC_ID_DYLIB name dependents reference.
    try:
        output = subprocess.check_output([OTOOL, "-D", str(path)], text=True)
        for line in output.splitlines()[1:]:
            value = line.strip()
            if value.endswith(".dylib"):
                return Path(value).name
    except subprocess.CalledProcessError:
        pass
    return path.name


def resolve(dep, loader_dir, search_dirs):
    if os.path.exists(dep):
        return Path(dep)
    if dep.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
        name = Path(dep).name
        # Prefer the canonical installed copy (where @rpath deps already
        # resolve from) over a possibly stale staging copy next to the
        # referencing dylib.
        for directory in search_dirs:
            candidate = directory / name
            if candidate.exists():
                return candidate
        if dep.startswith(("@loader_path/", "@executable_path/")):
            candidate = loader_dir / name
            if candidate.exists():
                return candidate
    return None


def bundle_closure(dest, roots, search_dirs, sign_identity="-"):
    """Copy+relink the closure of `roots` into `dest`. Returns basenames."""
    search_dirs = list(search_dirs)
    for root in roots:
        if root.parent not in search_dirs:
            search_dirs.append(root.parent)
    queue = list(roots)
    by_basename = {}
    by_realpath = {}
    while queue:
        source = queue.pop(0)
        if not source.exists():
            raise SystemExit(f"missing dependency: {source}")
        real = Path(os.path.realpath(source))
        basename = install_basename(real)
        if real in by_realpath:
            continue
        prior = by_basename.get(basename)
        if prior is not None and prior != real:
            raise SystemExit(
                f"conflicting dylibs named {basename}: {prior} and {real}")
        by_basename[basename] = real
        by_realpath[real] = basename
        for dep in load_commands(real):
            if is_system(dep) or Path(dep).name == basename:
                continue
            resolved = resolve(dep, real.parent, search_dirs)
            if resolved is None:
                raise SystemExit(
                    f"unresolved non-system dependency {dep!r} from {real}")
            queue.append(resolved)

    dest.mkdir(parents=True, exist_ok=True)
    for basename, source in sorted(by_basename.items()):
        target = dest / basename
        shutil.copy2(source, target)
        target.chmod(0o755)

    for basename in sorted(by_basename):
        target = dest / basename
        subprocess.check_call(
            [INSTALL_NAME_TOOL, "-id", f"@loader_path/{basename}", str(target)])
        for dep in list(load_commands(target)):
            if is_system(dep) or Path(dep).name == basename:
                continue
            dep_name = Path(dep).name
            if dep_name not in by_basename:
                raise SystemExit(
                    f"unbundled dependency {dep!r} referenced by {basename}")
            subprocess.check_call(
                [INSTALL_NAME_TOOL, "-change", dep,
                 f"@loader_path/{dep_name}", str(target)])
        # install_name_tool invalidates signatures; arm64 dylibs must be
        # signed (ad-hoc by default) to load at all.
        subprocess.check_call(
            [CODESIGN, "--force", "--sign", sign_identity, str(target)],
            stdout=subprocess.DEVNULL)
    return sorted(by_basename)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--search-dir", action="append", type=Path, default=[],
                        help="Extra directory to resolve @rpath deps from (repeatable)")
    parser.add_argument("--sign", default=os.environ.get("CODESIGN_IDENTITY", "-"),
                        help="codesign identity for copied dylibs (default: $CODESIGN_IDENTITY or -)")
    parser.add_argument("dest", type=Path)
    parser.add_argument("dylibs", type=Path, nargs="+")
    args = parser.parse_args()
    search_dirs = [Path(d) for d in args.search_dir] + DEFAULT_SEARCH_DIRS
    search_dirs += sorted(Path("/opt/homebrew/opt").glob("*/lib"))
    names = bundle_closure(args.dest, args.dylibs, search_dirs, args.sign)
    print(f"bundled {len(names)} dylibs")
    for name in names:
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
