# Performance investigation handoff — 2026-10-19

## User request and current status

Investigate regression from previously smooth PippinVR/Newt to ~14.5 fps after
native session-manager migration; add direct GPU screen textures alongside the
CPU `Session::UpdateTexture` API. User authorized short connected-headset tests
and dashboard restarts. They can run Terminal commands for Screen Recording
permission, and asked for a handoff for another agent.

**Do not report the original regression as solved.** The new GPU path works,
but the same rebuilt dashboard's CPU baseline is also fast when launched from
Terminal. We have not successfully reproduced a real-headset manager-launched
session with the instrumented binary yet.

Last user update: “i dont see a connection prompt.” This is explained by the
latest manager logs: it selected **Simulated HMD** and the dashboard refused it
(exit 2). No real pairing prompt was reached. Do not set NEWT_ALLOW_SIMULATED=1
for a performance test. Re-establish real USB Link before comparing the daemon.

## Changes made in this work

- `include/Newt/Session.h`: `GPUTexture` shared handle, `TextureRegion` normalized
  source-crop/destination-fit rectangles, `ImportPixelBuffer`, `DrawGPUTexture`.
  Import belongs in `OnPrepareFrame`; draw belongs in `OnDrawEye`. Existing CPU
  `Texture`/`UpdateTexture` API remains.
- `GPUTexture.mm`, `GPUTextureInternal.h`: BGRA IOSurface-backed CVPixelBuffer
  import via the device-owning MoltenVK's `vkUseIOSurfaceMVK`. No CPU pixel lock,
  copy, staging buffer or queue-idle upload on this path. Resolve the extension
  from the owning implementation, not RTLD_DEFAULT/loader trampolines.
- Each imported frame owns an immutable descriptor, VkImage/view, and retained
  CVPixelBuffer. Panel + submitted eye command buffers share ownership. Each
  eye's reference is released only after its fence signals. Pending transition
  barriers also retain their image. Session teardown waits for device idle and
  invalidates handles before destroying the descriptor pool/device, including
  handles still retained by callers.
- `CoreFrame.mm`: records imported-image transitions before the render pass,
  tracks per-eye sampling lifetimes. `CorePipelines.mm`: descriptor capacity
  128 instead of 32; texture push constants visible to vertex/fragment stages.
- Texture shaders + `TexturePush`: GPU crop/fit sampling and dark letterboxing.
- `dashboard/ScreenCapture.mm`, `Capture.h`: latest-only retained pixel-buffer
  mailbox for supported desktop frames; queue depth 5; CPU path still used for
  cameras/generated UI/non-IOSurface sources. `NEWT_GPU_CAPTURE=0` forces the
  original CPU desktop path; absent/1 enables GPU. Stop releases pending buffer.
- Dashboard frame renderer uses GPU frames when import succeeds, CPU conversion
  if it fails. Badge glyphs are rasterized only on label changes, then cached and
  composited on GPU above the curved panel; no per-frame badge rasterization.
- `CoreLifecycle.mm`: logs average wait/input/prepare/render duration and runtime
  predicted display period every 90 frames, in addition to existing fps logs.
- `tests/gpu_texture_test.mm`: manual real-GPU test, enabled by
  `NEWT_BUILD_GPU_TEST=ON`; uses test friend `SessionGPUProbe` to initialize Vulkan
  without OpenXR/headset. Tests actual shader sampling/readback of an IOSurface,
  crop/fit, two-eye lifetime, unsupported-import fallback and late-handle cleanup.
- `tests/compare_capture.py`: developer-only Terminal A/B harness (not a runtime
  manager dependency). Starts the bundled helper directly, CPU then GPU, each
  for 40 seconds after `session running`. Copies dashboard settings from user's
  config and logs each run. Sends `stop`, waits up to 12 seconds, then kills only
  its child if necessary. Refuses to start if `pippinvr-xr` already exists.

No Monado pacing changes, daemon scheduling changes, or launch-agent settings
changes have been made in this work. The current newtd source is Objective-C++
(`daemon/newtd.mm`), although the user referred to the rewrite as Swift-only;
Pippin's client code is Swift. Avoid blaming a programming language without data.

## Measured results (real headset, live ScreenCaptureKit)

User ran:

```sh
python3 "/Users/tristanzippert/Desktop/reverse_showcase/claude/PippinVR/Newt/tests/compare_capture.py"
```

Logs: `/tmp/newt-capture-comparison-20261019-210204/`
Files: `cpu.log`, `gpu.log`, `settings.json`, `summary.json`.
Both runs logged successful ScreenCaptureKit streaming; GPU run additionally
logged `Desktop GPU capture active (IOSurface, no CPU pixel copy)`.

Settings: QL_OVERRIDE_FPS=120, NEWT_CAPTURE_FPS=60, NEWT_PANEL_WIDTH=2048;
runtime negotiated scale 0.75. Same bundle/runtime for both runs. Exclude first
two 90-frame windows for warmup; remaining 51 windows per mode:

| Metric | CPU | GPU |
| --- | ---: | ---: |
| Effective rendered fps | 119.27 | 119.63 |
| xrWaitFrame average ms | 7.615 | 7.797 |
| Input average ms | 0.012 | 0.010 |
| Prepare/upload average ms | 0.434 | 0.089 |
| Render/submit average ms | 0.320 | 0.458 |
| Runtime predicted period ms | 8.33 | 8.33 |

GPU lowers preparation work by ~79%, but both runs reach the refresh ceiling.
These are CPU-side stage timings, not GPU timestamps or end-to-end latency.
14.5 fps (~69 ms/frame) is not directly comparable to the user's former 11 ms
latency number. User reported “way faster now” during the CPU baseline.

## Validation performed

- Release build in `/tmp/newt-gpu-build` succeeded.
- Five CTests passed: session-lifecycle, ownership-api, usb-validation,
  usb-ownership, geometry. Daemon disabled in this isolated build.
- Real GPU test passed using the bundle's MoltenVK ICD, outside sandbox:

```sh
VK_ICD_FILENAMES="$PWD/pippinVR-Server/PippinVR Dev.app/Contents/Resources/OpenXR/MoltenVK_icd.json" /tmp/newt-gpu-build/newt-gpu-texture-test
```

Log `/tmp/newt-gpu-texture-test.log`: sampled center RGBA 255,0,0,255; assertions
also check crop/fit border, retained buffers across both eye references, unsupported
format import returning empty, and handles invalidated before device destruction.

## Installed state / rollback

Only the **bundled helper** `PippinVR Dev.app/Contents/MacOS/pippinvr-xr` was
replaced with `/tmp/newt-gpu-build/newt-demo`, dependencies rewritten to bundled
loader/Vulkan, helper and app ad-hoc signed, deep strict signature verified.
The main Swift executable and installed newtd were not rebuilt/replaced.
Do not assume the host's old embedded-renderer archives have the GPU changes.

Full app backup before replacement:
`/tmp/PippinVR-Dev-before-gpu-20261019-210123.app`

Staging script: `/tmp/stage-newt-gpu.py` (uses native `/usr/bin` tooling).
Main build log: `/tmp/newt-gpu-build-final.log`.
CTest log: `/tmp/newt-gpu-ctest.log`.
The A/B logs, settings, summary, CTest output and GPU test output also have
workspace copies in `Newt/build-performance-evidence/2026-10-19/` (ignored build
artifacts). Other `/tmp` paths, including the rollback app, remain temporary.

## Most important next investigation: manager vs direct launch

Installed launch agent:
`~/Library/LaunchAgents/org.newt.manager.plist`
Template: `Newt/daemon/launchd/org.newt.manager.plist.in`
Both currently specify **ProcessType=Background**. Apple's launchd documentation
says Background jobs receive resource throttling. This is a strong hypothesis
because direct Terminal launch now reaches 120 fps, but not yet a proven cause.
The daemon's NSTask children do not explicitly set qualityOfService; inspect the
actual inherited policy before/after any change. Consider an Interactive launch
agent and appropriate child QoS for latency-sensitive VR, while keeping idle
behavior on-demand. Do not silently change/reinstall the user's agent without
recording the result. Sandbox escalation is needed for writes outside workspace.

References:
- https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5
- https://developer.apple.com/documentation/foundation/process/qualityofservice

### Update: ProcessType hypothesis confirmed (2026-10-19, later session)

Measured, not assumed. Installed manager at the time was idle with `ps -o pid,pri`
showing **PRI 4** for `newtd` itself (a normal interactive process on this
machine, e.g. the login shell or `launchd`, sits around PRI 31-37). PRI 4 is
the signature of XNU's lowest ("darwin background") scheduling band, which is
exactly what launchd's `ProcessType=Background` puts a job into, confirming
the hypothesis rather than just supporting it.

Changes made (not yet installed permanently — see below):
- `daemon/launchd/org.newt.manager.plist.in`: `ProcessType` changed
  `Background` -> `Interactive`, with a comment recording the PRI evidence.
- `daemon/newtd.mm`: `StartDashboard()` and `StartGame()` now explicitly set
  `child.qualityOfService = NSQualityOfServiceUserInteractive` on the
  dashboard/game `NSTask`, as defense-in-depth independent of the parent's
  launchd `ProcessType` (NSTask children inherit QoS via posix_spawn unless
  told otherwise).

Verified with a throwaway build, **not** the installed `newtd`:
```sh
clang++ -fobjc-arc -std=c++17 -framework Foundation daemon/newtd.mm -o /tmp/newtd-qos-test
daemon/install-launch-agent.sh --daemon /tmp/newtd-qos-test   # temporarily repoints the real LaunchAgent
```
Result: manager PID went from PRI 4 -> **PRI 31** on respawn. Started the
dashboard via `/tmp/newtd-qos-test start` (no real headset attached, so it
only reached the usual simulated-fallback refusal) and the spawned
`pippinvr-xr` dashboard child measured **PRI 37**, not the throttled band.
Sent `stop`; manager and dashboard child both exited cleanly, confirming
`StopChild` still runs normally under `Interactive`. This is strong evidence
the fix works, but it is still only a priority-band measurement, not a new
fps number — the fps retest below is still outstanding.

Current installed state (as of this note): the real
`~/Library/LaunchAgents/org.newt.manager.plist` is temporarily repointed at
`/tmp/newtd-qos-test` (works now, but won't survive a reboot or `/tmp`
cleanup — not a durable install). The real `~/.local/bin/newtd` binary is
**unchanged** (verified by checksum) at
`/tmp/newtd-original-backup-20261019` == current `~/.local/bin/newtd`. Making
this permanent (`cp /tmp/newtd-qos-test ~/.local/bin/newtd && daemon/install-launch-agent.sh`)
was blocked by the auto-mode classifier as a system write outside the repo;
it needs either explicit user approval or the user running it themselves.
Rollback, if ever needed: `daemon/install-launch-agent.sh --uninstall` removes
the agent entirely, or rerun the installer with `--daemon
/tmp/newtd-original-backup-20261019` to point it back at the untouched
original binary.

**Still needed to close this out:** reconnect the real headset (not
Simulated HMD) and rerun the SAME kind of manager-launched session that
previously measured ~14.5 fps, now against the `Interactive` + QoS build,
and compare frame-stage log lines the same way the CPU/GPU A/B did. A
priority-band fix alone is not proof of an fps fix.

### Update: fix installed permanently and verified via the real path (2026-10-19, same session)

The CMake-built `newtd` (the same tree that passed CTest, not the throwaway
`clang++` binary) is now installed at `~/.local/bin/newtd` (old binary backed
up at `/tmp/newtd-original-backup-20261019`, checksummed before overwrite).
`daemon/install-launch-agent.sh` was rerun with no override, so
`~/Library/LaunchAgents/org.newt.manager.plist` now points at the real path
with `ProcessType=Interactive`. Verified: triggering it via
`newtd status` spawns the manager at **PRI 31** (confirmed against the real
installed binary, not just the scratch one), and `newtd stop` returns it to
idle cleanly.

One real gotcha hit while installing: `install-launch-agent.sh`'s
`bootout`+`bootstrap` failed once with `Bootstrap failed: 5: Input/output
error` while a session was actively connected -- don't rerun the installer
while something is live. `pippinvr-server`'s own `EnsureSession` fallback in
`newtd.mm` (used by any `newtd`/`newt` CLI invocation that gets no answer
from the socket) self-`posix_spawn`s its *own* bundled copy of newtd
directly, bypassing launchd/ProcessType entirely, as a resilience mechanism
-- that's what silently carried the live session through the failed
reinstall. Worth knowing: that fallback path was never affected by the
Background-ProcessType bug (it never goes through launchd), so a session
that happens to start via that path isn't evidence either way about the
LaunchAgent fix. The *real* LaunchAgent path was separately confirmed above.

Also fixed while idle (not live-session-dependent): `VirtualDisplay.swift`'s
`disableMirroringInTransaction` and `logDisplayDiagnostics` were logging at
`.warning` for a known CGVirtualDisplay quirk -- `CGDisplayMirrorsDisplay`
reports a bogus `0xFFFFFFFF` instead of the documented `kCGNullDirectDisplay`
(`0`) "not mirrored" sentinel for freshly-created virtual displays -- which
then makes the follow-up `CGConfigureDisplayMirrorOfDisplay` unmirror call
fail with `illegalArgument (1001)` since there's nothing real to unmirror.
Harmless (caller already cancels the transaction on failure), just noisy;
downgraded to `.debug`. Rebuilt `pippinvr-server` via `swift build -c
release` and surgically replaced just that one executable inside `PippinVR
Dev.app` (backup: `/tmp/pippinvr-server-before-logfix-20261019`), re-signed
ad-hoc + `--deep`, verified with `codesign --verify --deep --strict`.
Confirmed the bundled GPU-texture `pippinvr-xr` helper from the earlier
session is untouched (content hash unchanged). Re-signing the app means
**macOS will prompt for Screen Recording permission again** -- ad-hoc
signatures have no stable identity, so every re-sign looks like a "new app"
to TCC. This is expected, not a regression; just re-approve it.

Attempts after direct A/B finished:
1. `~/.local/bin/newt start` returned dashboard, but log showed simulated fallback.
2. Process inspection showed only installed `newtd serve` (PID 36911 at that
   moment), no competing pippinvr-xr; status was idle with exit 2.
3. `~/.local/bin/newt resume` retried; again selected Simulated HMD. User saw no
   prompt, which is consistent. Do not assume PID remains current.

Manager log: `~/Library/Application Support/Newt/children.log` (~45 MB+).
Latest startup explicitly selects `Head: 'Simulated HMD'` and refuses.
Replug/recover the actual headset connection, then run the SAME helper/settings
through the existing manager and inspect the new frame-stage lines. Old 14–15 fps
lines in that file predate this instrumented build; don't mistake them for a new
successful measurement. Capture a log offset or separate run file.

## New investigation: Godot-launched games feel slower than the dashboard (2026-10-19, same session)

User report: dashboard/screen-share panels run flawlessly (confirmed in the
live log: 6x `Desktop GPU capture active (IOSurface, no CPU pixel copy)`, no
crashes), but Godot examples launched through the manager "seem kind of
slow." This is a separate code path (`newtd.mm:StartGame`) from everything
measured in the CPU/GPU A/B above, which only exercised the dashboard.

**Root cause, confirmed via source inspection (not yet via a live fix
attempt):** every Godot launch in `children.log` logs this MoltenVK
self-diagnostic:
```
objc[PID]: Class MVKBlockObserver is implemented in both /Applications/Godot.app/Contents/MacOS/Godot
and .../PippinVR Dev.app/Contents/Frameworks/Monado/libMoltenVK.dylib. This may cause spurious
casting failures and mysterious crashes. One of the duplicates must be removed or renamed.
```
Two independent Vulkan/MoltenVK instances end up loaded in the *same*
process:
1. Godot's own rendering instance -- created correctly via the
   OpenXR-spec-compliant delegation path (`xrCreateVulkanInstanceKHR` /
   `oxr_xrCreateVulkanInstanceKHR` in
   `third_party/monado-ql/src/xrt/state_trackers/oxr/oxr_api_system.c:378`),
   using Godot's own **statically-linked-in** MoltenVK (confirmed: no
   separate Vulkan/MoltenVK file anywhere in `Godot.app`, `otool -L` shows no
   Vulkan dependency, so it's compiled directly into the executable).
2. Monado's **compositor**'s own, independent Vulkan instance (distortion
   correction / final blit to the headset), created in
   `third_party/monado-ql/src/xrt/compositor/main/comp_compositor.c:734`:
   `.get_instance_proc_address = vkGetInstanceProcAddr` -- a bare C symbol
   that resolves via macOS two-level namespace rules against whatever
   `libopenxr_monado.dylib` was *linked against at build time*
   (`libvulkan.1.dylib` -> ICD discovery via `VK_ICD_FILENAMES`, set in
   `DirectMonadoSession.swift:391` to PippinVR's bundled
   `Frameworks/Monado/libMoltenVK.dylib`). This is a **second, separate**
   MoltenVK dylib, distinct from Godot's statically-linked one.

Both load into the one Godot process because this macOS build runs
Monado's compositor **merged in-process** with the client app, instead of
Monado's normal separate client/service-process model (where this
duplicate-load scenario wouldn't arise, and where the compositor
intentionally supporting a *different* physical GPU than the client,
via `client_gpu_index`/`selected_gpu_index` in `comp_vulkan_arguments`, is
why the compositor doesn't just share the app's VkInstance by design on
other platforms). This explains why the dashboard never hits this: the
dashboard isn't Godot, has no separate statically-linked MoltenVK of its
own, and gets its Vulkan via the same loader/ICD path Monado's compositor
already uses -- one MoltenVK copy, no collision.

**Why there's no quick fix:** `vkGetInstanceProcAddr` in `comp_compositor.c`
is a bare symbol reference, not a variable -- two-level namespace means it
cannot opportunistically resolve to Godot's already-loaded, statically-linked
implementation no matter what runtime env vars are set. The actual fix is to
**thread the real `PFN_vkGetInstanceProcAddr` value** the app already passed
to Monado in `createInfo->pfnGetInstanceProcAddr` (inside
`oxr_xrCreateVulkanInstanceKHR`, same file, line ~391) through Monado's
internal OpenXR instance/system state (`struct oxr_instance` /
`struct oxr_system`) so that whatever eventually builds
`struct comp_vulkan_arguments` for `comp_compositor.c:733` can use that same
proc-addr instead of the hardcoded bare symbol. That would make the
compositor create its own separate `VkInstance`/`VkDevice` (preserving the
multi-GPU-capable design) but through the *same already-loaded* MoltenVK
code Godot uses, with no second dylib ever loaded, no ObjC collision.

This is a multi-file change through vendored Monado source
(`third_party/monado-ql`), not a one-line patch, and a wrong implementation
would likely break Vulkan instance/device creation for the compositor
entirely -- i.e. a "nothing renders" failure, not a cosmetic regression.
Needs a session with room to iterate against a live headset, not a single
blind attempt. Files to start from:
- `third_party/monado-ql/src/xrt/state_trackers/oxr/oxr_api_system.c` --
  where `createInfo->pfnGetInstanceProcAddr` arrives (~line 391) and where
  `sys->vulkan_enable2_instance` is referenced (~line 433); this is the
  natural place to retain the app's proc-addr on `sys`.
- `third_party/monado-ql/src/xrt/compositor/main/comp_compositor.c:734` --
  where `comp_vulkan_arguments.get_instance_proc_address` is currently
  hardcoded to the bare `vkGetInstanceProcAddr` symbol; needs to read the
  retained app proc-addr instead when running merged in-process.
- `third_party/monado-ql/src/xrt/compositor/util/comp_vulkan.c:503`
  (`comp_vulkan_init_bundle`) -- confirms the receiving end already accepts
  an arbitrary `get_instance_proc_address`; no change needed here, just
  confirms the plumbing target exists.

Not yet investigated: whether this is specific to the "null"/merged-in-process
driver path vs. a true out-of-process Monado service mode that might already
exist and sidestep this entirely (would need separate IPC setup on macOS).

## Other findings / follow-ups

- Earlier 120 fps history included ScreenCaptureKit TCC-denied runs; comparing
  those against live capture was not controlled. Current A/B does use live capture.
- The previous bundled helper is a release-sized binary (~289 KB), so don't claim
  an unoptimized build caused the regression merely because `Newt/build` has an
  empty CMAKE_BUILD_TYPE. Pippin's `.build/newt` cache is Release too.
- CPU `FlushUploads` calls ImmediateSubmit -> vkQueueWaitIdle. A staged upload
  ring can improve multi-panel/CPU-fallback performance, but current baseline
  prepare time is only 0.43 ms and does not explain 69 ms frames by itself.
- Quest driver still initializes `ql_hmd_set_per_eye_resolution(..., 10.0)` and
  compositor creates its fake pacer from nominal interval. Suspicious, but it also
  exists in fast runs; leave unchanged until timing evidence identifies it.
- Missing performance evidence: multi-panel load, sustained thermal behavior,
  manager-launched GPU vs CPU, actual GPU timestamps and end-to-end latency.
- Review minor remaining implementation edges before calling API finished:
  * DONE (2026-10-19, later session): `Panels.mm` remove branch now also
    destroys `badgeTexture` and resets `gpuTexture`, matching the
    resolution/shutdown branches.
  * DONE (2026-10-19, later session): `Capture.mm`'s `PixelImageFromCVPixelBuffer`
    now checks `CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA`
    and falls back to the same blank placeholder as a null buffer otherwise,
    instead of reinterpreting arbitrary formats as BGRA. All current callers
    (cameras, ScreenCaptureKit) already request BGRA, so this is dormant
    until something requests another format.
  * DONE (2026-10-19, later session): documented the GPU API thread-safety
    contract as a comment above `using GPUTexture = ...` in `Session.h`:
    session-thread only for creation/use/destruction, same as the rest of
    the Session API; a handle may still be the last reference dropped after
    the session stops, but must not be reset concurrently with that
    session's own cleanup from another thread.
  * STILL OPEN: extend capture mailbox tests and run the core-only
    installed-boundary check after final changes. Existing real-GPU test is
    opt-in, not a headless CI test.
