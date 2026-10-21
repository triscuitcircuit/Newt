# Newt roadmap / remaining work

_Last updated: 2026-10-18. Standalone Newt manager/dashboard/Godot handoff
was reported working in-headset by the previous agent. The rebuilt PippinVR Dev
dashboard now appears in the headset, and the user reports no smearing. Godot
handoff through Pippin is not implemented or validated yet._

## Performance investigation — 2026-10-19

See [the detailed handoff](PERFORMANCE-HANDOFF-2026-10-19.md) before continuing.
GPU desktop capture and per-stage frame timing are implemented in the test helper.
Controlled Terminal runs measured 119.27 fps (CPU) and 119.63 fps (GPU), with
prepare time reduced from 0.434 ms to 0.089 ms. This does **not** yet explain the
old ~14.5 fps regression: both paths are fast under direct launch. Compare the
same build through the native manager; its Background launch-agent policy is a
hypothesis, not a confirmed cause. The latest manager tests selected Simulated
HMD and refused to start, so restore real USB Link before measuring.

## Done (for context)

- Standalone native session manager with one-owner handoff between the Newt
  dashboard and OpenXR games (`newtd`, Godot editor Play bridge,
  exported-game launch, dev bundles and self-contained standalone bundles;
  the original Python manager it replaced has been removed).
- In-headset app launching: dashboard host requests (`NEWT_REQUEST:3` first
  app, `100+i` Apps-page pick), `--app` configuration, cooperative in-game
  Menu -> Resume/Quit convention, `newt stop-game` escape hatch.
- Fail-fast simulated-runtime refusal (dashboard exit 2 + manager reports
  `idle` with an actionable error; `NEWT_ALLOW_SIMULATED=1` opt-in).
- Layer split: standalone `newt_core` (`Newt::core`), reference dashboard
  (`newt_dashboard`, sources in `dashboard/`), `Newt::newt` compat aggregate.
- `NewtLog` delegate (`include/NewtLog.h`): Newt's log lines route to a host
  handler when installed (Pippin forwards into its Swift `Logger`), stdio
  otherwise.

## Current responsibilities and dependencies

| Component | Handles today |
| --- | --- |
| Newt core (`Newt::core`) | OpenXR session lifecycle, tracking/controller input, Vulkan resources, swapchains and frame submission. Public `Session`/`SessionDelegate` API. |
| Newt dashboard (`Newt::dashboard`) | Screens, curved panels, dock, controller interaction, capture and media playback. Still lives in Newt pending migration to Pippin. |
| Newt session manager + Godot addon | Discovery of Newt-managed sessions, one-owner game handoff, and dashboard restoration. |
| Pippin | macOS menus/settings, device information, virtual-display creation, app/media selection, and packaging the headset runtime. |
| Monado + Vulkan/MoltenVK | Quest Link USB/runtime support and graphics translation to Metal. |

Pippin now builds Newt through `pippinVR-Server/build-newt.sh`, installs its
archives into `.build/newt-package`, and links them through the SwiftPM
`NewtBridge` module. Its bundled `pippinvr-xr` helper comes from the same Newt
build. Its embedded path no longer compiles the old `PippinXR` renderer.

This does **not** remove external dependencies: the OpenXR loader, Monado,
Vulkan/MoltenVK and their runtime dependencies are still required. Newt wraps
them; it does not replace them. Newt's optional libusb module is disabled in
this Pippin build because the bundled runtime handles USB Link. The old
`PippinXR/` directory remains for rollback and runtime vendor files; it cannot
be deleted wholesale until those remaining references are migrated.

## Completed integration and validation

- Added public `Newt::Session` and `SessionDelegate`. Session owns instance,
  device, swapchains, actions and frame lifecycle; dashboard owns the session.
- Input, frame preparation, eye drawing and host policy use callbacks.
- Added `NEWT_BUILD_DASHBOARD=OFF`, an isolated source-build/install check,
  and an installed C++ core consumer with product headers absent.
- Added failure/retry lifecycle coverage without starting a runtime. All five
  local Newt tests and the isolated installed-core check passed.
- Pippin build/bundle/helper-install scripts use `build-newt.sh`. Pippin
  translates its existing settings to Newt environment names and recognizes
  `NEWT_REQUEST` messages alongside the legacy prefix.
- Pippin release build, request decoding, settings forwarding and process-stop
  tests passed locally. The updated development app was staged with a backup
  in `/tmp` (temporary rollback copy, not a release artifact).
- Live PippinVR Dev check: user confirmed the dashboard appears and reports
  no smearing. Full controller/menu, screen adjustment, disconnect/reconnect
  and game launch/return regression coverage is not yet recorded.

## Remaining, in recommended order

### 1. Unify Pippin and Godot under the Newt session manager

**Current gap:** Godot Play discovers a Newt-managed session, reserves the
headset, stops that manager's dashboard, launches the game, and restores the
dashboard afterward. Pippin instead launches its helper directly through
`DirectMonadoSession`; that session is not registered with the Newt manager.
Godot therefore cannot automatically take over the running Pippin session.
Avoid starting an independent manager against a headset already owned by Pippin.

The missing in-headset app list has the same integration cause: the standalone
manager supplies `NEWT_APPS_FILE`, while Pippin does not. Pippin currently keeps
**Launch 3D App…** in its macOS menu; the headset app button requests the Mac
file picker when no app list is supplied. Pippin recognizes requests 1–4,
but does not yet route the manager's indexed `100+i` app selections.

- Make Pippin connect/disconnect and native-app launch use the shared manager
  endpoint and ownership/lease protocol rather than independently starting
  another headset-owning process.
- Configure the manager to launch Pippin's bundled dashboard helper with its
  runtime manifests, settings and host resources. Preserve Pippin's virtual
  display, media-picker and settings command routing through the manager.
- Supply one shared app list to the dashboard and route indexed app selection
  through the manager. Keep the macOS file picker available for new apps.
- Define disconnect/quit behavior while Godot owns the session; handle startup
  failure, game crash, cancelled Play and an already-running manager without
  orphaned processes or a second USB owner.
- Acceptance: connect from Pippin, press Play in Godot, discover/reuse that
  session, release the dashboard before game startup, then restore Pippin's
  dashboard on Stop/exit. Verify native-app launch and headset app selection
  through the same flow. Record live headset results separately from tests.

This unifies discovery and handoff; it still uses process swaps with a possible
reconnect gap. Persistent runtime/service switching remains item 3 below.

### 1b. Finish the dashboard migration (Phase 2)

The core class split and Pippin archive integration are complete. Remaining:

- Move the product dashboard out of Newt into Pippin; Newt ships the core,
  optional transport and developer integration tools without product UI.
- Build Pippin's dashboard/helper against installed `Newt::core` instead of
  also consuming Newt's current dashboard archive.
- Relocate runtime vendor files and update all build/install references before
  removing the duplicate `pippinVR-Server/PippinXR/` renderer and log bridge.
- Preserve the core-only source/install test and complete the on-headset
  launch/quit regression after the migration.

### 2. Partial simulated-fallback detection — estimated 1-2 days

The name-based check catches full fallback (`Monado: Simulated HMD`), but
this Monado build can report `Monado: Meta Quest Link` as the system name
while the head device still fell back at the USB/XRSP level. Add a
first-frames liveness probe (views locate with tracked flags and advancing
poses within a bounded window) and refuse with the same exit-2 path.

### 3. Seamless app switching (Monado service mode) — spike, then weeks

Today every handoff is a process swap: dashboard exits, USB/XRSP and the
encoder restart in the game process (visible reconnect gap).

- Spike (1-3 days): build the Monado QL fork with `XRT_FEATURE_SERVICE=ON`
  on macOS; connect `hello_xr` as an IPC client to a persistent service.
  Known blocker: cross-process Vulkan image sharing is unimplemented on
  macOS (`vk_image_allocator.c` returns an invalid handle type, MTLTexture
  path marked TODO); MoltenVK IOSurface/Metal-objects work is the bulk of
  the effort (1-3 weeks), plus service supervision/latency hardening
  (2-4 weeks).
- Payoff when done: stream never drops between apps, and a true overlay
  system menu (dashboard session over a focused game) becomes possible.

### 4. Runtime-enforced quit gesture (Monado QL driver) — estimated days

Detect the system/menu long-press in the Quest Link driver and force
`XR_SESSION_STATE_EXITING`, so any well-behaved OpenXR app exits without
in-game cooperation. Until then, quit relies on the cooperative menu
convention plus `newt stop-game`.

### 5. Quest Link driver handoff polish — estimated days

- Skip the USB reset during re-initialization when the device is already in
  XRSP mode; suppress the transient `xrsp_read_usb` pipe-error burst.
- Avoid re-pairing/"Waiting for user to accept" prompts except after a real
  disconnect or re-plug.

### 6. Session-manager hardening — estimated 1-2 days total

- Restore the Godot editor's environment (and release the lease) when Play
  stops, instead of on plugin unload; don't call `ProjectSettings.save()`
  on every Play.
- Don't block the manager's accept loop (and the editor's `_build`) for the
  full dashboard-stop grace period; timestamped, per-child log files
  instead of one merged `children.log`.
- Guard `kill(pid, 0)` against `PermissionError`/PID reuse (prefer
  kqueue `EVFILT_PROC` or start-time checks).

### 7. Dashboard state persistence — estimated days

Panel layout, dashboard pose, and settings are lost when the dashboard
process restarts after a game. Persist them (manager state dir) and restore
on dashboard start so hand-backs return to the same workspace.

### 8. Godot example follow-ups — estimated hours

- Enable `use_xr` from the session-begun signal instead of only `_ready`.
- Optional: GDExtension exposing Newt capture panels as Godot textures
  (shares Godot's session; previously scoped but not implemented).

## Out of scope here

- Pippin's non-Monado (Swift XRSP) serving modes.
- Shipping/notarization packaging for either product.
