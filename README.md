# Asphalt 6 arm64 兼容层

让 2011 年发布的《狂野飙车 6》（Asphalt 6: Adrenaline，iOS 1.3.2）在现代 iPhone（arm64，iOS 17 及以上）上运行的兼容层。

本仓库**只包含兼容层代码**，不包含任何游戏程序、美术或音频。使用者需要自备合法取得的游戏 IPA，在自己的 Mac 上构建出可安装的 App。

## 兼容层提供的能力

- **运行环境**：在 arm64 上执行游戏程序，提供它依赖的 iOS 3/4 时代系统接口（UIKit、Foundation、OpenGL ES、音频、触控、重力感应、线程与文件）。
- **全面屏适配**：画面按现代屏幕比例与安全区重新布局，界面元素（返回键、跳过键、选车按钮等）随之调整。
- **图形兼容**：OpenGL ES 调用适配到当前驱动；构建时为三段旧着色器做声明修正，使其能在当前驱动上编译。
- **离线可用**：构建时把菜单中的内购与推广入口替换为空元素，菜单逻辑不受影响。
- **音乐**：游戏音乐由本机音频服务播放，可正常暂停、恢复。
- **稳定性**：
  - 后台加载（例如快速切换车辆）时，游戏线程会把执行权优先让给主线程，画面和触控持续响应，不会被系统看门狗终止；
  - 离线事件队列文件（`Documents/events.dat`）超过 1MB 时会在启动前自动移开，避免它无限增长导致启动失败。
- **可选高清背景包**：见下文。

## 环境要求

| 项目 | 版本 |
| --- | --- |
| macOS + Xcode | 含 iOS 17 及以上 SDK |
| CMake | 3.20 及以上 |
| Python | 3.9 及以上 |
| Ghidra | 12.1.4（构建时用于分析游戏程序） |
| JDK | 21 |
| 游戏 IPA | **仅支持 Asphalt 6 1.3.2**（构建脚本会校验其中的程序；1.3.8 等其他版本不受支持），校验值见下 |

### 支持的游戏版本

| 项目 | 值 |
| --- | --- |
| 版本 | 1.3.2（`CFBundleVersion`） |
| 已验证的 IPA 文件 | `Asphalt_6__Adrenaline_1.3.2_ios_3.1.3.ipa`，564,685,789 字节 |
| IPA 的 SHA-256 | `30ea95d5ccd3fb9ded3b7b6b0c9e88f6af8de62d8c841ed0a3f79be6d045a796` |
| 游戏程序 ARMv7 部分的 SHA-256 | `4a2209881ab5933113a15770b0615807cfa7d73bf50a9326569a7ed20f77df00` |

构建脚本以**游戏程序 ARMv7 部分**的哈希为准：重新打包过的 IPA，文件哈希可能和上表不同，但只要其中的游戏程序一致，就可以使用。自行核对：

```sh
shasum -a 256 Asphalt6.ipa                                   # IPA 文件
unzip -p Asphalt6.ipa Payload/Asphalt6.app/Asphalt6 > Asphalt6.fat
lipo -thin armv7 Asphalt6.fat -output Asphalt6.armv7
shasum -a 256 Asphalt6.armv7                                 # 游戏程序 ARMv7 部分
```

## 构建

```sh
python3 scripts/buildGame.py /path/to/Asphalt6.ipa \
    --ghidra /path/to/ghidra_12.1.4_PUBLIC --jdk /path/to/jdk-21
```

脚本依次执行以下阶段，每一步都用固定的 SHA-256 校验结果，任何不一致都会立即停止：

1. **extract**：解开 IPA，确认是受支持的 1.3.2 版本；
2. **resources**：从 IPA 组装出游戏资源文件夹 `Asphalt6Data`；
3. **codegen**：把游戏程序转换成本机 C++ 源码，放在 `generated/`；
4. **compile**：用 CMake 编译 iOS 静态库，翻译出的程序部分约需一小时；
5. **package**：链接、签名，输出安装包。

产物位于 `dist/`：

- `Asphalt6Compat.ipa`：默认为临时签名（ad-hoc），可直接交给 SideStore、AltStore 等工具安装；
- `Asphalt6Data.zip`：游戏资源。

如果要用自己的开发者证书直接签名：

```sh
python3 scripts/buildGame.py Asphalt6.ipa --identity "Apple Development: …" --profile your.mobileprovision
```

此时 bundle ID 取自描述文件；不签名时默认为 `com.ruterfu.asphalt6compat`（可用 `--bundle-id` 修改）。

## 安装

1. 安装 `Asphalt6Compat.ipa`。
2. 解压 `Asphalt6Data.zip`，在“文件”App 中把 `Asphalt6Data` 文件夹放进 **我的 iPhone → （App 名称，取自你的 IPA，通常为 Asphalt 6）**。
3. 打开 App。首次启动会校验资源，之后启动会使用缓存。

## 高清背景包（可选）

把 `NativeArtwork.zip` 放进 App 的文稿目录（与 `Asphalt6Data` 同级）即可。启动时，在“正在启动游戏”阶段兼容层会自动：

1. 解压其中受支持的文件到 `Asphalt6Data/NativeArtwork/`；
2. 逐个校验 SHA-256，只使用校验通过的图片；
3. 标题、菜单、加载等背景改为 16:9 高清版本。

没有这个压缩包、或其中某张图缺失或损坏时，对应画面自动使用游戏原版背景，不影响运行。高清背景包不在本仓库中，需单独获取。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `host/app/` | App 入口、启动流程与资源检查界面 |
| `host/src/` | 兼容层主体：系统接口、图形、音频、输入、界面适配、资源与高清背景包 |
| `host/tests/` | 兼容层的独立测试 |
| `aot/runtime/` | 翻译后程序所依赖的运行时：寄存器布局、内存访问、调度接口 |
| `aot/math/` | 与 ARMv7 浮点逐位一致的软件浮点库（Berkeley SoftFloat） |
| `scripts/buildGame.py` | 一键构建入口 |
| `scripts/as6build/` | 构建各阶段的实现与校验数据 |
| `generated/` | 构建时生成，不提交 |

## 当前状态

| 阶段 | 状态 |
| --- | --- |
| extract | ✅ 已完成并验证 |
| resources | ✅ 已完成：从原版 IPA 生成的 963 个文件与基准逐字节一致 |
| 高清背景包 | ✅ 已完成：解压、校验、缺失回退均已测试 |
| codegen：Ghidra 分析与导出 | ✅ 已验证：全新分析的导出在规范化后与基准完全一致 |
| codegen：转换为 C++ | ⏳ 进行中，脚本目前会在此阶段停止并给出提示 |
| compile / package | ✅ 已实现，待 codegen 完成后整体验证 |

## 许可

- 兼容层代码：见各文件。
- `aot/math/vendor/`：Berkeley SoftFloat，许可见 `aot/math/NOTICE.md`。
- 游戏程序、美术、音频及相关商标归其各自权利人所有，本仓库不包含也不分发这些内容。
