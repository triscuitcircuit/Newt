# GitHub builds

Upload the contents of the **Newt folder as the repository root**, including its hidden `.github` and `.gitignore` entries. The parent application and external headset runtime are separate projects. No GitHub repository has been created or uploaded by these changes.

`.github/workflows/macos.yml` runs on pushes, pull requests, and manual **Actions → macOS library and Godot addon → Run workflow** requests.

## Jobs and downloads

- Apple Silicon macOS 15: Release library/demo, with USB enabled and disabled.
- Intel macOS 15: Release library/demo with USB enabled.
- Both architectures: unit tests, installation, and a separate consumer that finds and links the installed `Newt::newt` CMake package (and `Newt::usb` when enabled).
- Godot addon: deterministic ZIP packaging, example import, and session-manager/editor-bridge tests against Godot 4.4.1 with XR disabled.

Download successful outputs from the workflow run's **Artifacts** section. Each architecture has a development SDK archive; `newt-godot-plugin` contains `newt-godot-plugin.zip`. The ZIP installs an `addons/newt_bridge` directory into a Godot project. Enable **Newt Play Bridge** in Project Settings → Plugins, then configure the local Newt installation/runtime.

The addon is GDScript/Python, so its build is packaging plus Godot validation, not a native compilation. `tools/package-godot-plugin.py` refuses to package if the canonical addon, session-manager script, and example addon disagree. To rebuild locally:

```sh
python3 tools/package-godot-plugin.py
```

## Dependencies and limits

The workflow builds the OpenXR loader from pinned OpenXR-SDK release 1.1.53. Homebrew supplies Vulkan headers/loader, glslang, and optional USB dependencies. Homebrew formulas follow their current versions; the complete toolchain is not hermetically pinned. GitHub Actions themselves are pinned to commit revisions, with monthly Dependabot update proposals.

SDK archives are **development outputs**, not portable signed applications: demo binaries retain dependency search paths from the runner, and consumers need matching external OpenXR/Vulkan/libusb libraries. Rebuild/install locally (`cmake -S . -B build && cmake --build build && cmake --install build`, see [docs/INSTALL.md](INSTALL.md)) for a usable dashboard installation. No headset runtime, MoltenVK driver, USB streaming backend, signing credentials, or notarization is bundled. CI does not connect to hardware or confirm headset rendering.

These workflows use read-only repository permissions and do not publish releases, push commits, or deploy applications. A GitHub-hosted run can only be verified after the repository is uploaded.

References: [GitHub runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [OpenXR SDK](https://github.com/KhronosGroup/OpenXR-SDK), [Vulkan loader formula](https://formulae.brew.sh/formula/vulkan-loader), [Godot 4.4.1 downloads](https://github.com/godotengine/godot-builds/releases/tag/4.4.1-stable).

## Ignore rules

`.gitignore` excludes build trees, compiled libraries, generated ZIPs, local dependency staging, Godot caches, Python environments, and machine-specific files. It keeps Godot `.uid` source metadata, example source projects, documentation, shaders, and license notices. Ignore rules do not untrack files previously committed; inspect `git status` before publishing.

The arm64 USB-disabled job also runs `tests/core_boundary_test.py`. It removes
product sources and headers from a temporary source copy, builds and installs
core only, and checks a plain C++ consumer of `Newt::core`. This protects the
session/delegate boundary independently of the dashboard and Godot addon jobs.
