# Testing Newt

Build with `BUILD_TESTING=ON` (the installer does this), then run:

```sh
ctest --test-dir build-install --output-on-failure
```

The normal suite does not start VR, access a camera, or connect USB devices:

- **session-lifecycle**: missing-runtime failure, exactly-once stopping callback, clean handles and retry on the same session object.
- **usb-validation** (USB enabled): invalid argument handling and null-safe close.
- **usb-ownership** (USB enabled): fake libusb failures during initialization, enumeration, opening, and interface claiming; successful close releases each resource exactly once. This compiles the real USB implementation against a fake backend.

Additional integration tests:

```sh
python3 tests/session_manager_test.py
```

That suite uses temporary state directories and fake child processes, and optionally the locally installed Godot for editor-plugin checks with XR disabled. It needs permission to create local Unix sockets. It does not verify headset rendering.

## Runtime integration boundary

Newt does not include the headset runtime. Tests for Vulkan resolver selection and cross-device Metal texture sharing live with that separate runtime, not in Newt's MIT source package. The GPU import test verifies a distinct target-device image, a stereo array view, and cleanup; it is not a substitute for a Godot/headset rendering test. Validate that separately after restarting the runtime and game.

## Core boundary

`python3 tests/core_boundary_test.py -DOpenXR_DIR=/path/to/loader/cmake`
accepts additional CMake dependency options. It builds core, runs tests,
installs into a temporary prefix and compiles/runs a plain C++ consumer linked
only to the installed `Newt::core`. Dashboard/product UI no longer lives in
this tree at all (see docs/ARCHITECTURE.md) -- this test now mainly guards
against something in core accidentally growing a new product-UI dependency.
It never starts a real runtime.
