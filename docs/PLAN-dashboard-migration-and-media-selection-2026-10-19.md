# Plan: dashboard migration + media selection (Spatial Video, 3D models)

_Written 2026-10-19 from two scoping research passes. Nothing in this plan
has been implemented yet — it's a decision document, not a status report._

---

## Part 1: Move the dashboard from Newt into Pippin

### Goal

Finish the migration `docs/ROADMAP.md` ("1b") and `docs/ARCHITECTURE.md`
already call out: Newt ships only `Newt::core` + the daemon + optional USB
transport, with no product UI. Pippin owns its dock/dashboard outright and
can diverge from Newt's own reference demo without affecting other hosts
(e.g. the Godot example).

### What's actually true today (confirmed by research, not assumed)

- The dashboard is genuinely host-neutral: zero "Pippin" strings anywhere
  in `Newt/dashboard/` or `NewtXRApp.h`; env vars are all generic `NEWT_*`.
- `newtd` (the session manager) needs **zero changes**. It already treats
  the dashboard as an opaque configured executable (path from config /
  `NEWT_BOOTSTRAP_DASHBOARD`), already parses its generic
  `NEWT_REQUEST:<n>` stdout protocol, and is already managing Pippin's own
  renamed binary (`pippinvr-xr`) today — not `newt-demo`.
- Dashboard code never reaches into `Session`'s private members (confirmed:
  the only `friend` on `Session` is the GPU hardware-test probe, not
  dashboard code). All dashboard ↔ core interaction goes through the public
  `Session`/`SessionDelegate` API.
- `Newt/tests/core_boundary_test.py` already proves five dashboard-exclusive
  headers (`NewtXRApp.h`, `InteractionGeometry.h`, `RayActivity.h`,
  `SystemCheck.h`, dashboard-local `NewtInternal.h`) can be physically
  deleted from the tree with `newt_core` still building/installing fine.

### The real blocker

`Capture.h`, `CaptureInternal.h`, and the root `PixelImage.h` (AppKit
drawing helpers) are **shared** between core and dashboard — core's
`Capture.mm`/`DrawHelpers.mm` implement them, dashboard's
`ScreenCapture.mm`/`MediaCapture.mm`/`FrameRenderer.mm`/`UI.mm` consume
them — but none of the three are installed/exported today
(`CMakeLists.txt` only installs `include/Newt/` + `Newt.h` + `NewtLog.h`).
This is the actual reason "build dashboard against an installed
`Newt::core`" doesn't work yet. Fix: promote these three headers into
`include/Newt/` as public headers. Small, mechanical CMake/install change,
not a design problem.

One genuine internal-API reach-through: `NewtXRApp.mm` calls
`HasLogHandler()`, which is core-internal with no public equivalent.
One-line fix — add a public wrapper to `Newt.h`/`Log.mm`.

### Size

~1,765 lines across 12 dashboard files (`NewtXRApp.mm`, `NewtAPI.mm`,
`RenderAssets.mm`, `XRInput.mm`, `Panels.mm`, `FrameRenderer.mm`, `UI.mm`,
`ScreenCapture.mm`, `MediaCapture.mm`, plus headers), not counting the
three shared headers above which stay in Newt core.

### Steps, in order

1. Promote `Capture.h`, `CaptureInternal.h`, root `PixelImage.h` to
   `include/Newt/` (or equivalent public location); update
   `CMakeLists.txt` install rules.
2. Add a public one-line replacement for the internal `HasLogHandler()`
   call.
3. Stand up Objective-C++ compilation inside Pippin's own SwiftPM target
   tree for the first time. Mechanically supported (SwiftPM compiles
   `.mm`, and `cxxLanguageStandard: .cxx17` is already set package-wide)
   but needs manual setup SwiftPM doesn't give for free: `-fobjc-arc` via
   `unsafeFlags` in `cSettings` (CMake currently sets this per-target),
   and `-I` paths for the Vulkan SDK / OpenXR headers (currently supplied
   to CMake via `VULKAN_SDK`/`OpenXR_DIR`).
4. Move the 12 dashboard files + dashboard-exclusive headers into
   `pippinVR-Server/`'s own source tree; wire them into the new SwiftPM
   target from step 3, linking only `Newt::core`.
5. Stop building/linking `newt_dashboard` from `build-newt.sh`/
   `Package.swift`; Newt ships core + daemon + optional USB only.
6. Decide the fate of three Newt tests that currently exercise dashboard
   code via CTest (`ownership_api_test.mm`, `interaction_geometry_test.cpp`,
   the `newt-render-settings-snapshot` tool): migrate to a Swift-side test
   harness, or explicitly accept the coverage loss. Don't let this happen
   by omission.
7. Verify the full protocol still works end-to-end (dashboard ↔ newtd ↔
   Godot handoff), since this is the kind of change that could silently
   break something even though the protocol itself isn't changing.

### Not required for this, but adjacent

`pippinVR-Server/PippinXR/` (the old, now-dead renderer + log bridge) is
called out in `ARCHITECTURE.md`/`ROADMAP.md` as cleanup to do *after* this
migration — its `vendor/lib` (OpenXR/Vulkan loader dylibs) is still
live-referenced by `Package.swift`'s linker flags and must not be deleted
wholesale. Treat as a separate follow-up, not part of this plan.

### Honest effort estimate

Multi-day, not multi-week. Nothing structurally hard turned up in the
research — the work is careful plumbing (header exports, first-time
Objective-C++-in-SwiftPM setup, moving ~1,765 lines, deciding what happens
to 3 tests), not a redesign.

---

## Part 2: Media selection — Spatial Video and 3D models

### Goal

Let Pippin's media picker add Apple Spatial Video (MV-HEVC) and 3D model
files (USDZ, glTF) as content in the VR environment, not just flat/manually
-stereo video and camera panels.

### Current state (confirmed)

- `MediaCapture.mm` decodes video via plain `AVPlayer`/
  `AVPlayerItemVideoOutput`, always requesting flat `kCVPixelFormatType_32BGRA`.
  No `AVAssetReader`, no multiview concept anywhere.
- "Stereo mode" in Newt is a **UV-split on one decoded texture**
  (`InteractionGeometry.h`'s `MakeScreen(arc, mode)` — mode only remaps
  texture coordinates, never creates a second view). It's built for
  pre-split side-by-side/over-under video files, not true dual-eye source.
- There is **no mesh/model system at all**: two unlit Vulkan pipelines
  (flat-color quads, single-texture UV quads with no lighting), no index
  buffers anywhere, every mesh is a procedurally-generated triangle list
  from `InteractionGeometry.h`. Zero hits for `usdz`/`gltf`/`ModelIO`/
  `SceneKit`/`RealityKit` in Newt's own source.
- Pippin's file picker (`DirectStatusItem.swift: addMediaFile`) is a single
  `NSOpenPanel` with `allowedContentTypes = [.movie]`, sending
  `add-media-file:<path>` unconditionally. Newt's `Panels.mm` treats *any*
  path reaching `add-media-file:` as a video for `MediaCaptureManager` —
  there is no format sniffing/dispatch by extension at all.

### Sub-plan A: Spatial Video (MV-HEVC)

This extends the existing pipeline; it does not need a new rendering
subsystem.

1. **Resolve the open question first**: does the macOS AVFoundation SDK
   Newt builds against actually expose tagged-buffer-group multiview
   output (`CMTaggedBufferGroup` / `AVPlayerItemVideoOutput` extensions,
   introduced primarily for visionOS/iOS)? This needs direct verification
   against the real SDK headers and a real spatial-video file — not
   assumed. If unavailable on macOS, the fallback is a `VTDecompressionSession`
   + manual HEVC multiview-layer parsing, which is a meaningfully bigger
   lift than calling a high-level API.
2. Add a spatial-video-aware branch to `MediaCapture.mm`'s video setup
   that extracts left/right eye `CVPixelBuffer`s per frame instead of one
   flat buffer.
3. Composite the two eye buffers into one side-by-side (or over-under)
   buffer on CPU each tick (same shape as `PixelImageFromCVPixelBuffer`'s
   output) and set `stereoMode=1` (or `3`) on that panel. This reuses the
   **existing** stereo rendering path with zero Vulkan/renderer changes.
   (Trade-off: this loses the zero-copy GPU `ImportPixelBuffer` IOSurface
   fast path for that panel, since the buffer is now CPU-synthesized —
   acceptable for v1.)
4. Pippin side: add the Spatial Video `UTType`(s) to the file picker's
   `allowedContentTypes`. Trivial once step 2-3 land — until then, adding
   the picker type alone does nothing differently from a flat video.
5. *(Future, not required for v1)*: a true dual-texture renderer mode
   (two descriptor sets / two draws per eye in `OnDrawEye`) to keep the
   GPU zero-copy path for spatial video specifically. Defer unless the
   CPU composite proves too costly in practice.

**Effort**: bounded — extension of working code, main risk is the API
research in step 1, not new architecture.

### Sub-plan B: 3D model files (USDZ, glTF)

This is a new subsystem, not an extension. Treat as its own project with
its own scoping/review, not a quick add alongside Spatial Video.

1. **Importer**: use Apple's `ModelIO` (`MDLAsset`) to load both USDZ and
   glTF on macOS — walk `MDLMesh`/`MDLSubmesh`/`MDLMaterial` to get raw
   vertex/index buffers and textures, rather than hand-rolling a glTF JSON
   parser or a USD parser (much larger, riskier).
2. **New Vulkan pipeline**: today's two pipelines are unlit and UV-only
   (`VertexPC` = position + UV). Models need at minimum position + normal
   + UV, a basic lit (Lambertian or PBR-lite) shader pair, and — if
   materials need more than one texture map (albedo/normal/roughness) — a
   richer descriptor set layout than the single combined-image-sampler
   used everywhere today.
3. **Indexed mesh buffers**: nothing in Newt uses index buffers today
   (everything is raw triangle-list quads via `vkCmdDraw`). Real meshes
   need `vkCmdDrawIndexed` support added to the `Buffer`/`VulkanResources.mm`
   machinery.
4. **Placement/interaction**: reuse the existing panel grab/move pattern
   (`mGrabbedPanel`/`mGrabHand`, pose stored as `XrPosef`) conceptually,
   but hit-testing needs a bounding-box/sphere proxy for v1 rather than
   true mesh raycasting (the existing `RayQuad`/`RayScreen`/`RayDock` are
   hardcoded analytic shapes for flat/curved/cylindrical panels, not
   arbitrary meshes — a bounding volume is sufficient to start).
5. Pippin side: add `.usdz`/glTF `UTType`s to the picker, and a new
   command (e.g. `add-model-file:<path>`) distinct from `add-media-file:`
   so `Panels.mm` can branch to a model-loading path instead of assuming
   `MediaCaptureManager`.

**Effort**: multi-week, new-subsystem-sized (importer + pipeline/shaders +
indexed-draw support + placement), not a small add.

### Recommended sequencing

Do Spatial Video first if this is wanted soon — it's bounded and reuses
working code; the one real unknown (macOS API availability) is answerable
with focused research against the actual SDK before writing any code.
Treat 3D model support as a separate, larger initiative with its own
planning pass, not bundled into the same effort.
