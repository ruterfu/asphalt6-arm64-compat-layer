# Asphalt 6 ARM64 兼容层性能优化调查

日期：2026-10-23（Asia/Taipei）。

仓库：`/Users/fubo/FuboProject/Extract/git-commit/asphalt6-arm64-compat-layer`。

整理时仓库 HEAD：`ce8a34e`（`README：更新实机演示录屏链接`）。本文行号以整理时磁盘上的源文件为准；历史实验各自使用冻结输入，并不都对应这个提交。

> 证据保存位置：原先位于 `build/work/performance-30/` 与 `build/work/performance-investigation/` 的实验代码、trace 与结果，已复制到仓库根目录的 `perf-evidence/`（本地保存，已在 `.gitignore` 中忽略，不随仓库提交），清理 `build/` 不再影响它们。下文链接已指向该目录。

## 1. 结论与范围

**兼容层仍有可研究的优化空间，但目前没有验证出在相同画质、帧率和比赛工作量下，整应用 CPU 工作量降低至少 30% 的方案。**

最值得继续研究的是 ARM→C++ 生成器中的通用开销：临时标志的重复计算、寄存器状态在代码块之间的搬运、临时值的字节数组表示，以及普通内存访问的重复检查。已有部分模块微基准显示局部收益；这些结果不能直接当作手机整场比赛的收益。

本报告遵守本次任务已经明确的边界：

- 用户提供的原版 IPA 逐字节保持不变；提取出的 ARMv7 程序保持不变。
- 可以优化兼容层运行时、系统桥接、数学支持和 ARM→C++ 生成器；生成代码结构可以变化，但必须保持等价行为。
- 保持现有画质、分辨率、帧率目标、更新频率、玩法、物理精度、资源和数值结果。
- 本轮候选保存在隔离实验目录，没有作为本轮成果合入生产实现或安装到手机。

以下“优先级”表示下一轮调查顺序，并不表示已经证明的收益大小。

| 优先级 | 优化点 | 当前状态 | 对 30% 目标的结论 |
| --- | --- | --- | --- |
| A | 延迟计算将被覆盖的临时标志 | 完成全量静态扫描和一个真实代码块的 eager 汇编检查；lazy 仍为未验证草稿 | 有具体机会，收益未知 |
| A | 将无重叠的 `unique` 临时值改为明确类型的局部变量 | 三模块候选已生成，未编译、未差分、未计时 | 收益未知 |
| B | 在 CFG 强连通区域内保留寄存器状态 | 16 模块完成差分和隔离微基准；生产所有权准入尚未接线 | 局部有效，不能据此证明整体 30% |
| B | 单页栈访问缓存、同一指令的批量访问检查 | 完成静态覆盖统计和单页缓存原型准备；未编译、未测试 | 收益未知 |
| C | PGO 编译优化 | 三模块完成微基准和差分 | 局部耗时下降约 4.6%–13.4%，不是实机 CPU 降幅 |
| C | 内存辅助函数、ARC、重复 VM 查询 | 部分有小型实验，部分只有覆盖分析 | 可作补充，尚无足够收益证据 |
| 排除当前实现 | 冷回退代码压缩、强制内联 NEON、仅删除 live-in 拷贝 | 已测得无明显收益、退化或机器码完全相同 | 不作为当前主路线 |

## 2. 原版 IPA 与输入完整性

### 2.1 固定输入

| 输入 | 路径 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| 用户原版 IPA | `/Users/fubo/Downloads/Asphalt_6__Adrenaline_1.3.2_ios_3.1.3.ipa` | 564,685,789 | `30ea95d5ccd3fb9ded3b7b6b0c9e88f6af8de62d8c841ed0a3f79be6d045a796` |
| 提取的 ARMv7 程序 | `build/work/program.armv7` | 7,994,608 | `4a2209881ab5933113a15770b0615807cfa7d73bf50a9326569a7ed20f77df00` |

调查期间已重新计算以上两个文件的哈希，均与固定值一致。原始记录见 [original-input-pins.json](../perf-evidence/performance-30/original-input-pins.json)，复核记录见 [original-input-recheck-20261023.json](../perf-evidence/performance-30/original-input-recheck-20261023.json)。

### 2.2 构建约束对应的代码

| 位置 | 作用 |
| --- | --- |
| [README.md:36](../README.md:36) | 说明离线翻译、arm64 编译及无 JIT 的运行方式 |
| [README.md:38](../README.md:38) | 要求原 ARMv7 寄存器、内存、条件标志和浮点行为一致 |
| [README.md:55](../README.md:55) | 支持版本、输入尺寸与固定哈希 |
| [scripts/buildGame.py:142](../scripts/buildGame.py:142) | `extract()` 只读打开输入 ZIP，解压到工作目录 |
| [scripts/buildGame.py:167](../scripts/buildGame.py:167) | 提取 ARMv7 部分并校验其哈希 |
| [scripts/as6build/codegen.py:205](../scripts/as6build/codegen.py:205) | 验证参考翻译模块与固定清单一致 |
| [scripts/as6build/codegen.py:222](../scripts/as6build/codegen.py:222) | 在参考翻译之上进行寄存器提升，保留原回退实现 |

README 允许程序内容相同的重新打包输入；本次用户要求更严格，按原版 IPA 整体字节不变执行。输入 IPA 与兼容层构建生成的 arm64 安装包是两个不同产物。

优化生成器时，应保留原输入哈希和参考翻译的来源验证，并记录新生成器版本及产物哈希；不应通过放宽输入校验来接受不同游戏程序。

## 3. 实机性能基线与测量限制

### 3.1 已采集的数据

设备为 iPhone 17 Pro。用户进入比赛后，附加 Time Profiler 采集约 30 秒，没有为采集重启游戏。

| 项目 | 已记录值 |
| --- | --- |
| 采集时段 | 2026-10-23 19:18:34–19:19:05，分析前 30 秒 |
| App Bundle ID | `com.fubo.as6.nativegame.QTPX8J5WEA` |
| 被采样可执行文件 UUID | `0F53F6F1-A707-3593-98AE-8FD38CAAF9AF` |
| 全应用所有线程 CPU 样本权重合计 | 26.879 秒 |
| 主线程 CPU 样本权重合计 | 24.979 秒，约占应用 CPU 的 92.93% |
| 生成的 `fn_*` 函数自身时间 | 主线程的 53.881%，约占全应用 CPU 的 50.07% |
| `NativeProgram::execute` 包含子调用 | 主线程约 70.8%；与下方分类有重叠 |
| 热状态 | 记录为 Fair |
| 长挂起记录 | 未记录到超过 250 ms 的挂起；不能据此排除较短掉帧 |

数据文件：

- [原始 trace 目录](../perf-evidence/performance-investigation/race-20261023.trace)。
- [time-profile.xml](../perf-evidence/performance-investigation/time-profile.xml)。
- [hotspots.json](../perf-evidence/performance-investigation/hotspots.json)。
- [summarize_hotspots.py](../perf-evidence/performance-investigation/summarize_hotspots.py)。
- [profile_system.json](../perf-evidence/performance-30/system-study/profile_system.json)。

### 3.2 已知路径的覆盖范围

| 路径 | CPU 样本权重 | 占主线程 | 占全应用 | 含义 |
| --- | ---: | ---: | ---: | --- |
| 浮点辅助函数集合 | 1.817 秒 | 7.27% | 6.76% | 包含有用数学计算，不全是开销 |
| GL 桥接子树 | 1.582 秒 | 6.33% | 5.89% | 不代表所有引擎渲染代码 |
| 内存复制相关集合 | 0.931 秒 | 3.73% | 3.46% | 与其他子树重叠 |
| 原版 UI 适配相关子树 | 0.570 秒 | 2.28% | 2.12% | 包括必要适配工作 |
| 客户端顶点数组 staging | 0.437 秒 | 1.75% | 1.63% | 是 GL 子树的一部分 |
| `DiagnosticLockHeld` 相关 | 0.329 秒 | 1.32% | 1.22% | 不能直接删除锁契约 |
| ARC retain/release 等叶样本 | 1.514 秒 | 约 6.06% | 约 5.63% | 独立叶样本归类；许多引用有生命周期作用 |

**这些分类不能相加为可节省比例。** 内联的页表检查、寄存器读写等也落在生成函数自身时间内，尚不能把那约 50% 全部认定为兼容层冗余。

### 3.3 为什么局部加速不能直接代表 30%

若某优化覆盖全应用 CPU 的比例为 `f`，该区域加速倍数为 `s`，在其他工作不变时：

```text
新总耗时 / 旧总耗时 = (1 - f) + f / s
```

如果只优化生成函数自身这约 50.07% 的应用 CPU 区域，要让总 CPU 工作量下降 30%，该整个区域平均需要减少约 **59.9%** 的耗时，约相当于 **2.49 倍**加速。少量模块达到 30% 或 40% 局部收益，不足以满足这个条件。

按旧样本工作量作说明，`26.879 × 0.70 = 18.8153` 秒；新版本必须在等价工作量下达到相应比值，不能直接拿不同比赛画面的两个 30 秒片段比较。

“吞吐增加 30%”对应耗时约下降 23.1%，也不等于“CPU 工作量下降 30%”。本报告采用后一个更严格目标。

### 3.4 当前测量不能证明的事情

- Time Profiler 的 CPU 样本不包含完整等待时间，也不测 GPU 工作量，不能直接给出实际 FPS、帧间隔 P95/P99 或输入延迟。
- 旧 trace 的 UUID 与后来检查的构建不同，不能把旧样本中的宿主 PC 地址映射到新二进制汇编行。
- [HLE_uikit.m:37](../host/src/HLE_uikit.m:37) 的 `OriginalRenderTiming` 统计完成的 draw 回调耗时；加载回调也会计入，不等于屏幕呈现帧数。
- 主绘制路径在 [HLE_uikit.m:399](../host/src/HLE_uikit.m:399) 先 `GuestLock`，到第 403 行才开始计时；定时器路径在第 594、599 行也有相同顺序。因此现有回调耗时遗漏 VM 锁等待。

## 4. 生成器与运行时的代码导航

```text
原版 IPA（只读）
  → buildGame.py：提取及校验 ARMv7
  → Ghidra 导出：固定 P-code 与补充指令
  → lower.py / lift.py：生成参考 C++
  → promote.py：代码块寄存器提升，保留 exact 回退
  → aot/runtime：寄存器、内存、状态与调度接口
  → host/src/GuestVM.mm：执行租约、系统调用、线程交接
  → Xcode 离线编译链接：arm64 App
```

| 代码位置 | 关键职责 | 优化时需要关注 |
| --- | --- | --- |
| [codegen.py:346](../scripts/as6build/codegen.py:346) | 生成流水线入口 | 固定输入、参考输出和生成器版本 |
| [lower.py:137](../scripts/as6build/lower.py:137) | 划分模块并生成参考 C++ | 模块边界、原始指令字节验证 |
| [lift.py:41](../scripts/as6build/pipeline/lower/lift.py:41) | `verify_temporary_definitions()` | 按原指令微操作 CFG 证明 `unique` 先定义后使用 |
| [promote.py:127](../scripts/as6build/promote.py:127) | `promote()` | 主要优化插入点 |
| [promote.py:169](../scripts/as6build/promote.py:169) | 计算代码块边界 | 分支、hook、模式切换及跨模块入口 |
| [promote.py:202](../scripts/as6build/promote.py:202) | `flush()` 与 `localize()` | 寄存器从局部变量写回 Context 的时机 |
| [promote.py:237](../scripts/as6build/promote.py:237) | 预算与停止点检查 | 整块预扣预算、精确回退和退款 |
| [aot_support.hpp:42](../aot/runtime/aot_support.hpp:42) | `DirectMemory` | 页权限、mutation epoch、独占保留粒度 |
| [aot_support.hpp:107](../aot/runtime/aot_support.hpp:107) | `read_bytes()` / `write_bytes()` | 字节表示和标量化机会 |
| [native_program.hpp:52](../aot/runtime/native_program.hpp:52) | `NativeProgram::execute()` | PC 发布、模块查找、执行返回状态 |
| [GuestVM.mm:1027](../host/src/GuestVM.mm:1027) | `GuestEmulate()` | 每片最多 8192 指令，租约与 host 边界 |

## 5. 优化点 A：临时标志延迟计算

### 5.1 现状与机会

Ghidra ARM 语义除架构 NZCV 外，还维护了以下翻译临时字节：

| 偏移 | 字段 |
| --- | --- |
| `0x64` / 100 | `tmpNG` |
| `0x65` / 101 | `tmpZR` |
| `0x66` / 102 | `tmpCY` |
| `0x67` / 103 | `tmpOV` |
| `0x68` / 104 | `shift_carry` |

字段定义见 [ARM.sinc:11](../build/tools/ghidra_12.1.4_PUBLIC/Ghidra/Processors/ARM/data/languages/ARM.sinc:11)。普通非 S 算术指令也可能产生这些临时值；后续指令可能再次覆盖它们。

可研究的优化是：保存构造最终临时值所需的旧操作数，等到真正需要公开状态时再计算。如果成功路径上的旧值被下一条指令覆盖，就可以省去中间计算。

### 5.2 已完成的证据

完整扫描覆盖 base stream、2 份 RECOVERIES 和 15 份 FRAGMENTS：

- 共 1,658,925 条原始指令，排除 12 条 literal data。
- 441,221 条指令触及候选五字节。
- 对五字节逐字节进行指令内 must-definition 分析，read-before-def 反例为 0。
- unsupported、重复和冲突均为 0；base 解压流哈希与固定预期一致。
- 候选指令内还有 215 个 `setISAMode`，仍需保守处理隐式观察和模式切换。

这证明的是**显式 P-code 中，读取临时值之前有本指令内的定义**，不是证明这些字节可以从所有可观察状态中删除。统计也不是比赛中的动态执行频率。

### 5.3 代码与证据位置

| 文件 | 内容 / 入口 |
| --- | --- |
| [scan_flags.py:31](../perf-evidence/performance-30/system-study/temporary-flags/scan_flags.py:31) | 微操作 CFG 和逐字节支配分析 |
| [scan-results.json:33](../perf-evidence/performance-30/system-study/temporary-flags/scan-results.json:33) | 全扫描计数、哈希、反例和未解决观察边界 |
| [design.md](../perf-evidence/performance-30/system-study/temporary-flags/design.md) | 延迟计算的设计和验证要求；其中“未扫描”是历史状态，以 JSON 为准 |
| [source.json](../perf-evidence/performance-30/system-study/temporary-flags/block-screen/source.json) | 提取真实代码块的来源与哈希 |
| [eager.cpp](../perf-evidence/performance-30/system-study/temporary-flags/block-screen/eager.cpp) | `0x14bc4–0x14c00` 的 16 指令代码块 |
| [eager.s:204](../perf-evidence/performance-30/system-study/temporary-flags/block-screen/eager.s:204) | 第一次 ADD 在正常内存访问前提前计算 carry/overflow/N/Z 并 spill 的汇编 |
| [eager.s:432](../perf-evidence/performance-30/system-study/temporary-flags/block-screen/eager.s:432) | 后续 ADD 再次计算临时标志 |
| [pending_flags.hpp:9](../perf-evidence/performance-30/system-study/temporary-flags/block-screen/pending_flags.hpp:9) | 草稿中的操作数保存和 `materialize()` |
| [lazy.cpp:90](../perf-evidence/performance-30/system-study/temporary-flags/block-screen/lazy.cpp:90) | 开始将临时标志替换成延期计算记录；仅延期 100–103，104 仍照原实现执行 |

**完成状态：只有 eager 版本编译为汇编。lazy 尚未编译、差分或计时。** `owned_for_lazy()` 只有声明，故障测试 fixture 尚未完成，当前不能部署。

### 5.4 等价性约束

[native_state.hpp:79](../aot/runtime/native_state.hpp:79) 重建 CPSR 不读取候选五字节，但 [save():101](../aot/runtime/native_state.hpp:101) 和 [restore():122](../aot/runtime/native_state.hpp:122) 保存、恢复全部寄存器字节。

[CollisionInverseCore.cpp:86](../host/src/CollisionInverseCore.cpp:86) 和 [NativeVertexAdapter.cpp:146](../host/src/NativeVertexAdapter.cpp:146) 也显式重建这些临时字段。

因此必须在 hook、host 调用、snapshot、故障、预算耗尽、停止点和模块返回前还原精确原值。通用回调可能观察 Context；只有经过所有权准入的、不观察 CPU 中间状态的路径，才可延期。不得通过屏蔽五字节的差分比较来宣称等价。

## 6. 优化点 B：`unique` 临时值类型化

### 6.1 现状与候选

部分生成代码把本来只有 1、2、4 或 8 字节的临时值写入 `unique[]`，随后再用 `read_bytes()` 拼回。某些实际汇编仍出现移位、掩码、位域重组和 spill。

候选将单条指令内部无重叠的临时槽改成 `uint8_t / uint16_t / uint32_t / uint64_t / Word` 局部变量，使编译器更直接看到整数宽度和数据依赖。原始寄存器布局和 guest 内存布局保持原行为。

| 位置 | 内容 |
| --- | --- |
| [typed_unique.py:17](../perf-evidence/performance-30/typed_unique.py:17) | 隔离转换入口；检查临时存储没有逃逸到未知访问 |
| [typed_unique.py:51](../perf-evidence/performance-30/typed_unique.py:51) | 线性的先定义后读检查 |
| [typed_unique.py:59](../perf-evidence/performance-30/typed_unique.py:59) | 对微操作跳转和重叠槽保留原路径 |
| [typed_unique.py:78](../perf-evidence/performance-30/typed_unique.py:78) | 生成明确类型变量和读写替换 |
| [typed-unique-candidate-02/generation.json](../perf-evidence/performance-30/typed-unique-candidate-02/generation.json) | 三模块生成统计 |
| [typed-unique-candidate-02/native_00032.cpp](../perf-evidence/performance-30/typed-unique-candidate-02/native_00032.cpp) | 示例候选源码；同目录另有 01500、02481 |
| [cold-exact-study.py:28](../perf-evidence/performance-30/cold-exact-study.py:28) | 通用 screen runner 的 `--candidate-dir` 参数，可加载上述候选；指定此参数时不应用冷代码改写 |

三模块分别转换了 716、688、716 个指令片段；每个模块统计同时包括 exact 和 promoted 两份函数，不能当成两倍原始游戏指令覆盖。

**完成状态：候选已生成，尚未编译、差分或计时。** 当前转换器的线性检查不是通用 CFG 证明；正式实现需要继承 [lift.py:41](../scripts/as6build/pipeline/lower/lift.py:41) 的逐指令定义支配证明，补全别名、截断、任意合法入口和微操作分支验证。LLVM 也可能已经消除部分源级字节拷贝，必须比较最终机器码后判断收益。

## 7. 优化点 C：跨代码块寄存器驻留 / SCC

### 7.1 修改思路和代码位置

生产版 `promote.py` 已在基本块内部使用局部寄存器，块入口复制输入，跨块和退出时写回。SCC 候选将控制流图中互相可达的一组基本块合成区域，在区域内部保留局部状态，减少循环中的重复搬运。

同时实验了模块入口停止点范围检查，以及仅在所有临时 `value` 用途不超过 8 字节时使用 64 位临时值；地址计算继续保留原 128 位检查语义。

| 文件 | 作用 |
| --- | --- |
| [生产 promote.py:188](../scripts/as6build/promote.py:188) | 输入和写回集合 |
| [隔离 promote_region.py:127](../perf-evidence/performance-30/cpu-prototype/promote_region.py:127) | SCC 变换原型 |
| [region64guard/native_01500.cpp](../perf-evidence/performance-30/cpu-prototype/region64guard/native_01500.cpp) | 已测候选示例 |
| [EXCLUSIVE_RESULTS.md](../perf-evidence/performance-30/cpu-prototype/EXCLUSIVE_RESULTS.md) | 排除 CPU 竞争后接受的计时结果 |
| [exclusive-rerun/summary.json](../perf-evidence/performance-30/cpu-prototype/results/exclusive-rerun/summary.json) | 机器可读结果 |
| [EXPANDED_RESULTS.md](../perf-evidence/performance-30/cpu-prototype/EXPANDED_RESULTS.md) | 变换与输入来源；首次非独占计时已被上方结果替代 |

### 7.2 已完成的验证与收益

- 16 模块、163,740 次随机逐入口执行、9,099,219 条原始指令，差分未发现不一致。
- 另有 128,000 个 direct-page 案例，对比全部寄存器、控制字段、完整最终内存和 epoch，未发现不一致。
- 11 份 hook 源码明确拒绝 SCC 变换，保留基线。
- 独占重测中，部分模块几乎没有收益；`native_01500` 局部区间耗时下降约 41.27%，`02356` 约 35.43%，`00271` 约 33.92%，`02481` 约 30.96%。
- 这 16 个被选模块只覆盖旧实机主线程自身样本的 6.782%。按旧权重计算的局部平均改善约 16.07%，对应约 1.01 个全应用 CPU 百分点的示意投影。**该投影与真实比赛工作负载不匹配，不是已测得的实机改善。**

SCC 的关键未完成项是**生产所有权准入**：回调若能读取或修改 CPU 状态，延后写回会改变其观察。旧差分 driver 记录内存访问轨迹，不记录每次回调发生时的全部 Context，因此不能据此证明任意观察型回调的等价性。

应只向真实 Core、自有 AtomicAccess、有效执行租约且寄存器布局正确的路径开放；通用回调、未知 DirectMemory、Context/寄存器别名以及不支持的 hook 都走原基线。不得假设 `&ctx` 和 `ctx.registers` 来自不同分配：它们在真实 NativeState 中属于同一个对象分配内的不同成员。

### 7.3 相邻模块合并

`02412 + 02413` 的隔离合并保留 1019 个合法 PC、literal holes、原查找出口及 legacy 行为。一般路径和强制 resolver override 路径各完成 30,570 次差分，另有 8,000 个 direct-page 案例。

SCC 合并的微基准区间耗时下降约 7.40%；较大的弱连通区域约 3.92%。保留独立基线后会增加代码体积。任何未来合并都必须验证完整 provider override，而不能只检查已知 hook 清单。

证据：[merged-pair/RESULTS.md](../perf-evidence/performance-30/cpu-prototype/merged-pair/RESULTS.md)、[merged-pair-weak/RESULTS.md](../perf-evidence/performance-30/cpu-prototype/merged-pair-weak/RESULTS.md)。

## 8. 优化点 D：普通内存、栈访问与独占监视器

### 8.1 现有生产路径

| 位置 | 职责 |
| --- | --- |
| [aot_support.hpp:153](../aot/runtime/aot_support.hpp:153) | `direct_page()` 验证地址宽度、页权限和同页边界 |
| [aot_support.hpp:163](../aot/runtime/aot_support.hpp:163) | `direct_reserved()` 检查独占保留 granule |
| [aot_support.hpp:177](../aot/runtime/aot_support.hpp:177) | 普通 `load()` 的 direct 路径与 checked 回退 |
| [aot_support.hpp:215](../aot/runtime/aot_support.hpp:215) | `store()` 保留 epoch 饱和检查、reservation 和一次写入一次 epoch |
| [HostDataMemory.hpp:138](../host/src/HostDataMemory.hpp:138) | 独立分配每个 4096 字节 guest 页，维护权限和有效字节 |
| [HostDataMemory.hpp:243](../host/src/HostDataMemory.hpp:243) | checked read |
| [HostDataMemory.hpp:270](../host/src/HostDataMemory.hpp:270) | checked write |
| [HostDataMemory.hpp:299](../host/src/HostDataMemory.hpp:299) | 先验证全体目标，再顺序提交的批量写入 |
| [HostDataMemory.hpp:332](../host/src/HostDataMemory.hpp:332) | 仅能借用同一页的 `read_span()` |
| [GuestNativeCore.hpp:92](../host/src/GuestNativeCore.hpp:92) | Core 提供直接内存视图 |
| [GuestVM.mm:1063](../host/src/GuestVM.mm:1063) | 有界 native 调用中持租约，RAII 发布和清除 DirectMemory，host 交接前结束 |

### 8.2 栈访问的静态覆盖

实际栈映射及生命周期入口如下。`GuestRegisterStack()` 只登记元数据，不能单靠“地址位于登记范围”就跳过映射、权限和有效性检查。

| 生产位置 | 已确认结构 / 对缓存的影响 |
| --- | --- |
| [GuestNativeCore.hpp:315](../host/src/GuestNativeCore.hpp:315) | 主栈范围为 `[0x3f7f0000, 0x3fff0000)`，8 MiB |
| [GuestNativeCore.hpp:322](../host/src/GuestNativeCore.hpp:322) | `ensure_dynamic()` 按页映射，失败时会回滚新页；缓存也必须覆盖失败和回滚协议 |
| [HLE_pthread.m:452](../host/src/HLE_pthread.m:452) | pthread 栈从 `0x30000000` 分配，每个 1 MiB |
| [HLE_audio.m:327](../host/src/HLE_audio.m:327) | audio 栈为 `GuestAlloc(1<<18)` 的 256 KiB，首尾页可能与堆邻居共享 |
| [GuestVM.mm:938](../host/src/GuestVM.mm:938) | `GuestRegisterStack()` 追加范围，`GuestStackContains()` 查询范围 |
| [GuestVM.mm:1495](../host/src/GuestVM.mm:1495) | 嵌套 `GuestCall` 创建 child SP、保存和恢复 CPU；不能把 SP 恒定作为普遍前提 |

扫描 1,644,383 条基础 AOT 指令后：

- 普通 load/store helper 调用点共 892,466 个。
- 明确使用 SP 为地址基址的调用点 405,707 个，占 45.46%。
- 其中多寄存器 push/pop/ldm/stm 等包含 169,232 个调用点，占全部普通 helper 调用点约 18.96%。
- 用旧模块自身样本作混合权重时，SP helper 静态比例约 49.56%。

这些是**静态调用位置比例**，不是动态内存访问频率，也不是可减少的 CPU 比例。统计见 [static-counts.json](../perf-evidence/performance-30/cpu-prototype/stack-study/static-counts.json)，全模块明细见 [all-modules.json](../perf-evidence/performance-30/cpu-prototype/stack-study/all-modules.json)。

### 8.3 单页栈缓存原型

候选不搬动 guest backing；在一次执行租约内，为已验证的完整 RW 栈页发布缓存。命中时复用 host 页指针，失配、跨页、权限不足或地址异常时回原 load/store。

| 原型位置 | 内容 |
| --- | --- |
| [原型 aot_support.hpp:60](../perf-evidence/performance-30/cpu-prototype/stack-study/prototype/runtime/aot_support.hpp:60) | `StackPageWindow` |
| [原型 aot_support.hpp:257](../perf-evidence/performance-30/cpu-prototype/stack-study/prototype/runtime/aot_support.hpp:257) | 发布经过所有权和租约约束的窗口 |
| [原型 aot_support.hpp:272](../perf-evidence/performance-30/cpu-prototype/stack-study/prototype/runtime/aot_support.hpp:272) | `StackWindowScope` 生命周期与撤销 |
| [原型 aot_support.hpp:311](../perf-evidence/performance-30/cpu-prototype/stack-study/prototype/runtime/aot_support.hpp:311) | `load_stack()` / `store_stack()` |
| [screen.cpp](../perf-evidence/performance-30/cpu-prototype/stack-study/prototype/screen.cpp) | 使用真实 HostArmAtomicMemory/AtomicAccess 的测试草稿 |
| [run.py](../perf-evidence/performance-30/cpu-prototype/stack-study/prototype/run.py) | 三模块编译和 screen 入口 |

**完成状态：准备了源码及候选，未启动编译、差分或计时，生产 DirectView 尚未接线。**

hit 路径的安全依赖发布者生命周期协议。map/protect/unmap/initialize、切换 DirectMemory 或观察型 DataAccess、租约结束前必须撤销缓存；不能把这个 helper 独立拿出后视为对任意被手工修改的 Context 都安全。

若单页缓存只能节省一次页表依赖加载而收益很小，更值得研究的是同一 ldm/stm 指令的整段 preflight：仅当全区间同页、权限足够、epoch 余量足够且不触及 reservation 时，才执行固定偏移 fast 路径；其他情况整条指令走原路径，保留原本部分执行后故障的效果。该批量方案尚未实现。

### 8.4 独占监视器：已排除“大量 monitor”假设

真实 Core 只有一个 AtomicAccess/monitor。CPU snapshot 不会新增 monitor；10,000 次 snapshot 保存/恢复的探针仍保持 count=1。因此按大量 monitor 设计 Bloom filter 缺乏生产前提。

不过 inactive monitor 的旧 granule 仍会进入检查表。对它写入会调用 checked 路径并更新 `granule_version`。一个集中写入的合成循环中，该路径局部约慢 4.5 倍，但没有真实比赛的碰撞率数据。

不能直接删除 inactive 条目：snapshot 可观察 `granule_version`，只保持 STREX 成败相同不足以满足完整状态等价。

对应生产代码：

| 位置 | 等价约束 |
| --- | --- |
| [HostArmAtomicMemory.hpp:81](../host/src/HostArmAtomicMemory.hpp:81) | `refresh_reservations()` 依据 width，而不是 active |
| [HostArmAtomicMemory.hpp:135](../host/src/HostArmAtomicMemory.hpp:135) | `mutation()` 对相交 monitor 更新版本，包括 inactive monitor |
| [HostArmAtomicMemory.hpp:198](../host/src/HostArmAtomicMemory.hpp:198) | 特定 owner 的 ExecutionLease；有严格锁顺序和生命周期 |
| [HostArmAtomicMemory.hpp:239](../host/src/HostArmAtomicMemory.hpp:239) | `clrex()` 只清 active，保留 width/granule |
| [HostArmAtomicMemory.hpp:247](../host/src/HostArmAtomicMemory.hpp:247) | map/protect 等结构变更在 owner 锁内执行，并保留 mutation 与错误顺序 |
| [HostAtomicAccess.hpp:34](../host/src/HostAtomicAccess.hpp:34) | 一个 AtomicAccess 构造时建立一个 monitor |

证据和诊断草案：

- [monitor-findings.md](../perf-evidence/performance-30/system-study/runtime-only/monitor-findings.md)。
- [monitor_probe.cpp](../perf-evidence/performance-30/system-study/runtime-only/monitor_probe.cpp)、[monitor_probe.jsonl](../perf-evidence/performance-30/system-study/runtime-only/monitor_probe.jsonl)。
- [diagnostic.patch](../perf-evidence/performance-30/system-study/runtime-only/diagnostic.patch)：未应用、未编译、未安装。其边界采样只能观察 count/activity，不能提供逐 store 的真实碰撞率。

后续微基准需要覆盖 count=0、count=1 不相交和 count=1 相交。既有多个简单 flat-memory bench 使用 count=0，其结果不能代表全部实际写入成本。

## 9. 编译器与 PGO 实验

### 9.1 已完成的三模块 PGO

同一份冻结生成源码、严格浮点选项和 math archive，仅改变编译 profile；训练计时不计入结果。已检查真实 profile 计数、LLVM IR 的 profile 元数据，且最终计时程序不链接 profiling runtime。

生产 AOT 编译选项入口为 [CMakeLists.txt:36](../CMakeLists.txt:36)；PGO 微实验的插桩和 profile-use 选项在 [run_pgo.py:89](../perf-evidence/performance-30/render-study/pgo-micro/run_pgo.py:89) 与 [run_pgo.py:108](../perf-evidence/performance-30/render-study/pgo-micro/run_pgo.py:108)。

| 模块 | 中位吞吐比 | 同工作量 elapsed 耗时下降 | `__TEXT` 变化 |
| --- | ---: | ---: | ---: |
| `native_00032` | 1.047754× | 4.5577% | 295,810 → 279,818 字节，约 −5.4% |
| `native_01500` | 1.091907× | 8.4171% | 268,204 → 311,616 字节，约 +16.2% |
| `native_02481` | 1.155085× | 13.4263% | 233,610 → 255,854 字节，约 +9.5% |

每模块 10,240 次逐入口差分，共 30,720 次未发现不一致；每模块有 12 对微基准计时。

**这里的耗时使用 `steady_clock`，是 Mac 合成工作负载的 elapsed，不是直接测得的手机 CPU 时间。** 训练和测试使用相同 seed/工作负载，存在过拟合；内存布局为 flat-memory，reserved_count=0，A/B 顺序也有局限。PGO 可能使代码膨胀，不能把最佳结果推广到全部模块。

| 位置 | 内容 |
| --- | --- |
| [pgo-micro/README.md](../perf-evidence/performance-30/render-study/pgo-micro/README.md) | 实验设计、运行步骤和解释限制 |
| [run_pgo.py](../perf-evidence/performance-30/render-study/pgo-micro/run_pgo.py) | 输入冻结、训练、profile-use、差分和计时 |
| [inputs-01/inputs.json](../perf-evidence/performance-30/render-study/pgo-micro/inputs-01/inputs.json) | 输入来源与哈希 |
| [results-01/screen-results.json](../perf-evidence/performance-30/render-study/pgo-micro/results-01/screen-results.json) | 精简结果及 `whole_race_goal_proven=false` |
| [results-01/summary.json](../perf-evidence/performance-30/render-study/pgo-micro/results-01/summary.json) | 全部配对数据、profile/产物哈希和差分状态 |
| [results-01/conclusion.md](../perf-evidence/performance-30/render-study/pgo-micro/results-01/conclusion.md) | 已完成实验结论 |

### 9.2 PGO + SCC 组合与实机 PGO

组合实验仅完成输入与源码准备，没有编译或结果。准备中的 harness 同时记录进程 CPU、线程 CPU 和 elapsed，并区分训练 seed 与 held-out seed，覆盖 inactive monitor、观察型回调以及准入失败后的基线回退。

相关目录：[pgo-combo](../perf-evidence/performance-30/render-study/pgo-combo)、[pgo-combo/inputs-01/inputs.json](../perf-evidence/performance-30/render-study/pgo-combo/inputs-01/inputs.json)。**不能把单独 SCC 与 PGO 的百分比相加或相乘，当作组合已测收益。**

准入草稿见 [admission.hpp:11](../perf-evidence/performance-30/render-study/pgo-combo/admission.hpp:11)，拒绝后的回退见 [admission.cpp:5](../perf-evidence/performance-30/render-study/pgo-combo/admission.cpp:5)，逐 callback 完整状态记录见 [observer_driver.cpp:48](../perf-evidence/performance-30/render-study/pgo-combo/inputs-01/observer_driver.cpp:48)。这些仍是单线程实验夹具，没有完成生产 Core 集成。

iOS 训练 overlay 也仅准备了工具，未安装训练版本或采集手机 profile。见 [pgo-study/README.md](../perf-evidence/performance-30/render-study/pgo-study/README.md)。训练版含插桩开销，不能作为性能 A/B 的正常基线。

### 9.3 普通优化级别

严格 FP 的 `-O3` 对三个模块的结果约在轻微退化到少量改善之间；没有大幅突破。`-Os` 在这组生成函数上出现约 10–13 倍的局部耗时退化，代码也变大。该结论只针对当前工具链和这些生成模块，不能泛化为所有 C++ 程序。

来源：[compiler-study.py](../perf-evidence/performance-30/compiler-study.py)、[compiler-study/results.json](../perf-evidence/performance-30/compiler-study/results.json)。

## 10. 浮点、渲染及其他运行时函数

### 10.1 浮点辅助函数

主要位置：

- [arm_float.c:83](../aot/math/arm_float.c:83)：正常值准入。
- [arm_float.c:111](../aot/math/arm_float.c:111)：`fast_lane()`，硬件计算和精确异常重建。
- [arm_float.c:182](../aot/math/arm_float.c:182)：`fast_neon()`，保留两条 lane 和 FPSCR。
- [arm_float.c:208](../aot/math/arm_float.c:208)：标量 `fast_binary()`。

强制内联 NEON wrapper 完成 2,226,190 次 helper 比较和 30,620 次模块差分，未发现不一致。但稳定重测只有一个工作负载小幅改善，其他退化，且代码膨胀；不建议整体采用。详见 [inline-fp/README.md](../perf-evidence/performance-30/system-study/inline-fp/README.md)。

“把每次 helper 的 FPCR/FPSR 切换提升到整个 slice”这一前提不成立：被检查的 `arm_float.c` 快照汇编中没有这些控制寄存器读写。现有内核中的 FP scope 是另一层语义，不能混为每次 helper 的重复成本。见 [fp-scope/study.md](../perf-evidence/performance-30/render-study/fp-scope/study.md)。

### 10.2 渲染目标、GL batching 与借用内存

相关位置：

| 文件 | 作用 |
| --- | --- |
| [GameplayBacking25x.hpp:100](../host/src/GameplayBacking25x.hpp:100) | 已有 backing 尺度 |
| [PostEffectsTargetSize.hpp:15](../host/src/PostEffectsTargetSize.hpp:15) | 4096 方形离屏分配大小 |
| [NativeGamePolicy.cpp:200](../host/src/NativeGamePolicy.cpp:200) | 已有 post-effects ratio 策略 |
| [GLReal.m:1281](../host/src/GLReal.m:1281) | `StageClientArrays()` |
| [GLReal.m:1821](../host/src/GLReal.m:1821) | 已 marshalled 的 GL 调用入口 |

普通比赛视口约为 2400×1600（或方向转置），位于 4096×4096 分配的有效子矩形内。不能把整个分配面积当作每帧实际场景片段数。改成 2048 方形无法容纳 2400 宽的现有视口，会有裁切和 UV 风险；降低分辨率也不符合本次目标。

相同状态的四边形 draw batching、uniform gather 或 staging 减少可能有小收益，但没有实际 eligibility/命中率和 CPU 计数。guest 页当前独立分配，`read_span()` 仅同页；GL host 调用还会释放 VM 锁，直接长期借用可写 guest 指针存在生命周期和并发语义问题。

证据：[render-study/conclusion.md](../perf-evidence/performance-30/render-study/conclusion.md)、[compat-batching-borrowing.md](../perf-evidence/performance-30/render-study/compat-batching-borrowing.md)。这些是后续补充调查项，当前不应作为独立 30% 路线。

### 10.3 其他具体函数

| 优化点 | 生产代码位置 | 可研究内容与限制 |
| --- | --- | --- |
| VM 状态重复查询 | [GuestVM.mm:800](../host/src/GuestVM.mm:800)、[GuestVM.mm:836](../host/src/GuestVM.mm:836)、[GuestVM.mm:851](../host/src/GuestVM.mm:851) | `GuestReg/GuestArg/GuestReturn` 可在持锁条件下减少重复查找，必须保留锁和状态有效性检查 |
| C 字节写入探测 | [HLE_libc.m:845](../host/src/HLE_libc.m:845) | `GuestByteWrite` 写前读取目标以保留非法目标故障行为；不能直接删除预验证 |
| Guest 内存复制 | [HLE_libc.m:932](../host/src/HLE_libc.m:932) | `CopyGuest` 的 staging 和重复范围验证；必须保持重叠复制方向和故障行为 |
| 无任务 POSIX 轮询 | [HLE_posix.m:174](../host/src/HLE_posix.m:174) | 研究仅在 ready 慢路径获取强引用，保留 callback 和锁持有期间的生命周期 |
| 执行帧对象所有权 | [GuestVM.mm:408](../host/src/GuestVM.mm:408) | `HostExecutionFrame` 有意保留 VM 并延迟 Core 销毁，不应全局移除强引用 |

ARC 叶样本共约 1.514 秒，但大部分不应简单删除。`HLEPosixPoll` 邻近的 ARC 叶样本约 155 ms，只约占应用 CPU 的 0.58%，即使改善也只是补充。详见 [arc-findings.md](../perf-evidence/performance-30/system-study/arc-findings.md)、[arc-callers.json](../perf-evidence/performance-30/system-study/arc-callers.json)。

同页内存 bulk/copy 已有 50,000 次语义对比通过，但不同长度有改善也有退化，不能直接全面替换。来源：[memory_probe.cpp](../perf-evidence/performance-investigation/more-functions/memory_probe.cpp)、[memory_probe_results.txt](../perf-evidence/performance-investigation/more-functions/memory_probe_results.txt)。

## 11. 已排除或暂缓的方案

| 方案 | 已有结果 | 当前决策 / 证据 |
| --- | --- | --- |
| 仅删除被证明无用的块入口 copy-in | 3 模块、30,720 次差分通过，8 个分析用例；最终 `__text` 与基线逐字节相同 | LLVM 已消除这些拷贝，不计性能收益；[liveness/README.md](../perf-evidence/performance-30/system-study/liveness/README.md) |
| 每组缓存 `ctx.registers` 指针 | 30,720 次差分和 300,000 次别名检查通过；局部吞吐变化约 −0.7% 至 +4.5%，代码增大 | 收益小且不一致；[base-cache/README.md](../perf-evidence/performance-30/system-study/base-cache/README.md) |
| byte helper 改 memcpy、页返回形式、epoch 缓存、noalias certificate | 多种 variant 有完整直接访问和模块差分；收益通常仅数个百分点且有退化 | 保留为辅助实验，不当作主要突破；[runtime-only/RESULTS.md](../perf-evidence/performance-30/cpu-prototype/runtime-only/RESULTS.md) |
| 冷 exact 函数加 cold/noinline/minsize 并独立 section | 3 模块共 30,720 次差分通过；进程 CPU 比值为 1.025952、1.027696、0.999878 | 两模块慢约 2.6%–2.8%，另一接近不变；[cold-exact-results-01/conclusion.md](../perf-evidence/performance-30/cold-exact-results-01/conclusion.md) |
| 在上述冷代码实验中强制内联 byte helpers | 10,240 次差分通过；进程 CPU 比值 1.013921，目标模块段合计 304,002 → 507,932 字节 | 仍慢约 1.4% 且膨胀，停止扩展；[cold-exact-inline-results-01/conclusion.md](../perf-evidence/performance-30/cold-exact-inline-results-01/conclusion.md) |
| 大量 monitor 的 Bloom filter | 生产 Core 只有一个 monitor | 前提不成立 |
| 每 helper FPCR 切换提升到 slice | 被检查的数学 helper 中没有该重复切换 | 前提不成立 |
| 缩小渲染分辨率、跳帧、减少物理更新 | 不符合本次画质和行为边界 | 不作为候选 |

冷代码实验使用 `getrusage(RUSAGE_SELF)` 的 user+system CPU，和旧 PGO 的 elapsed 指标不同。代码体积减少、静态表达式减少和性能改善是不同结论，不能互相替代。

## 12. 等价性要求与验证缺口

正式实现必须保留以下观察结果，现有差分断言不能弱化：

1. 全部 1024 字节寄存器、架构 NZCV/Q/GE/T、FPSCR、S/D/Q 别名和截断规则。
2. 正常、故障、停止点、预算耗尽、任意合法入口以及 ARM/Thumb 切换后的状态、PC 和 budget。
3. 完整内存结果、必要的访问顺序、部分执行后故障的效果及单条访存写回回滚。
4. 每次成功写入的 mutation epoch、独占 monitor 的 active、granule 和 version。
5. hook/provider override、host callback、scheduler snapshot 和观察型 DataAccess 所能看到的中间状态。
6. IEEE 舍入、NaN/denormal、正负零、异常累积和独立乘加的数值行为；保留严格 FP 编译约束。

参考：[tools/promote_equivalence/driver.cpp:89](../tools/promote_equivalence/driver.cpp:89) 的完整 Outcome 对比。既有随机差分只对其覆盖的输入和观察契约提供证据，不是任意 Context 或所有运行路径的完整形式证明。

目前最需要补齐的是：

- 临时标志 lazy 原型缺少所有权准入实现、完整故障 fixture、差分和性能数据。
- typed-unique 候选缺少编译、CFG/别名验证、逐入口差分和机器码比较。
- SCC 缺少生产 owned-Core 准入以及逐 callback 的完整 Context 观察测试。
- 栈缓存缺少实际编译、失效协议验证和真实 monitor 场景计时。
- 所有候选均缺少匹配 UUID、相同比赛工作负载的整应用实机 A/B。

## 13. 实机 A/B 验收流程

### 13.1 已准备工具

| 文件 | 作用 | 完成状态 |
| --- | --- | --- |
| [ab-plan/README.md](../perf-evidence/performance-30/render-study/ab-plan/README.md) | 完整流程、输入格式和验收限制 | 文本准备 |
| [freeze_baseline.py:28](../perf-evidence/performance-30/render-study/ab-plan/freeze_baseline.py:28) | 记录 App、静态库、源码、工具链、UUID 和哈希；默认只输出计划 | 语法/帮助检查，未执行正式冻结 |
| [build_variant.py:33](../perf-evidence/performance-30/render-study/ab-plan/build_variant.py:33) | 从冻结输入构建相同模块列表的 A/B 变体 | 语法/帮助检查，未构建变体 |
| [analyze_ab.py:12](../perf-evidence/performance-30/render-study/ab-plan/analyze_ab.py:12) | 核对来源、UUID、工作量，计算 CPU/frame 配对比和 bootstrap 上界 | 尚无真实配对数据可验收 |

### 13.2 推荐的操作次序

1. 先停止其他编辑/构建者写入同一输出，冻结一个有完整哈希的基线。仓库在调查期间存在其他并行修改，不能用任意时刻的源码加旧二进制拼成基线。
2. 对一个明确候选完成上述等价检查，再构建 A/B。除目标变换外，其他 host/math 库、资源、编译器和模块范围相同。
3. 使用同一手机、同一赛道、车辆、模式、对手、存档/起始状态和输入片段；固定画质、视口、更新节奏及帧率目标。涉及恢复存档时先保存原数据。
4. 记录实际安装二进制的 UUID、资源和输入身份。训练版不参加正常性能比较。
5. 采用至少 5 对匹配实验，交替顺序并控制热状态；记录所有应用线程 CPU、实际呈现帧、模拟更新数、帧间隔和长帧。
6. 主指标为 `全应用 CPU 秒数 / 实际呈现帧数`，并检查相同 FPS、更新/帧、画质和状态结果。draw callback 数、draw call 数及循环数不能替代实际呈现帧。
7. 只有配对结果满足 B/A ≤ 0.70，且误差范围、长帧和等价要求也满足时，才可声称达到 30%。现有分析器采用配对 bootstrap 单侧 95% 上界 ≤ 0.70 的保守标准。

示例只查看冻结计划，不修改现有构建：

```sh
AS6_REPO='/Users/fubo/FuboProject/Extract/git-commit/asphalt6-arm64-compat-layer'
AS6_AB_TOOLS="$AS6_REPO/perf-evidence/performance-30/render-study/ab-plan"
python3 "$AS6_AB_TOOLS/freeze_baseline.py" \
  --repo "$AS6_REPO" \
  --out "$AS6_REPO/perf-evidence/performance-30/baseline-freeze-next"
```

真正冻结需要在所有写入者停止后另加 `--execute --quiescent`，并使用新的输出目录。这里的 quiescent 是测量来源一致性要求；不表示当前已有可验收的优化安装包。

## 14. 文件位置索引与实施顺序

### 14.1 目录索引

| 目录 / 文件 | 用途 |
| --- | --- |
| `scripts/as6build/` | 生产生成器和构建流水线 |
| `aot/runtime/` | 生产 AOT 执行、状态和内存辅助接口 |
| `aot/math/` | 严格浮点及 SoftFloat 支持 |
| `host/src/` | iOS 桥接、真实内存、GL、调度和原生适配 |
| `tools/promote_equivalence/` | 既有生成器差分与微基准工具 |
| `perf-evidence/performance-investigation/` | 旧实机 trace、导出 XML 和热点分析 |
| `perf-evidence/performance-30/cpu-prototype/` | SCC、模块合并、runtime-only、栈实验 |
| `perf-evidence/performance-30/system-study/` | 全局覆盖、临时标志、ARC、monitor、浮点与 liveness 证据 |
| `perf-evidence/performance-30/render-study/` | 渲染调查、PGO、组合准备和 A/B 工具 |
| `perf-evidence/performance-30/typed_unique.py` | 尚未验证的临时值类型化转换 |
| `perf-evidence/performance-30/cold-exact-study.py` | 已运行的冷代码 screen，以及可加载其他候选的微基准 runner |

实验路径已从构建工作目录复制到 `perf-evidence/`，清理 `build/` 不会再移除这些证据（`perf-evidence/` 只在本地，不随仓库提交）。正式采用某方案前，应把必要的生成器改动和有意义的测试迁入可维护的源码目录，并保留输入、工具链与结果清单。

部分历史笔记还写有调查中途的“禁止修改生成器”限制，或扫描执行前的状态。本报告按用户后来明确允许“兼容层生成器可等价优化”的最新范围整理；已完成状态优先参考结果 JSON、独占重测记录和本文逐项核对的说明。

### 14.2 建议的下一轮实施顺序

1. **先完成一个临时标志真实代码块。** 实现所有权准入，补齐每个内存故障点的完整状态差分，检查机器码是否真正去掉中间计算，再测真实 CPU 时间。
2. **对 typed-unique 做最小编译 screen。** 若机器码与基线相同或无稳定收益，及时停止；若有收益，再扩大到 CFG 和别名覆盖。
3. **为 SCC 加上生产所需的准入与观察测试。** 保留基线回退，选择实际热点和代表性模块；不将局部最佳值外推。
4. **测单页栈缓存。** 使用真实页存储和 monitor；若收益小，再决定是否值得开发同一指令的批量 preflight。
5. **只组合已经分别验证的候选。** 对组合重新差分、重新训练、重新计时，使用 held-out 输入；不累加独立百分比。
6. **最后进行匹配工作负载的实机 A/B。** 在此之前，结论保持为“发现具体优化机会，尚未证明整应用降低 30% CPU”。

本文是已有代码和实验的详细调查记录，不是已部署优化版本的发布说明。当前最有价值的产出是明确的优化入口、可复用的验证材料，以及已排除方案的负结果。
