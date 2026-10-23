# Asphalt 6 arm64 兼容层

**中文** | [English](README-en.md)

让《狂野飙车 6》（Asphalt 6: Adrenaline，iOS 1.3.2，2011 年）在现代 iPhone（arm64，iOS 17 及以上）上运行的兼容层。

本仓库只包含兼容层代码，不包含游戏程序、美术或音频。你需要自备游戏 IPA，在自己的 Mac 上构建出可安装的 App。

## 特性

- 在 arm64 iPhone 上运行原版《狂野飙车 6》1.3.2，iPhone 17 Pro 上比赛中平均约 58–60 fps（手机发热降频时会掉到 50 左右）
- 仅适配 16:9 与全面屏（约 2.2:1）的 iPhone（例如 iPhone 17 Pro）：界面不拉伸，3D 画面按屏幕真实比例 1:1 显示（3D 部分需要高清背景包）。其他屏幕（例如 iPad）不做任何适配，3:2 画面直接拉伸铺满
- 多人游戏关闭了蓝牙（不支持）和在线（估计 Gameloft 早就关闭服务器了吧）的入口；移除商店相关服务；移除 iPod 音乐库播放入口（游戏自带音乐正常）
- 可选的高清背景包（16:9 与全面屏 2.2:1）。在这两种屏幕上，装了才会 1:1 显示 3D 画面；没装时 3D 画面按 3:2 拉伸铺满，界面仍会适配
- **不支持 iPhone Duo机型（没机器，没钱，耗费精力不值得）iPhone Duo估计是无脑拉伸**

## 截图

iPhone 17 Pro 实机截图，已装高清背景包。实机演示录屏：[在 X 上观看](https://x.com/ruterfu/status/2113624582498476257)

| | |
| --- | --- |
| ![标题画面](images/title.jpg) | ![主菜单](images/menu.jpg) |
| 标题画面 | 主菜单 |
| ![生涯联赛](images/career.jpg) | ![选车](images/car-select.jpg) |
| 生涯联赛 | 选车 |
| ![改装](images/tuning.jpg) | ![车库](images/garage.jpg) |
| 改装 | 车库 |
| ![比赛加载](images/loading.jpg) | ![比赛中](images/race.jpg) |
| 比赛加载 | 比赛中 |
| ![淘汰](images/elimination.jpg) | ![比赛结算](images/win.jpg) |
| 淘汰 | 比赛结算 |

## 工作原理

构建时将游戏的 ARMv7 程序经 Ghidra 分析（反汇编）后被一次性转换为 C++ 代码，再由 Xcode 编译为 arm64 代码，与兼容层一起链接进 App，运行的是原生 arm64 代码。运行时不生成或解释任何代码（没有 JIT）。

转换后的代码逐条保持与原版 ARMv7 指令一致的行为，包括寄存器、32 位内存空间、条件标志与浮点运算。游戏用到的 iOS 3/4 时代系统接口（UIKit、OpenGL ES、音频、触控、重力感应等）由兼容层基于现代 iOS 接口重新实现。

构建的每个中间结果都有固定校验值，同一 IPA 在任何 Mac 上得到的转换结果逐字节相同。

## 环境要求

- Apple Silicon Mac（M芯片 的Mac）
- Xcode（含 iOS 17 及以上 SDK，必须安装 应用，而不是 Command Line）
- CMake 3.20 及以上（brew install cmake 就行）
- Python 3.9 及以上（自带）

Python 依赖、Ghidra 12.1.4 与 JDK 21 会在首次构建时自动下载到 `build/`。所有编译产物都在 `build/` 下，删掉即可全部清理。

### 支持的游戏版本

仅支持 **Asphalt 6 1.3.2**（p.s. 因为我一开始就随意下的1.3.2，得知最新的是1.3.8，已经来不及了，算了不想折腾了）。IPA 可以自行在 Archive.org 搜索获取。

| 项目 | 值 |
| --- | --- |
| IPA 文件 | `Asphalt_6_Adrenaline_1.3.2_ios_3.1.3.ipa`（564,685,789 字节） |
| IPA SHA-256 | `30ea95d5ccd3fb9ded3b7b6b0c9e88f6af8de62d8c841ed0a3f79be6d045a796` |
| 游戏程序 ARMv7 部分 SHA-256 | `4a2209881ab5933113a15770b0615807cfa7d73bf50a9326569a7ed20f77df00` |

构建脚本校验的是游戏程序 ARMv7 部分的哈希，重新打包过的 IPA 只要其中的程序一致即可使用。

## 构建

```sh
python3 scripts/buildGame.py /path/to/Asphalt6.ipa
```

理论上这一句话就行，完整构建约 1.5–2.5 小时，因为需要编译3000多个 AOT文件。编译完成后，ipa文件和游戏资源包都在 `dist` 下：

| 文件 | 说明 |
| --- | --- |
| `Asphalt6ARM64.ipa` | 未签名的 App，用 SideStore、AltStore 等工具签名安装 |
| `Asphalt6Data.zip` | 游戏资源包 |

| 参数 | 说明 |
| --- | --- |
| `--jobs N` | 编译并行数，默认为 CPU 核数的一半 |
| `--debug` | 编译时带调试信息 |

## 安装

1. 签名并安装 `Asphalt6ARM64.ipa`，打开一次（会显示请导入资源）。
2. 在“文件”App 中，把 `Asphalt6Data.zip` 放进 **我的 iPhone → Asphalt 6**，无需解压，游戏进去后会自动解压。
3. 再次打开 App，点击重新检测，或者直接kill掉它重开，资源会自动解压并校验，完成后进入游戏。

### 高清背景包（可选）

高清背景包 `NativeArtwork.zip` 已单独上传到 Google Drive：[点此下载](https://drive.google.com/file/d/1o8iHwtRP0q2xYJgAp07VcnXXSXm7BQE5/view?usp=sharing)。把它和资源包放在同一目录，启动时会自动安装，标题、菜单与加载画面改用高清背景，同时激活1:1渲染，可以看到比原版游戏更宽的视野。

>  高清背景以游戏原版背景为基础，使用 GPT Image 2 重绘为 16:9 与 2.2:1 两种画幅，分别对应 16:9 屏幕和全面屏，其他屏幕（例如 iPad）不生效。

## 测试

测试设备：iPhone 17 Pro（iOS 27.0）。不支持 iPhone Duo。

| 功能 | 状态 |
| --- | --- |
| 生涯模式 | ✅ 正常 |
| 单人游戏 | ✅ 正常 |
| 联机 | ⚠️ 本地 WiFi 可进入，两台设备联机未实测；在线与蓝牙不支持 |

帧率测试（生涯第 1 场 · 拿索，完整比赛）：

| 版本 | 平均帧率 | 平均每帧耗时 |
| --- | --- | --- |
| 基础版本 | 约 36 fps | 25.3 ms |
| + 寄存器优化 | 约 53 fps | 18.7 ms |
| + 外部调用与间接跳转缓存 | 约 57 fps | 17.4 ms |
| + NEON 单精度硬件快速路径（当前） | 约 60 fps | 16.6 ms |

## 版权声明

《狂野飙车 6》（Asphalt 6: Adrenaline）的游戏程序、美术、音频及相关商标归 Gameloft 所有。本项目与 Gameloft 无关，不包含也不分发任何游戏内容。高清背景包中的图片基于原版背景，借助 GPT Image 2 重绘，其画面内容与美术设计同样归 Gameloft 所有。

## 许可

- 兼容层代码以 [MIT 许可证](LICENSE) 发布（`aot/math/` 除外）。
- `aot/math/` 源自 QEMU SoftFloat，沿用其 SoftFloat-2a / BSD / GPL-2.0-or-later 许可，详见 [`aot/math/NOTICE.md`](aot/math/NOTICE.md)。
