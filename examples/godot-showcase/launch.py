#!/usr/bin/env python3
"""Launch Godot or an exported game with an explicitly selected OpenXR runtime."""
# SPDX-License-Identifier: MIT
import argparse
import json
import os
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', required=True, type=Path, help='OpenXR runtime JSON manifest')
parser.add_argument('--icd', type=Path, help='Optional Vulkan ICD JSON manifest')
parser.add_argument('--godot', default='godot', help='Godot executable, with OpenXR and Vulkan support')
parser.add_argument('--game', type=Path, help='Exported game executable; omit to run the example project')
args = parser.parse_args()
runtime = args.runtime.resolve(strict=True)
manifest = json.loads(runtime.read_text())
if not manifest.get('runtime', {}).get('library_path'):
    parser.error('runtime manifest is missing runtime.library_path')
env = os.environ.copy()
env['XR_RUNTIME_JSON'] = str(runtime)
if args.icd:
    env['VK_ICD_FILENAMES'] = str(args.icd.resolve(strict=True))
if args.game:
    executable = str(args.game.resolve(strict=True))
    command = [executable]
else:
    executable = shutil.which(args.godot)
    if not executable:
        parser.error('Godot executable was not found')
    command = [executable, '--path', str(Path(__file__).resolve().parent)]
command += ['--xr-mode', 'on', '--rendering-method', 'mobile', '--rendering-driver', 'vulkan']
os.execve(executable, command, env)
