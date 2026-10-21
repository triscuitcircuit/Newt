#!/usr/bin/env python3

import pathlib
import shutil
import subprocess
import sys
import tempfile

source = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="newt-core-boundary-") as temp:
    root = pathlib.Path(temp)
    isolated = root / "source"
    shutil.copytree(source, isolated, ignore=shutil.ignore_patterns(
        "build*", "cmake-build*", ".git", ".godot", "__pycache__",
        "dist", ".deps", "out", "install", "stage"))
    def run(*args, **kwargs):
        subprocess.run(args, check=True, **kwargs)
    build, prefix = root / "build", root / "install"
    run("cmake", "-S", str(isolated), "-B", str(build),
        "-DNEWT_WITH_USB=OFF", *sys.argv[1:])
    run("cmake", "--build", str(build), "--parallel", "4")
    run("ctest", "--test-dir", str(build), "--output-on-failure")
    run("cmake", "--install", str(build), "--prefix", str(prefix))
    consumer = root / "consumer"
    run("cmake", "-S", str(isolated / "tests/core-consumer"), "-B", str(consumer),
        *sys.argv[1:], f"-DNewt_DIR={prefix}/lib/cmake/Newt")
    run("cmake", "--build", str(consumer))
    import os
    env = dict(os.environ, XR_RUNTIME_JSON=str(root / "missing-runtime.json"),
               XR_API_LAYER_PATH=str(root / "no-api-layers"))
    run(str(consumer / "core-consumer"), env=env)
print("Core-only source build and installed C++ consumer passed.")
