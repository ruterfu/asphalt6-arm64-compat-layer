# Asphalt 6 arm64 Compatibility Layer

[中文](README.md) | **English**

A compatibility layer that runs *Asphalt 6: Adrenaline* (iOS 1.3.2, 2011) on modern iPhones (arm64, iOS 17 or later).

This repository contains only the compatibility layer code. It does not include the game program, artwork or audio. You need your own copy of the game IPA and build the installable app on your own Mac.

## Features

- Runs the original *Asphalt 6* 1.3.2 on arm64 iPhones; on an iPhone 17 Pro races average about 58–60 fps (around 50 when the phone heats up and throttles)
- Targets 30 fps in Low Power Mode and returns to 60 fps when it is disabled, including changes made while the game is running
- Adapted only for 16:9 and full-screen (about 2.2:1) iPhones, such as the iPhone 17 Pro: the interface is not stretched and the 3D view is shown 1:1 at the screen's real aspect (the 3D part needs the HD background pack). Other screens (such as iPad) get no adaptation; the 3:2 image is simply stretched to fill the screen
- Multiplayer Bluetooth (unsupported) and online entries are disabled; store services are removed; the iPod music library entry is removed (the game's own music still plays)
- Optional HD background pack (16:9 and full-screen 2.2:1). On these two screen types the 3D view is shown 1:1 only with the pack installed; without it the 3D view is stretched from 3:2 to fill the screen, while the interface is still adapted
- **iPhone Duo is not supported**

## Screenshots

Taken on an iPhone 17 Pro with the HD background pack installed. Gameplay recording on device: [watch on X](https://x.com/ruterfu/status/2113627084392444200)

| | |
| --- | --- |
| ![Title screen](images/title.jpg) | ![Main menu](images/menu.jpg) |
| Title screen | Main menu |
| ![Career league](images/career.jpg) | ![Car selection](images/car-select.jpg) |
| Career league | Car selection |
| ![Tuning](images/tuning.jpg) | ![Garage](images/garage.jpg) |
| Tuning | Garage |
| ![Race loading](images/loading.jpg) | ![In the race](images/race.jpg) |
| Race loading | In the race |
| ![Elimination](images/elimination.jpg) | ![Race result](images/win.jpg) |
| Elimination | Race result |

## How it works

At build time, Ghidra disassembles the game's ARMv7 program and it is converted once into C++ code, which Xcode compiles into arm64 code and links into the app together with the compatibility layer, so what runs is native arm64 code. Nothing is generated or interpreted at runtime (no JIT).

The converted code keeps the exact behaviour of the original ARMv7 instructions, including registers, the 32-bit memory space, condition flags and floating point. The iOS 3/4-era system interfaces the game uses (UIKit, OpenGL ES, audio, touch, accelerometer, etc.) are re-implemented by the compatibility layer on top of modern iOS APIs.

Every intermediate build result is checked against fixed hashes, so the same IPA yields byte-identical conversion output on any Mac.

## Requirements

- Apple Silicon Mac (M-series chip)
- Xcode (with the iOS 17 or later SDK; the full Xcode app is required, not just the Command Line Tools)
- CMake 3.20 or later (`brew install cmake`)
- Python 3.9 or later (bundled with macOS)

The Python dependencies, Ghidra 12.1.4 and JDK 21 are downloaded into `build/` on the first build. All build output stays in `build/`; delete it to clean everything.

### Supported game version

Only **Asphalt 6 1.3.2** is supported (P.S. 1.3.2 is simply the version I happened to download first; by the time I learned the latest is 1.3.8 it was too late to switch). You can search Archive.org for the IPA.

| Item | Value |
| --- | --- |
| IPA file | `Asphalt_6_Adrenaline_1.3.2_ios_3.1.3.ipa` (564,685,789 bytes) |
| IPA SHA-256 | `30ea95d5ccd3fb9ded3b7b6b0c9e88f6af8de62d8c841ed0a3f79be6d045a796` |
| Game program ARMv7 slice SHA-256 | `4a2209881ab5933113a15770b0615807cfa7d73bf50a9326569a7ed20f77df00` |

The build script checks the hash of the game program's ARMv7 slice, so a repackaged IPA works as long as the program inside is identical.

## Building

```sh
python3 scripts/buildGame.py /path/to/Asphalt6.ipa
```

That one command is all it takes in principle. A full build takes about 1.5–2.5 hours, since it compiles over 3,000 AOT files. When it finishes, the IPA and the game resource pack are in `dist/`:

| File | Description |
| --- | --- |
| `Asphalt6ARM64.ipa` | Unsigned app; sign and install it with SideStore, AltStore or similar tools |
| `Asphalt6Data.zip` | Game resource pack |

| Option | Description |
| --- | --- |
| `--jobs N` | Parallel compile jobs; defaults to half the CPU cores |
| `--debug` | Compile with debug info |

## Installation

1. Sign and install `Asphalt6ARM64.ipa`, then open it once (it asks you to import the resources).
2. In the Files app, put `Asphalt6Data.zip` into **On My iPhone → Asphalt 6**. Do not unzip it; the app extracts it.
3. Back in the app, tap "重新检测" (check again), or quit and reopen it; the resources are extracted and verified automatically, then the game starts.

### HD background pack (optional)

The HD background pack `NativeArtwork.zip` is uploaded separately to Google Drive: [download it here](https://drive.google.com/file/d/1o8iHwtRP0q2xYJgAp07VcnXXSXm7BQE5/view?usp=sharing). Put it in the same folder as the resource pack; it is installed at launch, the title, menu and loading screens switch to HD backgrounds, and the 1:1 3D view is enabled, showing a wider field of view than the original game.

> The HD backgrounds are based on the original game backgrounds and were redrawn with GPT Image 2 in 16:9 and 2.2:1, for 16:9 screens and full-screen phones respectively. They have no effect on other screens (such as iPad).

## Testing

Test device: iPhone 17 Pro (iOS 27.0). iPhone Duo is not supported.

| Feature | Status |
| --- | --- |
| Career mode | ✅ Works |
| Single player | ✅ Works |
| Multiplayer | ⚠️ Local Wi-Fi can be entered; a two-device match is not tested; online and Bluetooth are unsupported |

Frame rate test (Career race 1 · Nassau, full race):

| Version | Average frame rate | Average frame time |
| --- | --- | --- |
| Baseline | about 36 fps | 25.3 ms |
| + register promotion | about 53 fps | 18.7 ms |
| + caching for external calls and indirect jumps | about 57 fps | 17.4 ms |
| + NEON single-precision hardware fast path (current) | about 60 fps | 16.6 ms |

## Copyright

The game program, artwork, audio and related trademarks of *Asphalt 6: Adrenaline* belong to Gameloft. This project is not affiliated with Gameloft and does not include or distribute any game content. The images in the HD background pack are based on the original backgrounds and were redrawn with the help of GPT Image 2; their content and art design likewise belong to Gameloft.

## License

- The compatibility layer code is released under the [MIT License](LICENSE) (except `aot/math/`).
- `aot/math/` is derived from QEMU SoftFloat and keeps its SoftFloat-2a / BSD / GPL-2.0-or-later licensing; see [`aot/math/NOTICE.md`](aot/math/NOTICE.md).
