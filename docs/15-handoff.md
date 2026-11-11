# 模型切换交接：AX201 / Windows 用户态 AWDL

## 0. 立即执行的用户要求与暂停状态

用户最新要求：**立即暂停现有任务，整理成果，准备换模型。**

- 已暂停自动目标 `goal-06211121-cdb4-4002-a687-4573e50314a9`，revision 2，phase=paused，不得自动继续逆向。
- 检查时只有 lead（gpt-6.1-sol）在执行交接；没有运行中的子智能体，没有持久终端，没有运行中的后台任务。
- 两次最新 Ghidra 导出均已完成且收集结果，退出码 0。未因本次暂停杀死运行中的分析；暂停请求到达时它们已经结束。
- 两项仓库任务已登记为未分配 pending：task-1（radio 后端）、task-2（AWDL 上层复用）。**没有创建对应智能体，没有定时启动任务。**
- 用户要求这些仓库任务使用 DeepSeek Flash，计划北京时间 12:00 进入谷期后自己手动启动。时间到了也不得自行启动。
- 此次模型发现只返回 `openai-codex/gpt-6.1-sol`；没有可选 DeepSeek Flash。不得把任务标题里的模型要求当成已绑定路由，不得偷偷用 GPT 替代。用户切换模型或配置路由后，仍应核对真实 provider/model ID。
- 用户明确要求恢复时才能恢复主会话目标；恢复要调用 update_goal action=resume。不要仅因为读取交接文件而继续分析。

## 1. 目标与授权边界

目标：在本机 Intel AX201 / Windows 上实现用户态 AWDL，最终与 iPhone AirDrop 互通；考察 DropBridge 的可复用性。

当前授权仅有：离线静态逆向；允许少量只读 Ghidra 分析辅助脚本。没有授权修改/加载驱动、打开硬件或 IHV 会话、发 OID、无线发射测试、关闭 Secure Boot/HVCI、测试签名等。不要写专用固件解包器或其他自制硬件工具。不得重启旧子智能体或立即启动新子智能体。

本轮没有安装或下载任何新工具，也没有修改驱动或无线配置。

## 2. 入口与已有交付

会话工作区：`C:\Users\诚挚的村民\Desktop\DSH\IT`。

会话产物根目录为本交接文件的上两级；所有新产物继续留在本 analysis 目录。

- [前一阶段完整定向报告](./TARGETED-REVERSE.md)：注册、IHV 封套/分派、Action Frame 帧头/状态管理、会话验证、边界与官方文档。
- [前一阶段证据清单](./TARGETED-EVIDENCE-MANIFEST.json)：7 次导出，172 条记录，去重驱动 86 + DLL 49；这是上一阶段的清单，不包含下面新增两轮，不要直接覆盖。
- [第一轮静态基线](./STATIC-ANALYSIS.md)。
- [初始总报告](../REPORT.md)。
- [只读 Ghidra 辅助脚本](./scripts/Ax201ReadOnlyExport.java)：本轮未修改。
- [新增能力分析清单](./CAPABILITY-EVIDENCE-MANIFEST.json)：若本轮整理成功生成，记录最新两次证据及全阶段数量；该文件是整理统计，不代表新增人工分析。

## 3. 本轮新增且已完成的导出

1. [capability-r1 配置](./config/capability-r1.json) 与 [evidence.json](./capability-r1/evidence.json)：11 个函数，全部 decompileCompleted=true。
2. [capability-r2 配置](./config/capability-r2.json) 与 [evidence.json](./capability-r2/evidence.json)：13 个函数，全部 decompileCompleted=true。
3. [第一轮控制台日志](./capability-r1-run.log) 与 [第二轮控制台日志](./capability-r2-run.log)。

最新后台 job：`pwsh-1e9b4b5afac84533`、`pwsh-4f8f2561ad5f4688`，均 completed/exit0 且已用 job_output 收集。中文路径仍有原先 Ghidra 日志配置告警，但两轮输出已存在并检查；不是只凭退出码宣称成功。

导出的 C 是伪代码，不是原始源码；尤其 CFG 的间接调用会丢失真实目标和参数。汇编导出每函数有 1200 条上限，大函数不能默认整份汇编完整。

## 4. 本轮已经读到的新发现及不能外推的点

### 4.1 `0x140142a80` 是路径选择/状态分派，不是已发现的类别过滤器

[函数](./capability-r1/140142a80.c#L11-L60) 调用先前已分析的 ApiDecider，记录分支值，再按 1 进入 DAF、按 3/4/5 进入 DP，失败时清理。

因此上一阶段“下一步追这个地址检查类别/OUI”的计划已经执行了一步，结果是：**它本身没有给出 AWDL 类别/OUI 接受条件。** 不要误报为已通过或已拒绝 AWDL。

### 4.2 普通 TX 数据路径的内部表示确实可以是 802.11 头，不是“只有 Ethernet 字节”

[0x140049690，第 265–299 行](./capability-r1/140049690.c#L265-L299) 调用 `0x140171560` 处理头部，然后按 Frame Control 类型与端口上下文调整数据帧字段。

[0x140171560](./capability-r2/140171560.c#L12-L91) 从输入描述复制头部，检查 ToDS/FromDS 对应位、提取地址，并可修改其他位。

**积极意义**：驱动数据路径内部确有 802.11 原生帧头处理，不应武断地按“只接受 Ethernet”排除方案。

**仍不成立的结论**：这不是公共 raw injection API；WDI/NDIS、端口/peer、队列、加密和下层固件仍可能限制实际发送，不能据此声称 AWDL Data Frame 可任意发送。

[0x14003a790](./capability-r1/14003a790.c) 取得待发包并初始化每包元数据，随后进入 [0x1400f6110](./capability-r1/1400f6110.c#L42-L87)。后者需要适当 miniport 状态，失败路径会回传包状态而非直接发射。

大函数 [0x140049690](./capability-r1/140049690.c) 总长 1346 行，仅人工读取了前 459 行（其中大页返回有截断）；不要说已经完整理解全部函数。

### 4.3 管理帧 dispatcher 显式处理类别 `0x7f`，但本函数该分支没有可确认的上报操作

[prvHmfmHandleActionFrame，0x1402d70f0](./capability-r2/1402d70f0.c#L63-L79) 的 switch 把 `0x7f` 与若干类别分到 break，随后 [第 335–336 行](./capability-r2/1402d70f0.c#L329-L339) 返回初始为 0 的状态，没有像其他类别那样在这里发起具体协议处理。

这只说明该函数内的局部行为。**返回成功不等于转交用户态，也不等于驱动全局丢弃该帧。** 上游/旁路观察者是否另行通知尚待追踪。

当前直接调用者来自证据：`0x1402d0ad0`，调用点 `0x1402d280c`。尚未导出或人工审阅这个上层函数。

HT 检查 [0x1401f30f0](./capability-r1/1401f30f0.c) 处理类别 7；不能把特定 HT/TGh 协议处理器的限制外推成所有 Action Frame 的总白名单。

### 4.4 通用 Action Frame received observer 存在，但跨到用户应用的路径未闭合

[0x140035660](./capability-r2/140035660.c#L75-L99) 取 Action Frame 内容与信道相关参数、生成 `0x40050067` 对应 WDI indication，再调用通知辅助。

其入口引用主要来自静态函数指针表，不是普通直接调用：`0x1403e7f38`、`0x1403e7da8`、`0x1403f03f8` 等（其余引用也有 RTTI/元数据，需区分）。

**尚未确认**：类别 0x7f 是否能到达它、硬件前置过滤是否放行、Windows 如何把该 indication 交给合法用户态客户端。不要把这里直接视作 libpcap 或 DropBridge RX。

### 4.5 RX 路由、解密与去重检查均存在；某些旁路不能误叫 monitor mode

[rxPacketProcessValidMpduFrameApi，0x1400456e0](./capability-r1/1400456e0.c) 会按接收上下文、帧类型、状态分支路由。

- 一个受上下文条件控制的分支把 Data / Action Frame 排队给 [0x14007b780](./capability-r2/14007b780.c)。其 helper [0x1400083f0](./capability-r2/1400083f0.c) 只是读首个 DWORD；[0x14007b600](./capability-r2/14007b600.c) 只是读偏移 +4 的 bit0。**这些尚未命名的字段不能称为 monitor 开关。**
- [0x1400455b0](./capability-r2/1400455b0.c) 调用安全校验后决定是否继续或释放包。
- [0x140044eb0](./capability-r2/140044eb0.c#L60-L71) 体现按序列号/重试位等做重复帧判断。
- [0x14005f020](./capability-r2/14005f020.c#L15-L33) 按数据帧、上下文/状态和安全标志设置失败输出。
- [0x14005dd70](./capability-r1/14005dd70.c) 有明文/解密状态相关分支，不应简化成“未加密数据一定拒收”；也不能据此说 AWDL 明文一定可接收。

向 OS 接收队列的候选出口为 [0x14000aab0](./capability-r1/14000aab0.c)，直接调用者包含 `0x1400448b0` 与 [0x140044bb0](./capability-r1/140044bb0.c)。`0x1400448b0` 尚未导出；`0x14000aab0` 的长页返回有截断，尚未人工完整复核 364 行。

## 5. 用户允许恢复后，最有价值的下一步（现在不要执行）

1. 从 `0x1402d0ad0` 的调用前后追 Action Frame 的观察者/通知先后顺序，确认 0x7f 的其他路径，而不是只看局部返回 0。
2. 恢复 `0x140035660` 所在观察者对象与订阅入口，查合法调用可达性。
3. 追 `0x1400448b0`、`0x140045250` 和接收出口 callback，闭合 Data Frame 到 WDI/用户态的边界。
4. 完整复核 TX 大函数对头部、peer、加密、QoS 与地址的重写，区分本来支持与需要改动部分。
5. 在以上证据充分以前不做驱动替换或发射测试。

## 6. 必要本机事实与复用方式

- 网卡 Intel Wi-Fi 6 AX201 160MHz，CNVio2，不是 RTL8821CU USB；不能套 WinUSB/libusb 或仅改 INF。
- SYS 样本 SHA256：`87C083010DAD3FB6AC8CAC99DDB5E274DF300DA789CC8774B4A25DA137DA38B8`。
- IHV DLL 样本 SHA256：`60B7F7BC371E711FDA6BD957A252F779B4D326F9637BFD4751D27D88826B9ACF`。
- [SYS 项目](./ghidra-project/AX201-static-r2.gpr) 与 [DLL 项目](./ghidra-project/AX201-ihv.gpr) 必须保留各自同名 .rep 目录。不要重新导入/重新全分析。
- 工具 Ghidra：`C:\Users\诚挚的村民\Desktop\small_toolkit\ghidra_12.2_PUBLIC_20261016\ghidra_12.2_PUBLIC`；Java：`C:\Program Files\Microsoft\jdk-25.0.3.9-hotspot`。不要重复下载。
- headless 固定使用真实绝对路径设置 settings/cache/temp，参数 `-process Netwtw14.sys -noanalysis -readOnly -scriptPath <analysis/scripts> -postScript Ax201ReadOnlyExport.java <config.json>`；不要再试 SUBST 路径，之前引发过 Felix 数据目录错误。
- DropBridge 源码在 `C:\Github\DropBridge\repo`，是官方 ZIP 快照，不是 Git 工作树；上游依赖没有恢复，未构建/未做本机无线验证。

**交接终点：暂停。只保存已经得到的结果，不启动新分析、不启动任何智能体。**
