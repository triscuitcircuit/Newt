#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
import argparse
from pathlib import Path
import shutil
parser=argparse.ArgumentParser(description='Install the Newt Play Bridge into a Godot project')
parser.add_argument('project',type=Path)
args=parser.parse_args()
project=args.project.expanduser().resolve(strict=True)
if not (project/'project.godot').is_file(): parser.error('Not a Godot project directory')
destination=project/'addons/newt_bridge'
if destination.exists(): parser.error('Plugin already exists; remove or archive it explicitly before replacing it')
source=Path(__file__).resolve().parents[1]/'addons/newt_bridge'
shutil.copytree(source,destination,ignore=shutil.ignore_patterns('__pycache__','*.uid'))
print(f'Installed {destination}. Enable Newt Play Bridge in Project Settings > Plugins.')
