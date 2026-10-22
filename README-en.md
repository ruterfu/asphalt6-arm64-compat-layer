# Asphalt 6 arm64 Compatibility Layer

[中文](README.md) | **English**

A compatibility layer that runs *Asphalt 6: Adrenaline* (iOS 1.3.2, 2011) on modern iPhones (arm64, iOS 17 or later).

This repository contains only the compatibility layer code. It does not include the game program, artwork or audio. You need your own copy of the game IPA and build the installable app on your own Mac.

## Features

- Runs the original 1.3.2 game on arm64 iPhones, about 60 fps in races on device
- Full-screen and safe-area layout
- Works with the current OpenGL ES driver
- Removes the discontinued store, promotion and iPod music player entry points; the app never asks for music library access
- Optional 16:9 HD background pack

## How it works

At build time, the game's ARMv7 program is analyzed with Ghidra and converted once into C++ sources, which Xcode compiles into arm64 code and links into the app together with the compatibility layer. Nothing is generated or interpreted at runtime (no JIT).

The converted code keeps the exact behaviour of the original ARMv7 instructions, including registers, the 32-bit memory space, condition flags and floating point. The iOS 3/4-era system interfaces the game uses (UIKit, OpenGL ES, audio, touch, accelerometer, etc.) are re-implemented by the compatibility layer on top of modern iOS APIs.

Every intermediate build result is checked against fixed hashes, so the same IPA yields byte-identical conversion output on any Mac.

## Requirements

- Apple Silicon Mac
- Xcode (with the iOS 17 or later SDK)
- CMake 3.20 or later
- Python 3.9 or later

The Python dependencies, Ghidra 12.1.4 and JDK 21 are downloaded into `build/` on the first build.

### Supported game version

Only **Asphalt 6 1.3.2** is supported (P.S. 1.3.2 is simply the version I downloaded first, and I didn't want to deal with others). You can search Archive.org for the IPA.

| Item | Value |
| --- | --- |
| IPA file | `Asphalt_6__Adrenaline_1.3.2_ios_3.1.3.ipa` (564,685,789 bytes) |
| IPA SHA-256 | `30ea95d5ccd3fb9ded3b7b6b0c9e88f6af8de62d8c841ed0a3f79be6d045a796` |
| Game program ARMv7 slice SHA-256 | `4a2209881ab5933113a15770b0615807cfa7d73bf50a9326569a7ed20f77df00` |

The build script checks the hash of the game program's ARMv7 slice, so a repackaged IPA works as long as the program inside is identical.

## Building

```sh
python3 scripts/buildGame.py /path/to/Asphalt6.ipa
```

A full build takes about 1.5–2.5 hours, mostly compiling. Outputs are written to `dist/`:

| File | Description |
| --- | --- |
| `Asphalt6ARM64.ipa` | Unsigned app; sign and install it with SideStore, AltStore or similar tools |
| `Asphalt6Data.zip` | Game resource pack |

| Option | Description |
| --- | --- |
| `--jobs N` | Parallel compile jobs; defaults to half the CPU cores |
| `--debug` | Compile with debug info |

## Installation

1. Sign and install `Asphalt6ARM64.ipa`, then open it once.
2. In the Files app, put `Asphalt6Data.zip` into **On My iPhone → Asphalt 6**. Do not unzip it.
3. Open the app again; the resources are extracted and verified automatically, then the game starts.

### HD background pack (optional)

The HD background pack `NativeArtwork.zip` is published separately: [download (Google Drive)](https://drive.google.com/file/d/1o8iHwtRP0q2xYJgAp07VcnXXSXm7BQE5/view?usp=sharing). Put it in the same folder as the resource pack; it is installed at launch, and the title, menu and loading screens switch to 16:9 HD backgrounds. Without it, the original backgrounds are used.

The HD backgrounds are based on the original game backgrounds and were redrawn in 16:9 with GPT Image 2.

## Testing

Test device: iPhone 17 Pro (iOS 27.0). iPhone Duo is not supported yet.

| Feature | Status |
| --- | --- |
| Career mode | ✅ Works |
| Single player | ✅ Works |
| Online | ⚠️ Not tested |

Frame rate (Career race 1 · Nassau, full race):

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
