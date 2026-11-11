# AX201 第一轮离线静态分析

> 后续进展：用户允许只读 Ghidra 辅助脚本后，已继续导出并核对关键函数伪代码、虚表及 IHV 会话逻辑，见定向逆向报告。本文件保留为第一轮历史基线。

2026-11-11。仅使用用户提供的成熟工具及 Ghidra 原装导出脚本；未编写专用解包器、二进制解析器或 Ghidra 分析脚本。没有修改、加载或调试系统驱动，没有执行目标 SYS/DLL，没有发射测试帧，也未重启子智能体。

## 1. 工具与文件整理

工具保持在用户原有 small_toolkit 三个目录中，未移动、重新解压或复制。实际 Ghidra 根在用户提供目录下面多一层 `ghidra_12.2_PUBLIC`。版本：DIE 4.0.0、Strings 2.54、Ghidra 12.2 PUBLIC。

工具哈希/签名记录：Strings 的 Microsoft 签名 Valid，DIE 的 diec.exe 没有数字签名；未将无签名直接判定为异常。没有拿到用户原包的可用哈希记录，未声称发行包已与官网校验和比对。

Ghidra 的应用属性要求 Java 25；本机已有 Microsoft OpenJDK 25.0.3+9，直接复用。全局 JAVA_HOME 仍指旧 JDK8，本次只在子进程设置现代 JDK，不改全局环境变量或 PATH。

项目、导出、DIE/Strings 输出、工具配置、Ghidra 缓存与临时文件均集中在本文所在 analysis 目录。Strings 使用了 -accepteula，可能留下当前用户的 Sysinternals 许可证接受记录；不是完全零系统状态写入。

## 2. 已生成的可复用成果

- 内核驱动 Ghidra 项目：需保留相邻同名 .rep 目录，不能只复制 .gpr。
- IHV DLL Ghidra 项目：同样需保留同名 .rep。
- 驱动函数指标清单：9,267,053 B。
- 驱动静态调用图 DOT：1,507,264 B。
- IHV DLL 函数指标清单：4,438,104 B。
- 导出文件哈希。
- 驱动候选函数摘录、驱动字符串线索摘录、IHV 字符串线索摘录。

使用的是 Ghidra 随包 ExportFunctionInfoScript.java，参数通过 .properties 配置传入；没有修改该脚本。自动分析限定 2 个 CPU、单文件 240 秒预算、3 GiB 堆。此处“项目可用、导出成功”不等于所有分析器的每项结果都已人工核验。

函数统计：

| 样本 | Ghidra total_functions | exported_functions |
| --- | ---: | ---: |
| 内核驱动 | 13,518 | 13,348 |
| IHV DLL | 5,851 | 5,606 |

总数与导出数量是工具不同统计口径，不是恢复正确率。自动命名中有 FID_conflict，也保留大量 FUN_ 地址名；FID/RTTI 恢复的名字不是经过逐函数确认的原始源码符号。

## 3. 确认到什么程度

### 3.1 二进制可直接开展常规分析

DIE 驱动检测 将 SYS 识别为 PE64，MSVC C++ 19.44、Linker 14.44，并识别 CodeView/POGO 等调试记录类型；IHV 检测 同样为 PE64。工具的编译器版本是指纹识别结果，不作为原始构建日志。

DIE 驱动熵检查 对主体节报告 not packed。高熵 overlay 不能自动等同加壳：驱动原始文件的证书表位于文件偏移 0x55DE00，长度 19,536 B，正是其尾部区域，见 [前置 PE 清单](../driver-pe-listing.txt)。没有因为熵标签而对签名区域尝试“脱壳”。

### 3.2 WDI / OID 控制面已形成可追踪入口

驱动 Strings 第 26443–26453 行 出现 NdisMRegisterWdiMiniportDriver、OID 完成与状态上报相关导入名。

调用图第 12607 行 为 NdisMRegisterWdiMiniportDriver 外部节点；第 48668 行 给出从 FUN_14000d320 到该节点的静态调用边。由此可以把 `0x14000d320` 列为注册初始化的后续核查候选，而不是只从字符串猜测。

其他可定位地址如下，均是本次导入映像的静态地址，不是当前机器内核加载地址：

| 地址 | 工具给出的名称/事实 | 边界 |
| --- | --- | --- |
| 0x140043c80 | entry，13 条指令、2 个静态被调用函数 | 是 PE 入口，不应直接认定整段就是业务 DriverEntry |
| 0x1403d0128 | ParseWdiIhvRequest | 自动识别的解析包装函数，尚未恢复私有请求协议 |
| 0x1403d064c | ParseWdiTaskChangeOperationModeToIhv | 不证明支持 monitor 模式 |
| 0x1403d08f0 | ParseWdiTaskSendRequestActionFrameToIhv | 不证明允许任意 对等发现协议 action 帧 |
| 0x1403d0924 | ParseWdiTaskSendResponseActionFrameToIhv | 不证明用户态可直接调用 |
| 0x1403cf9bc | GenerateWdiIndicationActionFrameReceivedFromIhv | 不证明所有所需空口帧都能上报 |

证据见 候选函数摘录。调用图第 13903 行 将 FUN_14001ed80 与 ParseWdiIhvRequest 连接；第 49615 行 将 FUN_140032cb0 与 action-frame 请求解析函数连接。下一轮应追这些调用者的参数验证、分派与固件命令，而不是停留在生成/解析包装层。

### 3.3 IHV 是值得核查的现有接口方向，但还不是解决方案

IHV Strings 第 6548–6553 行 含 RouterUtils::OidSender::SendOid 与失败日志；IHV 字符串线索 含 IntelIhvRpcEndpoint、Dot11ExtNicSpecificExtension 等标识。

IHV 函数候选摘录 定位 Dot11ExtIhvInitService=0x180056c40、Dot11ExtIhvGetVersionInfo=0x180057720、Dot11ExtIhvInitVirtualStation=0x18005a5f0。

**设计判断**：应先弄清已有 IHV/WDI 通道是否提供所需功能，再考虑修改内核驱动。上述证据尚未给出 OID 数值、数据结构、权限、客户端认证、实际收发范围；没有调用这些入口或尝试绕过其权限检查。

### 3.4 固件/镜像文件的关联线索变强，但内部格式未解析

驱动 Strings 第 20124 行 有 Netwfw14.dat；候选摘录 有 DeviceControlLayer::ImagesDb 等镜像管理类字符串。配合前置 INF 的复制规则，足以支持继续检查该 DAT 与固件镜像装载的关系。

DAT Strings 开头 有 *WESTOPFORNOONE*、error_table_lmac1、txf_config_lmac1、signed_remote；其他位置有多组重复 monitor 字符串。DIE 仍只识别为 Unknown Binary。

没有恢复 DAT 容器头、各镜像边界、处理器架构、签名覆盖范围或固件命令 ABI；没有把整个 DAT 强行当 x86 文件反汇编。

## 4. 明确排除的误判

- DEBUG_MONITOR、DP_MONITOR、寄存器监测字段不等于 802.11 monitor mode。
- idcInjectDirectSurpriseRemovalWdmApi / fsmInjectEvent 等 Inject 字符串指向其他事件处理语义，不能据词根宣布帧注入可用。
- XVTProxyModeEnabled 等字符串没有被写入注册表，也未认定公开发行驱动一定实现该模式。
- WDI action-frame 解析函数存在，不代表底层允许任意 subtype、任意频道/时序，也不代表普通用户程序有合法直接入口。
- PDB 路径只是构建残留；没有拿到 Intel 私有 PDB，更没有完整原始源码。
- 自动调用图不能保证覆盖函数指针、回调、虚调用和固件内部行为。

## 5. 工具故障与整理结果

1. 中文安装路径触发 generic.log4j.xml 的 URI/XInclude 错误，常规日志 appender 未建立；错误留在会话工具事件中，不能把缺失的日志文件当作无警告。
2. 尝试把工具/会话目录映射为 R:/S:。Java 又将部分路径解析回真实路径，把 settings/cache 全置于映射路径时出现 Felix data-dir 一致性错误；该次启动失败。
3. 保持 settings/cache/temp 为一致的真实绝对路径后，headless 分析与导出成功，但日志配置警告仍存在。不是“中文路径问题已根治”。
4. 初次命令行传递原装导出脚本参数失败，虽然进程退出码是 0，仍按失败处理；随后使用原装脚本支持的 .properties 配置，成功生成并核对 JSON 与 DOT 内容。
5. R:/S: 临时映射已撤销，失败且中断的初始项目及锁文件已清理，只保留两个有成果的项目。工具原目录未被搬动。复跑配置中的 S:/ 输出路径需先重新建立同一映射，或改为实际输出目录。

## 6. 下一轮应做什么

优先对 `0x14000d320` 的注册回调、`0x14001ed80` 的 IHV 请求分派、`0x140032cb0` 的 action-frame 参数处理，以及 IHV DLL 的请求转发实现进行逐函数反编译/交叉引用核对。当前已建立地址和调用图基线，但尚未导出并人工验证这些函数的 C 伪代码。

如仍坚持不写任何分析脚本，可在 Ghidra GUI 中使用现成 Decompiler、References、Function Graph 和 C/C++ exporter。现有工具足够开始这一轮，不需要立刻新增软件；自动全量函数清单不能替代这一步。

在确认原始 RX、所需 TX、频道调度、ACK/重试与硬件恢复之前，不进入驱动修改，也不承诺 AX201 能复现 上层协议栈项目 的 RTL8821CU 用户态后端。
