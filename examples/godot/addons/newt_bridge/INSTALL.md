# Build, install, and configure Newt on macOS

Building Newt and configuring its headset runtime are separate steps. The OpenXR SDK supplies the **loader**, while the headset backend supplies a **runtime**. Installing the loader does not create Newt's runtime configuration.

## Build, test, and install

From the Newt checkout:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOME/.local" -DBUILD_TESTING=ON
cmake --build build -j 6
ctest --test-dir build --output-on-failure
cmake --install build
```

CMake auto-discovers the newest Vulkan SDK under `~/VulkanSDK`, and searches your install prefix, `/opt/homebrew`, and `/usr/local` for the OpenXR SDK's CMake package (`OpenXRConfig.cmake`). Optional USB support (`NEWT_WITH_USB`, default `AUTO`) enables itself automatically when libusb and pkg-config are available. No sudo is needed and no headset session is launched. Missing prerequisites are reported with installation instructions; dependencies are not automatically downloaded.

If OpenXR isn't under one of those prefixes (for example you built it straight from a clone elsewhere), point at it explicitly — either works the same way:

```sh
cmake -S . -B build -DOpenXR_DIR="/path/to/folder/containing/OpenXRConfig.cmake"
# or add a whole prefix to the search instead of one exact folder:
cmake -S . -B build -DNEWT_SDK_SEARCH_PATH="/path/to/install/prefix"
```

Use `python3 tools/find-libraries.py --root /path/to/your/OpenXR-or-runtime-source-tree` first if you're not sure where a loader or runtime manifest ended up.

Force USB on or off explicitly with `-DNEWT_WITH_USB=ON` (fails loudly if libusb is missing) or `-DNEWT_WITH_USB=OFF`. The main installed files are `$HOME/.local/bin/newt` (a symlink to the native `newtd` session manager), `$HOME/.local/bin/newt-demo`, and `$HOME/.local/lib/libnewt.a`. Add `$HOME/.local/bin` to `PATH` or use the full paths.

### Configuring the runtime in the same step

Pass `-DNEWT_CONFIGURE_RUNTIME=/path/to/runtime.json` (and optionally `-DNEWT_CONFIGURE_ICD=/path/to/MoltenVK_icd.json`) at configure time, and `cmake --install build` writes `~/Library/Application Support/Newt/config.json` right after installing — equivalent to running `newt configure` yourself afterward (see below). An existing `--godot` path from a previous configuration is preserved. Omit both and configure later instead, either via Godot's **Project → Tools → Configure Newt…** or the CLI.

## What to download and which path to use

| Item | Where to obtain it | Path Newt needs |
| --- | --- | --- |
| Xcode command-line tools | `xcode-select --install` | Tools must be available to CMake |
| CMake and Python 3.9+ | Your package manager; e.g. `brew install cmake python` | `cmake` and `python3` executables |
| OpenXR SDK / loader | [Khronos OpenXR-SDK](https://github.com/KhronosGroup/OpenXR-SDK) | `OpenXR_DIR`: the **folder containing `OpenXRConfig.cmake`** |
| Vulkan SDK for macOS | [LunarG downloads](https://vulkan.lunarg.com/sdk/home) | `VULKAN_SDK`: the **SDK's `macOS` directory**, commonly `$HOME/VulkanSDK/<version>/macOS` |
| libusb, optional | [libusb](https://libusb.info/); e.g. `brew install libusb pkg-config` | Found automatically via `pkg-config` (`NEWT_WITH_USB=AUTO`, the default); `=ON` requires it, `=OFF` disables it |
| Headset OpenXR runtime | A compatible macOS headset-runtime distribution, built separately | Runtime **JSON manifest**, whose `runtime.library_path` resolves to its runtime dylib |
| Vulkan ICD, when required | The Vulkan SDK or your runtime distribution | `MoltenVK_icd.json`, whose `ICD.library_path` resolves to the matching MoltenVK dylib |

**Do not set `VULKAN_SDK` to `libMoltenVK.dylib`.** The SDK directory provides headers, libraries, and shader tools. Likewise, the Newt setup dialog expects a runtime JSON file, not `libopenxr_loader.dylib` or `OpenXRConfig.cmake`.

Use this helper from the Newt checkout to print likely library locations:

```sh
python3 tools/find-libraries.py --root /path/to/your/OpenXR-or-runtime-source-tree
```

It also checks `$HOME/VulkanSDK`, `$HOME/.local`, and common CMake package locations. It only lists files; it does not connect to a headset. You can supply `--root` more than once. In an existing source checkout, the loader CMake package is often in `OpenXR-SDK/build/src/loader`; after SDK installation, look under the chosen prefix's `lib/cmake` directory. Use the actual directory reported by the helper.

## If you need to build the OpenXR loader

```sh
git clone https://github.com/KhronosGroup/OpenXR-SDK.git
cmake -S OpenXR-SDK -B OpenXR-SDK/build -DCMAKE_BUILD_TYPE=Release
cmake --build OpenXR-SDK/build -j 6
cmake --install OpenXR-SDK/build --prefix "$HOME/.local"
```

Then locate `OpenXRConfig.cmake` with the helper above and pass it as `-DOpenXR_DIR=...` (see "Build, test, and install" above). Keep this source/build tree if you point Newt at its build-tree CMake package rather than the installed one.

## Configure the headset runtime once

In Godot with Newt Play Bridge enabled, choose **Project → Tools → Configure Newt…**. Browse to:

1. `$HOME/.local/bin/newt-demo`.
2. The headset runtime's `.json` manifest.
3. Its Vulkan ICD `.json` manifest, if required.

Save. This writes `~/Library/Application Support/Newt/config.json` without starting a headset session. Then press Play. If you changed paths while the Newt manager was already running, stop that manager before retrying.

For terminal setup (or pass `-DNEWT_CONFIGURE_RUNTIME=`/`-DNEWT_CONFIGURE_ICD=` at install time instead, above):

```sh
newt configure \
  --dashboard "$HOME/.local/bin/newt-demo" \
  --runtime "/path/to/monado-runtime.json" \
  --icd "/path/to/MoltenVK_icd.json"
```

From a source checkout without installing, use `build/newtd configure ...` in place of `newt configure` (same `config.json`).

For an app-bundled runtime, Finder's **Show Package Contents** exposes `Contents/Resources/OpenXR/`. Keep the complete app/runtime package intact: its JSON commonly refers to dylibs in `Contents/Frameworks/` using relative paths. Copying only the JSON breaks those references.

Newt does not currently distribute its own complete headset runtime. Developers need an existing compatible runtime package; the upstream OpenXR SDK alone cannot provide USB headset streaming. This prerequisite is independent of Newt's MIT library and optional libusb support.
