#!/usr/bin/env python3
"""Print installed/build-tree dependency paths without loading any XR runtime."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root',type=Path,action='append',default=[],help='Also search a source/build directory for OpenXRConfig.cmake and runtime manifests')
args=parser.parse_args()
print('VULKAN_SDK (directory, not a dylib):')
for path in sorted((Path.home()/'VulkanSDK').glob('*/macOS')):
    if (path/'include/vulkan/vulkan.h').exists(): print(' ',path)
roots=[Path.home()/'.local',Path('/opt/homebrew/lib/cmake'),Path('/usr/local/lib/cmake')]+args.root
found=set()
for root in roots:
    root=root.expanduser().resolve()
    if not root.is_dir():continue
    for directory,children,files in os.walk(root):
        children[:]=[x for x in children if not x.startswith('.') and x not in ('node_modules','__pycache__')]
        for name in ('OpenXRConfig.cmake','monado-runtime.json','MoltenVK_icd.json'):
            if name in files:
                path=Path(directory)/name
                if path in found:continue
                found.add(path)
                print(('OpenXR_DIR: ' + str(path.parent)) if name=='OpenXRConfig.cmake' else ('Runtime/ICD manifest: '+str(path)))
print('newt-demo:',shutil.which('newt-demo') or str(Path.home()/'.local/bin/newt-demo'))
if shutil.which('pkg-config'):
    result=subprocess.run(['pkg-config','--variable=libdir','libusb-1.0'],capture_output=True,text=True)
    print('libusb directory:',result.stdout.strip() or 'not found (optional)')
print('Python:',shutil.which('python3') or 'not found')
