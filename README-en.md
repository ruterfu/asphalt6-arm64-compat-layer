# Asphalt 6 arm64 Compatibility Layer

[中文](README.md) | **English**

A compatibility layer that runs *Asphalt 6: Adrenaline* (iOS 1.3.2, released in 2011) on modern iPhones (arm64, iOS 17 or later).

This repository contains **only the compatibility layer code**. It does not include the game program, the original artwork or audio. You need your own legally obtained game IPA and build the installable app on your own Mac.

## What the compatibility layer provides

- **Runtime**: runs the game program on arm64 and provides the iOS 3/4-era system interfaces it depends on (UIKit, Foundation, OpenGL ES, audio, touch, accelerometer, threads and files).
- **Full-screen layout**: the picture is laid out again for modern screen ratios and safe areas, and UI elements (back button, skip button, car selection buttons, etc.) are adjusted to match.
  - Tested device: iPhone 17 Pro (iOS 27.0);
  - iPhone Duo is not supported yet.
- **Graphics**: OpenGL ES calls are adapted to the current driver; three old shaders get declaration fixes at build time so that they compile on the current driver.
- **Optional HD background pack**: see below.

## How it works

### Ahead-of-time compilation, not runtime translation

The game's ARMv7 program is converted **at build time**, once, into C++ sources (3214 program modules), which Xcode's clang compiles into arm64 machine code and links into the app together with the compatibility layer.

Everything that runs on the phone is this precompiled arm64 code:

- No code is generated at runtime (no JIT), and instructions are not interpreted one by one;
- The approach is similar to Rosetta 2's ahead-of-time translation, and the app needs no special entitlements.

### Why it is slower than a native program

The converted code must keep exactly the same behaviour as the original ARMv7 instructions, so it works more like a "statically compiled emulator": it executes native instructions, but each original instruction usually takes several arm64 instructions.

- **Registers**: the ARMv7 registers live in a structure in memory. Register promotion keeps them in real CPU registers within a basic block and writes them back between blocks;
- **Memory**: the game sees the original 32-bit address space, so every load and store goes through address translation and bounds checks;
- **Condition flags and floating point**: condition flags are computed instruction by instruction; floating point follows the ARMv7 rounding, denormal and NaN rules bit for bit (software floating point), and uses the hardware directly in the common cases where the result is guaranteed to be identical;
- **Calls**: jumps through function pointers and calls into system functions look up the matching converted code or compatibility-layer implementation (with caching);
- **Execution slices**: code runs in segments with a fixed budget, so thread scheduling and the audio service can step in.

The optimizations listed under "Current status → Frame rate" all reduce this overhead.

### System interfaces

The iOS 3/4-era system interfaces the game calls (UIKit, Foundation, OpenGL ES, audio, touch, accelerometer, threads, files, etc.) are re-implemented by the compatibility layer on top of modern iOS APIs. Interfaces that no longer exist or no longer apply are either replaced by an equivalent implementation or reported as "unavailable" (see "Removed features").

### Reproducible builds

Every step of the conversion is checked against fixed hashes:

- Ghidra's analysis of the game program;
- the 3214 generated program modules;
- the host modules and data bundle;
- the resource files.

As long as you use the supported 1.3.2 IPA, anyone gets byte-identical results for the items above on their own Mac, and any mismatch stops the build. The final app binary may differ slightly depending on the Xcode version.

## Removed features

The following features depend on services that have shut down or system capabilities that no longer apply, so the compatibility layer removes them. At resource build time, the corresponding menu buttons are replaced by invisible, non-clickable empty elements that keep their original names, so the menu logic keeps working; the entry points simply no longer appear.

- **Store and promotions**: in-app purchases (cash, stars, unlocks), App Store links, "More Games", rating prompts and the Gameloft Live entry are all removed. StoreKit is never loaded, and no purchase prompt ever appears in the game.
- **Music player (iPod)**: the original game let you pick songs from the system music library as race music, from the pause menu and the sound settings. This feature is removed:
  - The music button in the pause menu and the playlist button in the sound settings are no longer shown, and the song list screen cannot be opened;
  - Whenever the game queries the system music library it is told the library is "unavailable", so the game's own music always plays;
  - The app never accesses the system music library and never asks for music library permission at launch.

## Requirements

Install yourself:

| Item | Requirement |
| --- | --- |
| Mac | Apple Silicon (M-series chip) |
| Xcode | Full Xcode with the iOS 17 or later SDK (the command line tools alone are not enough) |
| CMake | 3.20 or later, e.g. `brew install cmake` |
| Python | 3.9 or later (the one shipped with macOS is fine) |

Installed automatically into `build/` on the first run (needs internet, about 800 MB):

| Item | Version | Purpose |
| --- | --- | --- |
| Python packages | `scripts/requirements.txt`: capstone 5.0.7, tqdm 4.67.1 | Program conversion, progress display |
| Ghidra | 12.1.4 (official release, SHA-256 checked; the release lacks the Apple Silicon native component, which is built from its bundled sources on first use) | Analyzing the game program |
| JDK | Temurin 21.0.12.1 (official release, SHA-256 checked) | Running Ghidra |

You also need your own game IPA: **only Asphalt 6 1.3.2 is supported** (the build script verifies the game program inside it; 1.3.8 and other versions are not supported. P.S. 1.3.2 is simply the version I downloaded first, and I didn't want to deal with others). Hashes below.

### Supported game version

| Item | Value |
| --- | --- |
| Version | 1.3.2 (`CFBundleVersion`) |
| Verified IPA file | `Asphalt_6__Adrenaline_1.3.2_ios_3.1.3.ipa`, 564,685,789 bytes; you can search Archive.org for the IPA |
| IPA SHA-256 | `30ea95d5ccd3fb9ded3b7b6b0c9e88f6af8de62d8c841ed0a3f79be6d045a796` |
| SHA-256 of the game program's ARMv7 slice | `4a2209881ab5933113a15770b0615807cfa7d73bf50a9326569a7ed20f77df00` |

The build script goes by the hash of the **game program's ARMv7 slice**: a repackaged IPA may have a different file hash than above, but it works as long as the game program inside is identical. To check it yourself:

```sh
shasum -a 256 Asphalt6.ipa                                   # IPA file
unzip -p Asphalt6.ipa Payload/Asphalt6.app/Asphalt6 > Asphalt6.fat
lipo -thin armv7 Asphalt6.fat -output Asphalt6.armv7
shasum -a 256 Asphalt6.armv7                                 # game program ARMv7 slice
```

## Building

```sh
python3 scripts/buildGame.py /path/to/Asphalt6.ipa
```

The script runs in 6 steps. Every step checks its result against fixed SHA-256 hashes and stops immediately on any mismatch:

| Step | Terminal output | What it does |
| --- | --- | --- |
| 1 | `[1/6] Preparing toolchain` | Checks Xcode and CMake, installs the Python packages, downloads Ghidra and the JDK on the first run |
| 2 | `[2/6] Extracting the game IPA` | Unpacks the IPA and confirms it is the supported 1.3.2 release |
| 3 | `[3/6] Building game resources` | Assembles the game resource folder `Asphalt6Data` from the IPA |
| 4 | `[4/6] Translating the game program (about 20 minutes)` | Analyzes the game program with Ghidra, converts it into native C++ sources and applies per-basic-block register promotion; output goes to `build/generated/` (about 20 minutes) |
| 5 | `[5/6] Compiling AOT (about 1-2 hours)` | Compiles the iOS static libraries with CMake (about 1–2 hours) |
| 6 | `[6/6] Packaging` | Links and writes the unsigned app package, and packs the resources |

Every step shows its progress: downloading, export, conversion, register promotion and compilation have progress bars, and phases that cannot estimate progress (such as the Ghidra analysis) show the elapsed time. Ghidra's output is kept in `build/work/pcode/`, and the full compiler output in `build/compile.log`.

Outputs are written to `dist/`:

- `Asphalt6ARM64.ipa`: the unsigned app; sign and install it with SideStore, AltStore or similar tools;
- `Asphalt6Data.zip`: the game resource pack;
- `NativeArtwork.zip`: only produced when the local `artwork/` folder contains the HD images (for maintainers who publish the pack); regular users simply download the separately published HD background pack.

Options:

| Option | Effect |
| --- | --- |
| `--jobs N` | Number of parallel compile jobs; defaults to half the CPU cores |
| `--debug` | Compiles with debug info (`-g`) for crash logs and profiling; the machine code is identical, but `build/ios` grows to about 18 GB |
| `--no-promote` | Skips register promotion and compiles the conversion output directly (smaller code, faster compile) |

## Installation

1. Install `Asphalt6ARM64.ipa` and open it once (this creates the app's Documents folder and a resource import guide).
2. In the Files app, put `Asphalt6Data.zip` directly into **On My iPhone → (app name, taken from your IPA, usually Asphalt 6)**. Do not unzip it.
3. Optional: put the HD background pack `NativeArtwork.zip` into the same folder.
4. Open the app; the compatibility layer extracts and verifies everything automatically.

### Resource handling at launch

The on-screen messages are shown in Chinese; English translations are given in parentheses.

| Situation | On-screen message | What happens |
| --- | --- | --- |
| Every launch | 正在验证游戏资源 (Verifying game resources) | Verifies `Asphalt6Data` (later launches use a cache and are fast) and checks whether the HD backgrounds are complete |
| Resources missing or damaged, and `Asphalt6Data.zip` present | 正在解压资源包 (Extracting resource pack) | Deletes the old `Asphalt6Data`, extracts the pack, deletes the pack on success and verifies again; installed HD backgrounds are kept |
| Resources missing, no resource pack | 请先导入游戏资源 (Please import the game resources first) | Import the resource pack, then tap "重新检测" (Check again) |
| Resource pack damaged | 资源包 Asphalt6Data.zip 损坏，请先导入新资源包 (Asphalt6Data.zip is damaged, please import a new one) | Replace the pack, then tap "重新检测" (Check again) |
| Resources complete, HD backgrounds incomplete, and `NativeArtwork.zip` present | 正在解压高清背景包 (Extracting HD background pack) | Fills in the missing HD backgrounds, deletes the zip on success and verifies again |
| HD background pack damaged | 高清背景包 NativeArtwork.zip 解压失败 (Failed to extract NativeArtwork.zip) | The game starts normally; the zip is kept and retried on the next launch |
| Resources complete | 正在启动游戏 (Starting the game) | Any zips in the Documents folder are ignored |

Verifying and extracting show a percentage, e.g. "正在验证游戏资源 42%".

## HD background pack (optional)

The HD background pack `NativeArtwork.zip` is published separately from the code and is not included in this repository. Download it and put it into the app's Documents folder. If the HD backgrounds are incomplete at launch, the compatibility layer automatically:

1. extracts the missing files into `Asphalt6Data/NativeArtwork/`;
2. verifies each one against its SHA-256 and uses only the images that pass;
3. switches the title, menu and loading backgrounds to 16:9 HD versions.

Once the HD backgrounds are complete, any `NativeArtwork.zip` in the Documents folder is ignored.

Without the pack, or if an image in it is missing or damaged, the corresponding screen falls back to the original game background; the game is not affected.

> The images in the HD background pack are based on the original game backgrounds and were redrawn in 16:9 with GPT Image 2; their content and art design belong to Gameloft. The compatibility layer has the hash of every image built in and only uses images identical to the published version.

## Repository layout

| Path | Contents |
| --- | --- |
| `host/app/` | App entry point, launch flow and the resource check screen |
| `host/src/` | Main compatibility layer: system interfaces, graphics, audio, input, layout adaptation, resources and the HD background pack |
| `host/tests/` | Standalone tests for the compatibility layer |
| `aot/runtime/` | Runtime used by the converted program: register layout, memory access, scheduling interfaces |
| `aot/math/` | Software floating point library bit-identical to ARMv7 floating point (derived from QEMU SoftFloat) |
| `artwork/` | HD background images (not committed); packed into `NativeArtwork.zip` by the build when present |
| `scripts/buildGame.py` | One-command build entry point |
| `scripts/as6build/` | Implementation and verification data for each build step |
| `build/` | Everything generated during the build (toolchain, converted sources, compiler output); not committed, safe to delete as a whole |

## Current status

### Game features

Tested on iPhone 17 Pro (iOS 27.0):

| Feature | Status |
| --- | --- |
| Career mode | ✅ Works |
| Single player | ✅ Works |
| Online (multiplayer) | ⚠️ Not tested |

### Frame rate

Measured on iPhone 17 Pro (iOS 27.0) in Career race 1 · Nassau (the first map). Each version ran one full race, and screen refreshes were counted during the race (about 2–3 minutes):

| Version | Average frame rate | Average frame time | Frames over 16 ms |
| --- | --- | --- | --- |
| Baseline | about 36 fps | 25.3 ms | 100% |
| + register promotion | about 53 fps | 18.7 ms | 73% |
| + caching for external calls and indirect jumps | about 57 fps | 17.4 ms | 56% |
| + hardware fast path for NEON single-precision math (current) | about 59–60 fps | 16.6 ms | 46% |

- The current version averages 16.6 ms per frame, which matches the 60 Hz frame interval (16.67 ms), so races run at a nearly steady 60 fps. The "over 16 ms" threshold is slightly below 16.67 ms, so the remaining share is mostly normal vsync jitter;
- A few scenes in a race still dip briefly to about 55 fps;
- No stall longer than 100 ms occurred during races (loading screens excluded);
- Menus and result screens run at a steady 60 fps.

### Build pipeline

| Stage | Status |
| --- | --- |
| extract | ✅ Done and verified |
| resources | ✅ Done: the 963 files generated from the original IPA are byte-identical to the reference |
| HD background pack | ✅ Done: extraction, verification and missing-file fallback tested |
| codegen: Ghidra analysis and export | ✅ Verified: a fresh analysis export matches the reference exactly after normalization |
| codegen: conversion to C++ | ✅ Verified: the 3214 program modules, 48 host modules and data bundle generated from the 1.3.2 IPA are byte-identical to the reference |
| codegen: register promotion | ✅ Integrated, correctness verified by differential testing; race frame rate on device about 36 → 53 fps |
| compile / package | ✅ Fully compiled and running on device |
| Extracting the resource pack / HD background pack at launch | ✅ 7 cases tested on Mac, and verified on device |

## License

- Compatibility layer code: [MIT License](LICENSE) (except `aot/math/`).
- `aot/math/`: derived from QEMU's SoftFloat implementation and keeps its original mixed SoftFloat-2a / BSD / GPL-2.0-or-later licensing; see `aot/math/NOTICE.md` and `aot/math/vendor/licenses/`.
- The game program, artwork, audio and related trademarks of *Asphalt 6: Adrenaline* belong to Gameloft. This repository does not include the game program, original artwork or audio; the HD images redrawn from the original backgrounds likewise have their content and art design owned by Gameloft.
