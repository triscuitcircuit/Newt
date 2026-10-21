#!/usr/bin/env python3

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import plistlib
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]

if os.environ.get('NEWT_SERVE_CMD'):
    SERVE_CMD=shlex.split(os.environ['NEWT_SERVE_CMD']);CLI_CMD=SERVE_CMD[:-1]
else:
    _candidates=[os.environ.get('NEWTD'),str(ROOT/'build/newtd'),str(ROOT/'build-install/newtd'),shutil.which('newtd')]
    NEWTD=next((c for c in _candidates if c and os.access(c,os.X_OK)),None)
    assert NEWTD,'No newtd found: build Newt first (or set NEWTD / NEWT_SERVE_CMD)'
    CLI_CMD=[str(Path(NEWTD).resolve())];SERVE_CMD=CLI_CMD+['serve']
NEWTD=CLI_CMD[0]

os.environ.setdefault('NEWT_DYLIB_CLOSURE_TOOL', str(ROOT/'tools/bundle-dylib-closure.py'))

def request(endpoint,message):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(12)
        client.connect(str(endpoint))
        client.sendall(json.dumps(message).encode()+b'\n')
        data=bytearray()
        while b'\n' not in data:
            chunk=client.recv(4096)
            if not chunk:raise ValueError('Incomplete response')
            data.extend(chunk)
    return json.loads(data.split(b'\n',1)[0])

def ipc_hash(bundle_id):
    return hashlib.sha256(bundle_id.encode()).hexdigest()[:12]

def wait_for(check, timeout=8):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        result=check()
        if result:return result
        time.sleep(.05)
    raise AssertionError('Timed out')

with tempfile.TemporaryDirectory(prefix='newt-session-test-') as raw:
    root=Path(raw).resolve()
    state=root/'state';state.mkdir(mode=0o700)
    ipc=root/'ipc';ipc.mkdir(mode=0o700)
    events=root/'events'
    runtime=root/'runtime.json';runtime.write_text(json.dumps({'runtime':{'library_path':'./fake.dylib'}}))
    (root/'fake.dylib').write_text('not loaded by fake programs')
    emit=root/'emit'
    helper=root/'dashboard'
    helper.write_text(f'#!{sys.executable}\nfrom pathlib import Path\nimport os,sys,threading,time\np=Path({str(events)!r})\ne=Path({str(emit)!r})\ndef watch():\n while True:\n  time.sleep(.05)\n  if e.exists():\n   n=e.read_text().strip();e.unlink()\n   print(f"NEWT_REQUEST:{{n}}",flush=True)\nthreading.Thread(target=watch,daemon=True).start()\nwith p.open("a") as f:f.write("dashboard-start\\n")\nwith p.open("a") as f:f.write(f"env:NEWT_TEST_PROBE={{os.environ.get(\'NEWT_TEST_PROBE\',\'\')}}\\n")\nfor line in sys.stdin:\n s=line.strip()\n if s=="stop":break\n with p.open("a") as f:f.write(f"command:{{s}}\\n")\nwith p.open("a") as f:f.write("dashboard-stop\\n")\n')
    helper.chmod(0o755)
    game=root/'game'
    game.write_text(f'#!{sys.executable}\nfrom pathlib import Path\nimport os,time\nassert os.environ["XR_RUNTIME_JSON"]=={str(runtime)!r}\nwith Path({str(events)!r}).open("a") as f:f.write("game-start\\n")\ntime.sleep(.4)\nraise SystemExit(7)\n')
    game.chmod(0o755)
    game2=root/'game2'
    game2.write_text(f'#!{sys.executable}\nfrom pathlib import Path\nimport time\nwith Path({str(events)!r}).open("a") as f:f.write("game2-start\\n")\ntime.sleep(.2)\n')
    game2.chmod(0o755)
    long_game=root/'long_game'
    long_game.write_text(f'#!{sys.executable}\nfrom pathlib import Path\nimport time\nwith Path({str(events)!r}).open("a") as f:f.write("long-game-start\\n")\ntime.sleep(30)\n')
    long_game.chmod(0o755)
    missing_env={k:v for k,v in os.environ.items() if not k.startswith('NEWT_BOOTSTRAP_')}
    missing_env.update(NEWT_STATE_DIR=str(state),NEWT_IPC_DIR=str(ipc))
    missing=subprocess.run(CLI_CMD+['start'],env=missing_env,capture_output=True,text=True,timeout=10)
    assert missing.returncode!=0 and 'Configure Newt' in missing.stderr and 'loader' in missing.stderr,(missing.stdout,missing.stderr)
    (state/'config.json').write_text(json.dumps({'dashboard':str(helper),'runtime':str(runtime),'startup_timeout':1,'apps':[{'title':'First','game':str(game)},{'title':'Second','game':str(game2)}]}))
    env={k:v for k,v in os.environ.items() if not k.startswith('NEWT_BOOTSTRAP_')}
    env.update(NEWT_STATE_DIR=str(state),NEWT_IPC_DIR=str(ipc))
    endpoint=ipc/'session.sock'
    def call(action,**values):return request(endpoint,dict(action=action,**values))
    def ready():
        try:return call('status')
        except (FileNotFoundError,ConnectionRefusedError):return False
    process=subprocess.Popen(SERVE_CMD,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    external=None
    try:
        wait_for(ready)
        wait_for(lambda: events.exists() and 'dashboard-start' in events.read_text())
        assert not call('launch',argv=['/does/not/exist'])['ok']
        assert call('status')['state']=='dashboard'
        assert call('launch',argv=[str(game)],cwd=str(root))['ok']
        assert not call('launch',argv=[str(game)])['ok']
        wait_for(lambda:call('status')['last_game_exit']==7)
        wait_for(lambda:events.read_text().count('dashboard-start')==2)
        assert [l for l in events.read_text().splitlines() if not l.startswith('env:')][:3]==['dashboard-start','dashboard-stop','game-start']
        print('PASS: validated launch, exclusive handoff, runtime environment, return after game failure')
        reply=call('prepare');assert reply['ok'] and reply['environment']['XR_RUNTIME_JSON']==str(runtime)
        assert not call('prepare')['ok']
        assert not call('attach',token='wrong',pid=os.getpid())['ok']
        external=subprocess.Popen([sys.executable,'-c','import time;time.sleep(10)'])
        assert call('attach',token=reply['token'],pid=external.pid)['ok']
        assert call('status')['state']=='game'
        external.terminate();external.wait();external=None
        wait_for(lambda:call('status')['state']=='dashboard')
        print('PASS: editor reservation, invalid-token rejection, external process exit restores dashboard')
        assert call('prepare')['ok']
        wait_for(lambda:call('status')['state']=='dashboard')
        assert 'timed out' in call('status')['error']
        print('PASS: abandoned Play reservation expires and restores dashboard')
        starts=events.read_text().count('game-start')
        emit.write_text('3')
        wait_for(lambda:events.read_text().count('game-start')==starts+1)
        wait_for(lambda:call('status')['state']=='dashboard')
        lines=events.read_text().splitlines()
        gi=len(lines)-1-lines[::-1].index('game-start')
        assert lines[gi-1]=='dashboard-stop'
        emit.write_text('99')
        time.sleep(.5)
        assert events.read_text().count('game-start')==starts+1 and call('status')['state']=='dashboard'
        print('PASS: dashboard host request launches configured game and returns; unknown requests ignored')
        assert call('launch',argv=[str(long_game)],cwd=str(root))['ok']
        wait_for(lambda:'long-game-start' in events.read_text())
        assert call('stop-game')['ok']
        wait_for(lambda:call('status')['state']=='dashboard')
        assert call('status')['last_game_exit'] is not None
        assert call('stop-game')['ok']
        print('PASS: stop-game ends an uncooperative game and restores the dashboard; idempotent when idle')
        assert (state/'apps.txt').read_text()=='First\nSecond\n'
        assert call('status')['apps']==['First','Second']
        emit.write_text('101')
        wait_for(lambda:'game2-start' in events.read_text())
        wait_for(lambda:call('status')['state']=='dashboard')
        emit.write_text('105')
        time.sleep(.5)
        assert call('status')['state']=='dashboard' and events.read_text().count('game2-start')==1
        print('PASS: apps list published for dashboard; request 100+i launches app i; out-of-range ignored')
        assert call('command',command='ping')['delivered']
        wait_for(lambda:'command:ping' in events.read_text())
        assert not call('command',command='bad\nline')['ok']
        print('PASS: command passthrough reaches the running dashboard stdin; multi-line commands rejected')
        call('poll-host-requests')  # clear the stray '99' queued by the unmatched-request check above
        emit.write_text('2')
        for _ in range(5):
            assert call('status')['state']=='dashboard'
            time.sleep(.1)
        assert call('poll-host-requests')['requests']==[2]
        assert call('poll-host-requests')['requests']==[]
        print('PASS: poll-host-requests drains queued codes exactly once; plain status calls never drain them')
        config=json.loads((state/'config.json').read_text())
        config['apps'].append({'title':'Third','game':str(game2)})
        (state/'config.json').write_text(json.dumps(config))
        assert call('status')['apps']==['First','Second']
        assert call('launch',argv=[str(game2)],cwd=str(root))['ok']
        wait_for(lambda:call('status')['state']=='dashboard')
        assert call('status')['apps']==['First','Second','Third']
        assert (state/'apps.txt').read_text()=='First\nSecond\nThird\n'
        print('PASS: configure change mid-run takes effect on next dashboard restart without a full stop')
        config=json.loads((state/'config.json').read_text())
        config['dashboard_env']={'NEWT_TEST_PROBE':'hello-from-host'}
        (state/'config.json').write_text(json.dumps(config))
        assert call('launch',argv=[str(game2)],cwd=str(root))['ok']
        wait_for(lambda:call('status')['state']=='dashboard')
        probes=[l for l in events.read_text().splitlines() if l.startswith('env:NEWT_TEST_PROBE=')]
        assert probes[-1]=='env:NEWT_TEST_PROBE=hello-from-host'
        print('PASS: dashboard_env overrides (e.g. a rich host\'s refresh/scale settings) reach the dashboard')
        second=subprocess.run(SERVE_CMD,env=env,capture_output=True,timeout=3)
        assert second.returncode==0 and call('status')['ok']
        print('PASS: second manager preserves the live session')
        exported=root/'Export.app'
        (exported/'Contents/MacOS').mkdir(parents=True)
        (exported/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Game','CFBundleIdentifier':'org.newt.fixture','CFBundlePackageType':'APPL'}))
        subprocess.run(['/usr/bin/clang','-x','c','-o',str(exported/'Contents/MacOS/Game'),'-'],input='int main(void){return 9;}',text=True,check=True)
        subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(exported)],check=True,capture_output=True)
        wrapped=root/'Wrapped.app'
        bundled=subprocess.run(CLI_CMD+['bundle','--game',str(exported),'--output',str(wrapped)],capture_output=True,text=True,timeout=30)
        assert bundled.returncode==0 and json.loads(bundled.stdout)['ok'],(bundled.stdout,bundled.stderr)
        subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(wrapped)],check=True,capture_output=True)
        launch=subprocess.run([str(wrapped/'Contents/MacOS/NewtLaunch')],env=env,capture_output=True,text=True,timeout=10)
        assert launch.returncode==0,(launch.stdout,launch.stderr)
        wait_for(lambda:call('status')['last_game_exit']==9)
        wait_for(lambda:call('status')['state']=='dashboard')
        assert (exported/'Contents/MacOS/Game').exists()
        print('PASS: native development bundle reuses manager, launches embedded export and returns')

        godot=shutil.which('godot')
        if godot:
            # The one-second lease above is intentionally for expiry testing.
            # Give real engine startup the production lease duration.
            call('stop')
            out,err=process.communicate(timeout=8)
            assert process.returncode==0,(out,err)
            config=json.loads((state/'config.json').read_text());config['startup_timeout']=60
            (state/'config.json').write_text(json.dumps(config))
            process=subprocess.Popen(SERVE_CMD,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            wait_for(ready)
            project=root/'godot' ;project.mkdir()
            shutil.copytree(ROOT/'addons',project/'addons')
            (project/'project.godot').write_text('config_version=5\n[application]\nconfig/name="NewtBridgeTest"\nrun/main_scene="res://main.tscn"\n[autoload]\nNewtSessionBridge="*res://addons/newt_bridge/session.gd"\n[xr]\nopenxr/enabled=true\nshaders/enabled=true\n[rendering]\nrendering_device/driver.macos="vulkan"\n[newt]\nexecutable='+json.dumps(str(Path(NEWTD).resolve()))+'\n')
            (project/'main.tscn').write_text('[gd_scene format=3]\n[node name="Test" type="Node"]\n')
            script = 'extends SceneTree\nfunc _initialize():\n    var plugin = load("res://addons/newt_bridge/plugin.gd").new()\n    var failure = plugin._decode_response(1, ["Newt: missing configuration"])\n    if failure.get("ok", true) or not str(failure.get("error", "")).contains("missing configuration"):\n        quit(5)\n        return\n    if not plugin._build():\n        quit(2)\n        return\n    if not OS.has_environment("NEWT_LAUNCH_TOKEN"):\n        quit(3)\n        return\n    var output: Array = []\n    var result = OS.execute(OS.get_executable_path(), ["--headless", "--path", ' + json.dumps(str(project)) + ', "--xr-mode", "off", "--quit-after", "3", "--log-file", ' + json.dumps(str(root/'child.log')) + '], output, true)\n    print("CHILD OUTPUT: ", "".join(output))\n    plugin.free()\n    quit(result)\n'
            (project/'bridge_test.gd').write_text(script)
            run=subprocess.run([godot,'--headless','--editor','--path',str(project),'--xr-mode','off','--script','res://bridge_test.gd','--log-file',str(root/'editor.log')],env=env,capture_output=True,text=True,timeout=30)
            assert run.returncode==0,(run.stdout,run.stderr)
            assert 'SCRIPT ERROR' not in run.stdout+run.stderr,(run.stdout,run.stderr)
            assert 'could not attach' not in run.stdout+run.stderr,(run.stdout,run.stderr)
            wait_for(lambda:call('status')['state']=='dashboard')
            print('PASS: Godot build hook, inherited runtime/token, child autoload, return to dashboard')

        call('stop')
        out,err=process.communicate(timeout=8)
        assert process.returncode==0,(out,err)
        config=json.loads((state/'config.json').read_text());del config['apps']
        (state/'config.json').write_text(json.dumps(config))
        process=subprocess.Popen(SERVE_CMD,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        wait_for(ready)
        wait_for(lambda:call('status')['state']=='dashboard')
        assert call('status')['apps']==[]
        emit.write_text('3')
        polled=wait_for(lambda:call('poll-host-requests')['requests'] or None)
        assert polled==[3]
        assert call('status')['state']=='dashboard' and call('status')['error'] is None
        print('PASS: request 3 with nothing configured queues for a rich host instead of erroring')

        # A dashboard that refuses the simulated runtime fallback (exit 2)
        # must surface as idle with an actionable error, never as healthy.
        sim=root/'sim_dashboard'
        sim.write_text(f'#!{sys.executable}\nimport sys\nprint("Newt fatal: simulated fallback (fake)",file=sys.stderr)\nsys.exit(2)\n')
        sim.chmod(0o755)
        call('stop')
        out,err=process.communicate(timeout=8)
        assert process.returncode==0,(out,err)
        config=json.loads((state/'config.json').read_text());config['dashboard']=str(sim)
        (state/'config.json').write_text(json.dumps(config))
        process=subprocess.Popen(SERVE_CMD,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        wait_for(ready)
        wait_for(lambda:call('status')['state']=='idle')
        assert 'simulated' in call('status')['error']
        assert call('status')['last_dashboard_exit']==2
        print('PASS: simulated-fallback refusal reports idle with an actionable error')
        # Idle must mean idle CPU too: a dashboard that exited leaves its
        # stdout pipe at EOF, and a readability handler that keeps firing
        # on that EOF spins a full core forever (regression: installed
        # newtd burned ~95% CPU in exactly this state).
        def cpu_seconds(pid):
            text=subprocess.check_output(['/bin/ps','-o','time=','-p',str(pid)],text=True).strip()
            return sum(float(part)*60**i for i,part in enumerate(reversed(text.split(':'))))
        before=cpu_seconds(process.pid);time.sleep(2);used=cpu_seconds(process.pid)-before
        assert used<0.5,f'idle manager burned {used:.2f}s CPU in 2s'
        print('PASS: idle manager uses ~no CPU after dashboard exit (no EOF readability spin)')

        # A dashboard that exits cleanly (e.g. the OpenXR session simply
        # became inactive) is not the same failure as a crash -- callers
        # need the real exit code to tell a graceful stop from a refusal.
        clean=root/'clean_dashboard'
        clean.write_text(f'#!{sys.executable}\nimport sys\nsys.exit(0)\n')
        clean.chmod(0o755)
        call('stop')
        out,err=process.communicate(timeout=8)
        assert process.returncode==0,(out,err)
        config=json.loads((state/'config.json').read_text());config['dashboard']=str(clean)
        (state/'config.json').write_text(json.dumps(config))
        process=subprocess.Popen(SERVE_CMD,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        wait_for(ready)
        wait_for(lambda:call('status')['state']=='idle')
        assert call('status')['last_dashboard_exit']==0
        print('PASS: a clean dashboard exit (status 0) is distinguishable from a crash')

    finally:
        if external is not None:external.terminate();external.wait()
        try:call('stop')
        except OSError:process.terminate()
        out,err=process.communicate(timeout=8)
        assert process.returncode==0,(out,err)
        assert not endpoint.exists()
    print('PASS: clean shutdown removes socket and reaps dashboard')

    # Self-bootstrapping run (standalone bundles): no config.json, but the
    # launcher-supplied NEWT_BOOTSTRAP_* variables synthesize one on first
    # launch. Driven through the real newtd CLI.
    cli=CLI_CMD
    bstate=root/'bstate';bstate.mkdir(mode=0o700)
    bipc=root/'bipc';bipc.mkdir(mode=0o700)
    icd=root/'icd.json';icd.write_text(json.dumps({'ICD':{'library_path':'./fake.dylib'}}))
    benv=os.environ.copy();benv.update(NEWT_STATE_DIR=str(bstate),NEWT_IPC_DIR=str(bipc),NEWT_BOOTSTRAP_DASHBOARD=str(helper),NEWT_BOOTSTRAP_RUNTIME=str(runtime),NEWT_BOOTSTRAP_ICD=str(icd))
    bendpoint=bipc/'session.sock'
    def bcall(action,**values):return request(bendpoint,dict(action=action,**values))
    game_starts=events.read_text().count('game-start')
    launched=subprocess.run(cli+['run','--game',str(game)],env=benv,capture_output=True,text=True,timeout=20)
    assert launched.returncode==0,(launched.stdout,launched.stderr)
    wait_for(lambda:bcall('status')['last_game_exit']==7)
    wait_for(lambda:bcall('status')['state']=='dashboard')
    assert events.read_text().count('game-start')==game_starts+1
    bconfig=json.loads((bstate/'config.json').read_text())
    assert bconfig['dashboard']==str(helper) and bconfig['runtime']==str(runtime) and bconfig['icd']==str(icd),bconfig
    bcall('stop');wait_for(lambda:not bendpoint.exists())
    # Partial bootstrap (dashboard only) still fails as unconfigured.
    pstate=root/'pstate';pstate.mkdir(mode=0o700)
    penv=os.environ.copy();penv.update(NEWT_STATE_DIR=str(pstate),NEWT_IPC_DIR=str(root/'pipc'),NEWT_BOOTSTRAP_DASHBOARD=str(helper))
    (root/'pipc').mkdir(mode=0o700)
    partial=subprocess.run(cli+['run','--game',str(game)],env=penv,capture_output=True,text=True,timeout=20)
    assert partial.returncode!=0 and 'not configured' in partial.stderr and not (pstate/'config.json').exists(),(partial.stdout,partial.stderr)
    # Second launch needs no bootstrap variables: the synthesized config persists.
    cenv={k:v for k,v in benv.items() if not k.startswith('NEWT_BOOTSTRAP_')}
    launched=subprocess.run(cli+['run','--game',str(game)],env=cenv,capture_output=True,text=True,timeout=20)
    assert launched.returncode==0,(launched.stdout,launched.stderr)
    wait_for(lambda:bcall('status')['last_game_exit']==7)
    bcall('stop');wait_for(lambda:not bendpoint.exists())
    print('PASS: run self-configures from NEWT_BOOTSTRAP_* on first launch only; partial bootstrap still fails; config persists')

    # Standalone bundle: fake runtime/ICD dylibs with a real dependency
    # chain around a fake export that records the environment it was
    # handed. Launching the wrapped .app must need no prior configure,
    # use only the private per-app state, and leave no manager behind.
    src_dir=root/'standalone-src';src_dir.mkdir()
    (src_dir/'dep.c').write_text('int dep_fn(void){return 1;}')
    (src_dir/'rt.c').write_text('int dep_fn(void);int rt_fn(void){return dep_fn()+1;}')
    (src_dir/'icd.c').write_text('int icd_fn(void){return 3;}')
    subprocess.run(['/usr/bin/clang','-dynamiclib','-install_name',str(src_dir/'libfake_dep.dylib'),'-o',str(src_dir/'libfake_dep.dylib'),str(src_dir/'dep.c')],check=True)
    subprocess.run(['/usr/bin/clang','-dynamiclib','-o',str(src_dir/'libfake_runtime.dylib'),str(src_dir/'rt.c'),f'-L{src_dir}','-lfake_dep'],check=True)
    subprocess.run(['/usr/bin/clang','-dynamiclib','-o',str(src_dir/'libfake_icd.dylib'),str(src_dir/'icd.c')],check=True)
    sruntime=src_dir/'sruntime.json';sruntime.write_text(json.dumps({'file_format_version':'1.0.0','runtime':{'name':'Fake','library_path':'./libfake_runtime.dylib'}}))
    sicd=src_dir/'sicd.json';sicd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':'./libfake_icd.dylib','api_version':'1.1.0'}}))
    env_record=root/'standalone-env.txt'
    sexport=root/'StandaloneExport.app'
    (sexport/'Contents/MacOS').mkdir(parents=True)
    (sexport/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Game','CFBundleIdentifier':'org.newt.fixture','CFBundlePackageType':'APPL'}))
    game_code='#include <stdio.h>\n#include <stdlib.h>\nint main(void){FILE*f=fopen(OUT,"w");if(!f)return 5;fprintf(f,"XR=%s\\nVK=%s\\n",getenv("XR_RUNTIME_JSON")?getenv("XR_RUNTIME_JSON"):"",getenv("VK_ICD_FILENAMES")?getenv("VK_ICD_FILENAMES"):"");fclose(f);return 9;}\n'.replace('OUT',json.dumps(str(env_record)))
    subprocess.run(['/usr/bin/clang','-x','c','-o',str(sexport/'Contents/MacOS/Game'),'-'],input=game_code,text=True,check=True)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(sexport)],check=True,capture_output=True)
    bundle_id=f'org.newt.test.standalone{os.getpid()}'
    app_support=Path.home()/'Library/Application Support'/bundle_id
    private_state=app_support/'Newt'
    private_endpoint=Path(f'/tmp/newt-session-{ipc_hash(bundle_id)}-{os.getuid()}')/'session.sock'
    shutil.rmtree(app_support,ignore_errors=True)
    shutil.rmtree(private_endpoint.parent,ignore_errors=True)
    def check_bundle(app):
        newt_dir=app/'Contents/Resources/Newt'
        for name in ('libfake_runtime.dylib','libfake_dep.dylib','libfake_icd.dylib'):
            assert (newt_dir/'lib'/name).is_file(),name
        assert (newt_dir/'dashboard-stub.sh').stat().st_mode & 0o111
        assert json.loads((newt_dir/'runtime.json').read_text())['runtime']['library_path']=='lib/libfake_runtime.dylib'
        assert json.loads((newt_dir/'runtime.json').read_text())['runtime']['name']=='Fake'
        assert json.loads((newt_dir/'icd.json').read_text())['ICD']['library_path']=='lib/libfake_icd.dylib'
        deps=subprocess.check_output(['/usr/bin/otool','-L',str(newt_dir/'lib/libfake_runtime.dylib')],text=True)
        assert '@loader_path/libfake_dep.dylib' in deps and str(src_dir) not in deps,deps
        assert plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']==bundle_id
        subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
    try:
        for extra,expect in ((['--runtime',str(sruntime)],'--bundle-id'),
                             (['--bundle-id',bundle_id],'--runtime'),
                             (['--icd',str(sicd)],'--runtime'),
                             (['--runtime',str(sruntime),'--bundle-id','not a bid!'],'Invalid --bundle-id')):
            bad=subprocess.run(cli+['bundle','--game',str(sexport),'--output',str(root/'Bad.app')]+extra,capture_output=True,text=True,timeout=20)
            assert bad.returncode!=0 and expect in bad.stderr,(extra,bad.stdout,bad.stderr)
            assert not (root/'Bad.app').exists()
        run_app=root/'WrappedStandalone.app'
        made=subprocess.run(cli+['bundle','--game',str(sexport),'--output',str(run_app),'--runtime',str(sruntime),'--icd',str(sicd),'--bundle-id',bundle_id],capture_output=True,text=True,timeout=60)
        assert made.returncode==0 and json.loads(made.stdout)['ok'],(made.stdout,made.stderr)
        check_bundle(run_app)
        main_config_before=(state/'config.json').read_bytes()
        launch=subprocess.run([str(run_app/'Contents/MacOS/NewtLaunch')],env=os.environ.copy(),capture_output=True,text=True,timeout=20)
        assert launch.returncode==0,(launch.stdout,launch.stderr)
        wait_for(lambda:env_record.exists() and env_record.read_text())
        recorded=dict(line.split('=',1) for line in env_record.read_text().splitlines())
        assert recorded['XR']==str(run_app/'Contents/Resources/Newt/runtime.json'),recorded
        assert recorded['VK']==str(run_app/'Contents/Resources/Newt/icd.json'),recorded
        # The game has exited; the dashboard stub must stop the manager so
        # nothing lingers, and the private config the bootstrap wrote uses
        # only bundle-internal paths.
        wait_for(lambda:not private_endpoint.exists())
        sconfig=json.loads((private_state/'config.json').read_text())
        assert sconfig['dashboard']==str(run_app/'Contents/Resources/Newt/dashboard-stub.sh'),sconfig
        assert sconfig['runtime']==recorded['XR'] and sconfig['icd']==recorded['VK'],sconfig
        assert (state/'config.json').read_bytes()==main_config_before
        print('PASS: standalone bundle embeds relinked closure + manifests, launches with no prior configure into private state, manager exits after the game')
    finally:
        try:
            request(private_endpoint,{'action':'stop'})
        except OSError:
            pass
        shutil.rmtree(app_support,ignore_errors=True)
        shutil.rmtree(private_endpoint.parent,ignore_errors=True)
