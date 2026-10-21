#!/usr/bin/env python3

import json
import os
from pathlib import Path
import subprocess
import threading
import time

root = Path(__file__).resolve().parents[2]
app = root / 'pippinVR-Server/PippinVR Dev.app'
helper = app / 'Contents/MacOS/pippinvr-xr'
config = json.loads((Path.home() / 'Library/Application Support/Newt/config.json').read_text())
if subprocess.run(['pgrep', '-x', 'pippinvr-xr'], stdout=subprocess.DEVNULL).returncode == 0:
    raise SystemExit('Disconnect the current USB session before running this comparison.')
logs = Path('/tmp') / time.strftime('newt-capture-comparison-%Y%m%d-%H%M%S')
logs.mkdir()
environment = dict(os.environ)
environment.update(config.get('dashboard_env', {}))
environment.update(XR_RUNTIME_JSON=str(app / 'Contents/Resources/OpenXR/monado-runtime.json'),
                   VK_ICD_FILENAMES=str(app / 'Contents/Resources/OpenXR/MoltenVK_icd.json'))
for key in ('NEWT_HOST_EVENTS', 'NEWT_APPS_FILE', 'NEWT_ALLOW_SIMULATED'):
    environment.pop(key, None)
(logs / 'settings.json').write_text(json.dumps({k:v for k,v in environment.items()
    if k.startswith(('NEWT_', 'QL_OVERRIDE_'))}, indent=2))
print(f'Logs: {logs}', flush=True)
print('Keep the headset awake. Two sessions will run for 40 seconds each after startup.', flush=True)
for mode, value in [('cpu', '0'), ('gpu', '1')]:
    print(f'\nStarting {mode.upper()} capture...', flush=True)
    started = threading.Event()
    with (logs / f'{mode}.log').open('w') as log:
        child = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True,
                                 env=dict(environment, NEWT_GPU_CAPTURE=value))
        def pump():
            for line in child.stdout:
                log.write(line); log.flush()
                if 'session running.' in line: started.set()
                if any(s in line for s in ('frame stages', 'rendered ', 'GPU capture active',
                                           'SCShareableContent fallback', 'streaming Display', 'fatal:')):
                    print(line.rstrip(), flush=True)
        reader = threading.Thread(target=pump, daemon=True)
        reader.start()
        try:
            deadline = time.monotonic() + 60
            while not started.wait(0.2) and child.poll() is None and time.monotonic() < deadline:
                pass
            if started.is_set():
                deadline = time.monotonic() + 40
                while child.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.2)
        finally:
            if child.poll() is None:
                try: child.stdin.write('stop\n'); child.stdin.flush()
                except BrokenPipeError: pass
                try: child.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
            reader.join(timeout=3)
        print(f'{mode.upper()} exit: {child.returncode}', flush=True)
        if not started.is_set():
            raise SystemExit(f'Headset session did not start; see {logs / (mode + ".log")}')
    time.sleep(2)
print(f'Comparison finished. Logs: {logs}', flush=True)
