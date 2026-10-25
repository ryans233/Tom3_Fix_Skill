# Tom3 Fix Skill — 蒙提祖玛的宝藏 3 音频泄漏修复：可执行规格与验收

**English: [README.md](README.md)**

本仓库是蒙提祖玛的宝藏 3 音频泄漏修复的**规格 + 验收**仓库，不含补丁本体，也不含游戏的任何代码、二进制、资源或反编译产物。

它让 LLM（或任何实现者）在**只依据行为契约与互操作坐标**的前提下，写出满足契约的 ASI 修复补丁，并用本仓库 `tools\` 的判据验收。

## 这个项目解决什么问题

**用户遇到的问题**：`TreasuresOfMontezuma3.exe` 是 32 位进程，连续游玩约 30 分钟后窗口“未响应”，只能强制结束再重开；重开后同样会复发。原因是音频对象池在复用 `{1 source + 3 buffers}` 时直接覆盖旧 buffer 名字、从不释放，导致每播放一次就泄漏约一整段音频 PCM，内存以约 44 MB/min 增长直至地址空间耗尽，随后分配失败在音频线程中触发模态对话框并与音频 tick 线程死锁（行为级根因见 §2）。

**本仓库负责的环节**：

1. **可执行规格**（`SKILLS.md`）：把“修什么、在哪修、什么时候绝不能修”写成契约——只在池复用覆盖旧名字之前删除上一代 3 个 buffer，其他路径一律透传；坐标不匹配时必须 fail-closed。不依赖反编译文本，实现者不需要游戏源码。
2. **可复现的验收**（`tools\`）：用固定阈值区分“复现”和“修复”——未修复时增长 `≥ 60 MB/min` 或进程耗尽，修复后压平到 `< 15 MB/min`，并用 `freed = 3 × hits`、`gen = 768 + 3 × hits` 证明钩子只命中复用路径。
3. **合规边界**：不修改游戏 exe、不分发游戏文件或反编译产物；只接受独立 `.asi` 插件。

**本仓库不提供**：修复补丁二进制、ASI Loader、游戏本体。两个 `.asi` 由实现者按规格自建；验收只认行为，不认语言、编译器或代码结构。

```
Tom3_Fix_Skill/
  README.md                  英文版：项目简介、验收标准、合规边界
  README_ZH.md               本文件（中文版）
  SKILLS.MD                  LLM 执行手册（英文）：缺陷模型、补丁契约、复现器契约、验收流程
  tools/set-gamepath.ps1     记录游戏安装目录（git-ignored）
  tools/check-submission.ps1 提交合规与产物格式检查（不启动游戏）
  tools/verify-tom3fix.ps1   部署 + 运行时验证（静态项、日志、钩子）
  tools/test-tom3-audio.ps1  端到端泄漏基准（repro / both / fix / none）
  tools/run-acceptance.ps1   一键验收：合规 → 部署验证 → 三个基准场景
```

---

## 1. 目标与验收对象

目标平台：`TreasuresOfMontezuma3.exe`（PE32 i386，ImageBase `0x400000`，无 ASLR，8,504,320 B）。

交付物（实现者自行创建，本仓库不提供）：

| 路径 | 作用 |
|---|---|
| `build\Tom3_Fix.asi` | 修复补丁；IAT 钩住 `OpenAL32.dll!alGenBuffers`，仅在池复用路径释放上一代 3 个 buffer |
| `build\Tom3AudioLeakRepro.asi` | 复现/压测补丁；直接调用引擎自身的“停止→回起点→重播”入口，按固定频率制造泄漏 |
| `src\` + 构建脚本 | 上述两个 DLL 的可复现源码；由实现者自备 MSVC x86 工具链构建 |

本仓库的验收脚本只认**行为**，不认实现语言、编译器或代码结构。两个 `.asi` 都是普通 32 位 DLL（扩展名不同），由上游 Ultimate ASI Loader（`dinput8.dll`，见 §4）在游戏进程内加载。

---

## 2. 为什么需要这个补丁（行为级根因）

游戏在 32 位地址空间内长时间游玩后会“未响应”。现场证据（内存曲线、全内存转储、锁归属）指向音频子系统的对象池：

1. 引擎复用池中的 `{1 source + 3 buffers}` 对象时，只删除并重建 source，随后用 `alGenBuffers(3, …)` **直接覆盖**上一代 3 个 buffer 名字，从未调用 `alDeleteBuffers`。
2. 旧 buffer 连同其 PCM 数据被永久遗弃。首包填充以“整段音频长度”作为 `alBufferData` 大小，所以**每播放一次泄漏约一整段音频**。
3. 这些 PCM 由 `wrap_oal`/DirectSound 以 `VirtualAlloc` 私有区持有，实测增长约 44 MB/min；32 位进程约 30 分钟见底。
4. 见底后新分配失败，`wrap_oal` 的静态 CRT 调 `abort()` 弹出模态框；消息循环重入游戏窗口过程，与音频 tick 线程形成 ABBA 死锁，表现为“未响应”而非崩溃退出。

修复不改变音质、音量或时序：只是在名字被覆盖**之前**，把即将成为孤儿的 buffer 名字释放掉。详细契约见 `SKILLS.md` 。

---

## 3. 验收标准（行为判据）

全部判据由本仓库的 `tools\verify-tom3fix.ps1` 与 `tools\test-tom3-audio.ps1` 实现；比对对象是调用者传入的产物（`-AsiPath` / `-ReproAsiPath`），产物路径可指向任意目录。

### 3.1 部署/运行时验证

| 检查 | 判据 | 级别 |
|---|---|---|
| 游戏 exe | 存在 | FAIL |
| ASI Loader `dinput8.dll` | 存在；应为上游 Ultimate ASI Loader v10.0.0 的 32 位构建 | FAIL |
| `Tom3_Fix.asi` | 存在；部署副本与传入产物 SHA256 一致 | FAIL / WARN |
| `Tom3_Fix.ini` | 缺失或键缺失 = `AudioMemoryLeakFix=1`；显式 `0` 表示停用 | PASS / WARN |
| `HIGHDPIAWARE` 兼容层 | 未设置（只读检查） | WARN |
| 游戏启动 | 40 s 内出现窗口 | FAIL |
| 日志 | 出现 `Tom3_Fix.asi attached`；启用时出现 `fix: alGenBuffers hooked` | FAIL |
| 日志错误 | 无 `fix: ERROR` | FAIL（由钩子检查间接判定） |
| 复现器残留 | 安装目录无 `Tom3AudioLeakRepro.asi` | WARN |
| LARGEADDRESSAWARE | 仅提示，不是修复 | WARN |

退出码：`0` = 无 FAIL；`1` = 至少一个 FAIL。

### 3.2 泄漏基准（阈值硬编码）

| 场景 | 部署 | 判据 | 退出码 |
|---|---|---|---|
| `repro` | 修复补丁（`Fix=0`）+ 复现器 | 进程 OOM/崩溃，或增长 `≥ 60 MB/min` → PASS；`20–60` → WEAK；`< 20` → FAIL | PASS 才 0 |
| `both` | 修复补丁（`Fix=1`）+ 复现器 | 存活且增长 `< 15 MB/min` 且 `fix.hits > 0` → PASS；持平但 `hits=0` → INCONCLUSIVE；仍在增长/崩溃 → FAIL | PASS 才 0 |
| `fix` | 仅修复补丁（空闲） | 存活且增长 `< 15 MB/min` → PASS | PASS 才 0 |
| `none` | 仅修复补丁（`Fix=0`，参考基线） | 只报告增长，不判定 | 1 |

> **噪音警告（预期现象，不要惊慌）**：`repro` 与 `both` 场景会加载 `Tom3AudioLeakRepro.asi`，按固定频率反复触发引擎的“停止 → 回起点 → 重播”入口，因此游戏会发出**噪音**（连续重播/爆音/电流声）。这是复现器的预期行为，不是游戏崩溃、不是补丁失效、也不是音频设备故障；判定只依赖内存增长与日志计数器，噪音不影响任何判据。测试期间请调低系统音量，测完正常关闭游戏即可。

测量方式：启动 → 等窗口 → 预热（默认 26 s，覆盖开场）→ 每 250 ms 采样 `PrivateMemorySize64`、逐秒记账 → 最小二乘拟合 `MB/min` → 读日志尾部计数器 → 关闭游戏并恢复部署（只留 `Tom3_Fix.asi`，删除两个 ini 以便下次自建）。

### 3.3 计数器不变量（诊断用，不改变判定）

`both` / `fix` 运行后，日志尾部应满足：

```
freed == 3 × hits
gen   == 768 + 3 × hits
```

`768` 是池内 256 个 bundle 的初始生成量。这两个等式用于证明钩子**只命中复用路径**；脚本以 `INFO` 输出，不参与 PASS/FAIL。

---

## 4. 快速开始

前置：Windows 10/11 x64、PowerShell 5.1+、已合法安装的游戏、上游 ASI Loader（`dinput8.dll`，见下）、MSVC x86 工具链（实现者构建用）。

**ASI Loader 必须使用上游版本，不要自行编写/“发明”加载器。** 从 [ThirteenAG/Ultimate-ASI-Loader v10.0.0](https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases/tag/v10.0.0) 下载 Win32 资源 `Ultimate-ASI-Loader-NoPDB.zip`（或 `Ultimate-ASI-Loader.zip`），取出其中的 32 位 `dinput8.dll` 放到游戏目录。不要改用其他版本、不要用 x64 构建、不要自写代理 DLL：加载器不是本仓库的交付物，也不要提交进仓库（`check-submission.ps1` 会拦截）。

> `repro` / `both` 场景会让游戏发出噪音，属复现器预期行为，详见 §3.2 的噪音警告。

```powershell
# 1) 记录游戏目录（优先级：-GameDir > TOM3_GAMEDIR > tools\gamepath.txt）
powershell -ExecutionPolicy Bypass -File tools\set-gamepath.ps1 -GameDir "E:\...\The Treasures of Montezuma 3"

# 2) 实现者按 SKILLS.MD 产出 build\Tom3_Fix.asi 与 build\Tom3AudioLeakRepro.asi

# 3) 提交合规 + 产物格式（不启动游戏）
powershell -ExecutionPolicy Bypass -File tools\check-submission.ps1

# 4) 一键验收（部署验证 + repro + both + fix，约 3 分钟）
powershell -ExecutionPolicy Bypass -File tools\run-acceptance.ps1

# 或分项运行
powershell -ExecutionPolicy Bypass -File tools\verify-tom3fix.ps1
powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario repro -DriveHz 30 -MeasureSeconds 10
powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario both  -DriveHz 30 -MeasureSeconds 30
powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario fix   -WarmupSeconds 25 -MeasureSeconds 15
```

可传入自己的产物路径：

```powershell
powershell -File tools\test-tom3-audio.ps1 -Scenario both -AsiPath D:\out\Tom3_Fix.asi -ReproAsiPath D:\out\Tom3AudioLeakRepro.asi
```

---

## 5. 脚本行为与安全边界

* 所有脚本会在**游戏安装目录**写入/删除 `Tom3_Fix.asi`、`Tom3AudioLeakRepro.asi`、对应 ini 与日志，并在结束时恢复为“只留 `Tom3_Fix.asi`、删除 ini”。请先确认目录。
* 脚本会强制结束 `TreasuresOfMontezuma3` 进程；运行前保存游戏进度。
* 脚本不修改游戏 exe，不写入注册表（只读 `HIGHDPIAWARE`），不联网，不收集数据。
* `run-acceptance.ps1` 会先用传入的 `-AsiPath` 覆盖安装目录中的 `Tom3_Fix.asi`；验收结束后保留该文件。
* 不通过上游 Ultimate ASI Loader（`dinput8.dll`）之外的机制注入；不自行实现加载器；不绕过 DRM；不修改/分发游戏本体。

---

## 6. 本地工具清单

| 脚本 | 作用 | 说明 |
|---|---|---|
| `tools\set-gamepath.ps1` | 记录游戏安装目录 | 优先级 `-GameDir` > `%TOM3_GAMEDIR%` > `tools\gamepath.txt`；文件 git-ignored |
| `tools\check-submission.ps1` | 提交合规与 PE 格式检查 | 不启动游戏，不参与行为判定 |
| `tools\verify-tom3fix.ps1` | 部署 + 运行时验证 | 支持 `-AsiPath` / `-ReproAsiPath`；校验部署副本与传入产物的 SHA256 |
| `tools\test-tom3-audio.ps1` | 端到端泄漏基准 | 场景 `repro` / `both` / `fix` / `none`；产物缺失时退出码 `2` |
| `tools\run-acceptance.ps1` | 聚合验收 | 依次执行上述检查与三个基准场景，不新增判据 |

---

## 7. 合法合规边界

本仓库的定位是**互操作性规格**，不是游戏内容的再分发：

* **不包含**游戏 exe、DLL、资源、存档、内存转储、IDA 数据库、反汇编清单或反编译伪代码；仓库内的 `.gitignore` 与 `check-submission.ps1` 会阻断常见误提交。
* **不修改**游戏可执行文件；补丁以独立 DLL 形式由上游 Ultimate ASI Loader v10.0.0（`dinput8.dll`）加载，只调用 `OpenAL32.dll` 的公开导出函数。
* **不绕过**任何 DRM、激活或完整性校验；不提供游戏本体，不提供下载。
* 文中的地址/RVA、字段偏移、vtable 地址是**互操作所必需的功能性事实**，为与未修改的目标二进制协作而提供；它们不是表达性内容，也不包含任何目标程序的指令或代码。
* 验收脚本仅在本机对**用户合法持有的副本**运行，不上传、不收集、不再分发任何游戏数据。
* 游戏名称、商标与全部游戏内容归其权利人所有；本项目与权利方无隶属或背书关系。
* 使用前请自行确认所在司法辖区的法律与游戏 EULA。本仓库不构成法律意见。

实现者必须遵守 `SKILLS.MD` 的 “Legal & evidence boundary”：**不得**把反编译输出、转储内容或游戏文件写入提交物、日志、issue 或验收记录。

---

## 8. 环境要求

| 项 | 要求 |
|---|---|
| OS | Windows 10/11 x64 |
| Shell | PowerShell 5.1+ |
| 游戏 | 合法安装的 The Treasures of Montezuma 3（Steam 等） |
| 加载器 | 上游 Ultimate ASI Loader **v10.0.0** 的 32 位 `dinput8.dll`（从上游 release 获取；不要自行实现） |
| 构建 | Visual Studio 2019/2022 C++ x86（`cl` + `/MT`），产物必须是 i386 DLL |
| 显示 | 能创建窗口的桌面会话（脚本等待游戏窗口） |

---

## 9. 不做的事

* 不修复 `% sampleFrames` 的除零隐患（未复现）。
* 不处理音画不同步的帧时间机制（推断，未实测）。
* 不承诺消灭所有内存增长；修复只覆盖“复用池对象时泄漏 buffer”，残余 1–3 MB/min 属引擎正常波动。
* 不保证跨版本兼容：换 exe 后 `0x197EAF` 命中点可能失效；实现必须 fail-closed（`hits=0`，绝不误删）。

---

## 10. 许可

本仓库的文档、脚本与规格为原创内容，采用 MIT 许可（见 `LICENSE`）。该许可**不覆盖**游戏本体、游戏资源、OpenAL/ASI Loader 等第三方组件；它们的权利与许可归各自权利人。

---

## 11. 脚本自检记录

为避免“脚本只是看起来对”，本仓库的验收链已用参考产物在作者环境完整跑通（同一台机器、同一游戏安装、同一 30 Hz 驱动）：

| 步骤 | 结果 | 关键数据 |
|---|---|---|
| `check-submission.ps1` | PASS | 两个 i386 DLL；无违规文件 |
| `verify-tom3fix.ps1` | PASS | 窗口、`attached`、`hooked`、无 `fix: ERROR` |
| `repro`（10 s） | PASS | 789.5 MB/min，`drives=774` |
| `both`（30 s） | PASS | 1.4 MB/min，`hits=1274`，`freed=3822`，`gen=4590` |
| `fix`（空闲 15 s） | PASS | 1.9 MB/min，`hits=1`，`freed=3`，`gen=771` |
| `run-acceptance.ps1` | PASS | 5/5 步 |

后两项同时满足 `freed = 3 × hits`、`gen = 768 + 3 × hits`。这些数值是本机实测，用于证明脚本能跑通并区分“复现/修复”；不同机器、界面与时长会有差异，判定只看上表的阈值。
