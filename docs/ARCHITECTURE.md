# Newt implementation layout

Handwritten source files are kept below roughly 500 lines by separating responsibilities, rather than dividing methods at arbitrary line boundaries. Generated shader byte arrays and third-party dependencies are excluded.

## Layers

Newt is separated into a product-neutral runtime core (the MIT library) and
a reference dashboard/product layer. `newt_core` (`Newt::core`) is a
standalone static library with no symbol dependencies on the dashboard;
`newt_dashboard` (`Newt::dashboard`, sources in `dashboard/`) links it.
`Newt::newt` remains as an interface aggregate (core + dashboard) so
existing consumers are unaffected. The dashboard is named for Newt, not
Pippin: Pippin is one future host of this layer, not a Newt build concept.

- **Core** (`newt_core`): `CoreLifecycle.mm`, `CoreInput.mm`, `CoreFrame.mm`,
  `CorePipelines.mm`, `XRSession.mm`, `VulkanResources.mm`, pixel helpers and
  logging. Public C++ API: `include/Newt/Session.h`.
- **Dashboard** (`newt_dashboard`): product UI, capture sources, panels,
  interaction and host command handling. `NewtXR` owns a `unique_ptr<Newt::Session>`
  and implements `SessionDelegate`; core never includes `NewtXRApp.h`.

Logging is the first delegate seam: `include/NewtLog.h` lets an embedding
host receive Newt's log lines (Pippin forwards them into its `Logger`);
with no handler installed, output goes to stdout/stderr as before.

`Session::Run` owns initialization, input polling, frame submission and cleanup.
It borrows the delegate only during this synchronous call. Callbacks run on the
calling thread; only `RequestStop` may be called from another thread.
`OnSystem` permits host policy checks, `OnReady` allocates host resources,
`OnInput` interprets controller snapshots, `OnPrepareFrame` uploads content,
and `OnDrawEye` records drawing inside an active render pass. `OnStopping`
releases host resources before the core destroys its device, including after
initialization or callback failure. It must not throw.

Configure `NEWT_BUILD_DASHBOARD=OFF` for a core-only package. The demo is then
omitted; `Newt::newt` links core only, so dashboard C entry points are unavailable.
C++ consumers should explicitly link `Newt::core` and include `<Newt/Session.h>`.
Public session/image headers work in ordinary C++; AppKit drawing helpers remain
internal. Resource handles returned to a delegate must be destroyed through the
session before `OnStopping` returns. The frame command buffer and eye view are
borrowed for that callback only.

Remaining Phase-2 work: move the dashboard to Pippin, rewire SwiftPM and remove
its duplicate renderer after verifying the installed-core integration on hardware.

| Component | Responsibility |
| --- | --- |
| `dashboard/NewtAPI.mm` | C entry points, bounded host command queues, stop requests |
| `dashboard/NewtXRApp.mm` | Dashboard callbacks and product resource teardown |
| `XRSession.mm` | OpenXR/Vulkan setup, reference space, swapchains |
| `VulkanResources.mm` | Buffer and texture allocation, upload, destruction |
| `dashboard/RenderAssets.mm` | Dashboard meshes and textures |
| `dashboard/FrameRenderer.mm` | Capture uploads and per-eye frame drawing |
| `dashboard/XRInput.mm` | Dashboard controller interaction |
| `dashboard/Panels.mm` | Panel commands, selection, ray hit testing |
| `Capture.mm` | Shared pixel conversion and capture settings |
| `dashboard/ScreenCapture.mm` | ScreenCaptureKit and desktop fallback |
| `dashboard/MediaCapture.mm` | AVFoundation camera/video sources |

## Ownership

`NewtXR` is noncopyable and owns panels through `unique_ptr`. A panel exclusively owns its capture backend. `FrameSource` provides the common frame retrieval, rate, and stop interface; backend-specific setup remains on its concrete class.

Capture delegates use ARC internally and a `unique_ptr` with a Core Foundation release deleter at the C++ boundary. Their callback back-pointers to capture managers are borrowed: stop clears those pointers on the serial capture queue before releasing the delegate. They must not become `shared_ptr`, which would obscure ownership and risk cycles.

USB construction uses a `unique_ptr` until successful ownership transfer through the C API. `NewtUSB_Close` takes ownership back and invokes the destructor, which releases the claimed interface, device, and context. Public C APIs still use opaque pointers so C callers remain supported.

One-shot command buffers use a lambda deleter to release their Vulkan allocation on both success and exceptions. Long-lived Vulkan/OpenXR handles remain API handles, not C++ heap pointers; `NewtXR::Cleanup` destroys them in dependency order. Swapchain images supplied by OpenXR are borrowed and are never destroyed by Newt; its image views and depth attachments are owned. This is deliberately not a blanket conversion of every pointer to a smart pointer.

No existing object requires shared C++ ownership, so `shared_ptr` is not used. Use it only when two independently-lived components must keep the same object alive. Borrowed pointers, mapped-memory addresses, callback parameters, and C API handles remain explicit non-owning views.

Headers use include guards, including generated shader headers. Internal helper headers are not part of the installed public API. `include/Newt.h` and `include/NewtUSB.h` remain the public C interfaces.
