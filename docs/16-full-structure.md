# Netwtw14.sys 结构还原报告

> 样本：`Netwtw14.sys` 23.50.21.2（SHA256 `87C08301…`），Intel Wi-Fi 6 AX201 驱动。
> 时间：2026-11-11 18:00–20:00，Ghidra 12.2 静态分析 + 9 个并行子智能体分簇精读。
> 全程只读，未加载样本、未联网、未提权。

---

## 0. 先读这一节：诚实的覆盖率

| 指标 | 数值 |
|---|---|
| 反编译导出 | **13,348 / 13,348 函数（100%）** |
| 汇编导出 | 13,348 份 |
| 调用边 | 52,522 |
| 字符串 | 11,076 |
| 导入符号 | 177 |
| 恢复真实函数名 | 2,246（16.8%） |
| 模块编号（tag） | 368–381 |
| **人工/子智能体逐行读过的函数** | **约 600–800（4.5–6%）** |
| 调用级（只看调用关系）覆盖 | 约 2,500（19%） |

**导出不等于读懂。** 本报告能给出可信的**分层结构、模块划分、命令表、关键数据结构与关键流程**，但不能声称"还原了整个驱动"。第 13 节逐条列出仍未解的部分。

---

## 1. 方法

1. 6 个 Ghidra headless 实例并行，按地址区间切分 `0x140001000–0x1405d4fff`，导出每个函数的伪代码与汇编。
2. 从伪代码中提取 `FUN_1400b37e0(tag, "名字", 行号, 站点)`，构建地址→真名映射。
3. 按「名字前缀 + 调用图标签传播」聚成 14 簇。
4. 9 个子智能体各领一簇精读，产出模块报告。
5. 汇总、交叉校验、修正。

---

## 2. 命名体系（本报告的地基）

### 2.1 `FUN_1400b37e0` 不是日志函数，是断言/看门狗检查点记录器

这是本次最重要的方法性发现，纠正了此前的误解。

```
FUN_1400b37e0(moduleId, "Class::Method", sourceLine, siteTag)
```

它做四件事：

1. 通过 WPP/ETW 发一条文本事件（事件号固定 0xEB）；
2. 维护一个 **50 槽环形缓冲**（`DAT_1404b06f8` 索引，`DAT_1404b06fc` 起 50 个 dword）；
3. 必要时 `NdisWriteErrorLogEntry(handle, 0xC0001392, 2, 'WDRV')`；
4. 必要时触发 live kernel dump。

**因此第二个参数是 `__FUNCTION__`，是断言所在函数的完全限定名，不是日志文本。** 代价是：只有"至少含一处断言"的函数才有名字——**没有断言的核心函数依然无名**，这解释了为什么 83% 的函数仍是 `FUN_xxx`。

### 2.2 第二命名来源

`osalSyncAcquireSpinLock(obj, "nalPrphRead32")` 这类调用会把当前函数名写进调试上下文（64 字节缓冲），共 241 处使用。

### 2.3 tag 的含义

tag **不是地址、不是行号**，是**源文件/编译单元 ID**。同一 TU 内多个函数共用一个 tag，因此 tag 可用于推断"这个函数属于哪个源文件"，但不能用来切函数边界。

行号可验证：`memAlloc` 的 `0x1E4` = 484，`prvMemAllocSharedMemBuffer` 的 `0x2FD` = 765，`osMemoryInitLookasideList` 的 `0x442` = 1090。

---

## 3. 模块划分

### 3.1 重要警告：簇 ≠ 模块

地址聚类的簇是**连续地址段**，不是功能模块。例如 `wdi-osal`（5,488 函数）实际横跨：OSAL 底座、WDI 指示适配、NDIS 小端口、电源状态机、RFD/TFD 队列、固件镜像装载、EEPROM、VIF/MVM、P2P 角色状态机、AMT、DTFP、BT 共存、ACPI/SMBIOS 平台层、诊断遥测等十余个子系统。

正确的模块划分应按 **tag（编译单元）** 做，簇只作为分工手段。

### 3.2 tag → 子系统（已确证的代表项）

| tag | 函数数 | 子系统 |
|---|---:|---|
| `0x32a5` | 381 | 硬件寄存器 `IRegisters` |
| `0x104` | 114 | **固件命令表（MHIF）** |
| `0x26c` | 104 | MVM 管理器（MAC 虚拟层） |
| `0x110` | 33 | MIB / 配置框架 |
| `0x3287` | 32 | AMT / WiMa 带外管理 |
| `0x4f93` | 27 | 调试数据采集（dcl） |
| `0x327a` | 26 | OID 事件处理（最大源文件，约 9,024 行） |
| `0x4b2` | 24 | 数据面对等组 |
| `0x31bb` | 24 | 数据面统计 |
| `0x443` | 22 | 信道选择 |
| `0x326e` | 22 | 管理帧管理器 hmfm |
| `0x4e61` | 20 | 连接插件 cnct |

完整表：`out/clusters/tag_modules.tsv`

### 3.3 已知模块编号（跨簇汇总）

`0x100` MHIF 分发 · `0x101` 表版本/FW API · `0x104` MHIF 命令表 · `0x106` 参数加载 · `0x10c` BSS 表 · `0x10d` 信道表 · `0x110` MIB 框架 · `0x113` STA 表 · `0x146` BT 共存 · `0x265` Job 调度 · `0x26c` MVM · `0x2ab`/`0x2f1`/`0x2f5`/`0x309`/`0x46b`/`0x46c` 固件镜像装载 · `0x31a1` CWdiBss · `0x311a` CPort · `0x3132` CCmdPropIhvRequest · `0x314c` CNdis · `0x3151` NIC 电源 · `0x315b` Action Frame 引擎 · `0x326e` hmfm · `0x3277` idc · `0x327a` OID 处理 · `0x3287` AMT/WiMa · `0x31af` CPagingMgr · `0x31b4` mfu · `0x31bb` dp 统计 · `0x35ac` OSAL 内存 · `0x35bc` OSAL 锁 · `0x35e4` OSAL 定时器 · `0x4ed` CPortMgr · `0x4f93` dbgTlv · `0x4fb` CWdiCommonClient · `0x4fc` CWdiP2PDevice · `0x4ff2` bssLinkMgr

---

## 4. 分层结构

```
┌──────────────────────────────────────────────────────────┐
│ NDIS 小端口（WDI）                                        │
│   NdisMRegisterWdiMiniportDriver，要求 NDIS ≥ 6.82        │
│   回调表：SetOptions/Unload/DevicePnPEventNotify/         │
│           Shutdown/CancelOid/FilterResourceRequirements   │
├──────────────────────────────────────────────────────────┤
│ 命令对象框架：CPort / CPortMgr / CCmdTask / CCmdProperty  │
│   OID 路径 · Task 路径 · 指示路径 三主干                   │
├──────────────────────────────────────────────────────────┤
│ WDI ↔ IHV 语义翻译                                        │
│   CWdi*IndicationsObserver（7 个观察者类）                 │
│   GenerateWdi<X>FromIhv 薄壳族（35 个）                    │
├──────────────────────────────────────────────────────────┤
│ 控制面                                                    │
│   管理帧 hmfm · 连接 cnct · 扫描/漫游/FTM · P2P/WFD        │
│   MIB 参数体系 · 安全（密钥/PMF）· 电源/D3/SAR · AMT       │
├──────────────────────────────────────────────────────────┤
│ 数据面                                                    │
│   RX：MDU 描述符 / 密钥表 / 重放窗口 / PMF / 上报          │
│   TX：端口分发 / TID 队列 / AMSDU 聚合 / 完成回调          │
├──────────────────────────────────────────────────────────┤
│ 固件命令层 MHIF                                           │
│   118 条命令描述符 + 27 条运行期版本覆盖                   │
├──────────────────────────────────────────────────────────┤
│ 硬件抽象 / 基础设施                                        │
│   HalLayer → SolarHalLayer / BlazarHalLayer               │
│   IRegisters（381 个寄存器访问器）                          │
│   OSAL：内存 / 锁 / 定时器 / Job / trace                   │
└──────────────────────────────────────────────────────────┘
```

---

## 5. C++ 对象模型

RTTI 被剥除（`/GR-`），`.rdata` 中无类型描述符；类名全部来自 `__FUNCTION__` 字符串。共 **22 个类**。

| 类 | 方法数 | 职责 |
|---|---:|---|
| `IRegisters` | 381 | 硬件寄存器访问 |
| `CWdiBssIndicationsObserver` | 9 | BSS 类 WDI 指示 |
| `CWdiP2PGoIndicationsObserver` | 7 | P2P GO 指示 |
| `DebugDataCollector` | 7 | 调试数据采集与上报 |
| `CPort` | 6 | 端口命令容器 |
| `CWdiP2PDeviceIndicationsObserver` | 5 | P2P 设备指示 |
| `SolarHalLayer` | 4 | AX2xx 代 HAL |
| `CWdiCommonClientIndicationsObserver` | 4 | 客户端连接状态 |
| `HalLayer` | 4 | HAL 基类 |
| `CheckForHang` | 3 | 挂起检测 |
| `CP2PClientVifProxy` | 3 | P2P 客户端 VIF |
| `CPagingMgr` | 2 | 固件分页 |
| `CAdapterProxy` / `CVifProxy` | 2 / 1 | 适配器与 VIF 代理 |
| 其余 8 个 | 各 1–2 | `CWdiAdapterIndicationsObserver`、`CWdiDataPathBaseIndicationsObserver`、`CWdiP2PClientIndicationsObserver`、`CcoreProxy`、`CPortGo`、`CcoreIndicationPreAuthAssocParamsRequest`、`CIntelWifiTraceConfiguration`、`BlazarHalLayer` |

`Solar` / `Blazar` 为芯片代号分支，说明驱动内含两代硬件差异化实现。

**虚表**（第二轮专项攻关已完成）：

驱动用 `/GR-` 编译，**全文件无一处 RTTI 修饰名**，`vtable[-1] → COL → TypeDescriptor` 这条标准路径不可用。改用更强的判据——**vptr 安装现场**（MSVC 构造/析构的标准形态 `LEA RAX,[vftable]` + `MOV [RCX],RAX`）：

| 项目 | 数字 |
|---|---:|
| 确认虚表（带安装铁证） | **125** |
| 存疑单列 | 3 |
| 定出类归属 | 91 / 125（32 个类） |
| 虚表槽位边 | 3,720（覆盖 1,319 个函数） |
| **新补出的间接派发边** | **562** |
| 原「入度为 0」函数 | 4,580，其中 **1,256（27.4%）被虚表认领** |

补边后**原 Top 12 入度榜一个都没变**（前 12 名是库/工具函数，靠直接调用就有几千入度）——说明补边算法没有污染既有热点，只是把一批原本入度 0 的桩函数放回原位（如 `_purecall` 0 → 469、`thunk_FUN_14011b630` 0 → 359）。

**一个必须记住的坑**：候选中的 `0x14043FCD0` **不是虚表**，而是**寄存器访问器分派表**（3,382 条目、838 个去重目标、全部挤在 171 KB 内）。若把它当虚表处理，会一次灌进 3,382 条假边。

**另一个反直觉点**：低去重率不能用来否决虚表——本驱动的 WDI/OSAL 接口大量方法共用空桩（`_purecall` 被引用 431 次），所以 21% 去重率的真虚表确实存在。



---

## 6. 命令对象框架

三套并行通道，均经 `CPort` 串行化：

**OID 路径**
```
CNdis::cmdEntryNormalMode (0x1400145e0)
 → CPortMgr 取端口（vtable+0x18）
 → CPort::handleCmdOnPortJob (0x14003c8b0)   // 串行化
 → CCmdProperty::execute
 → mmacAlSendCommandEx
 → completeOid (0x140016110)
```

**Task 路径**：`CPort → CCmdTask::execute → completeTaskByIndication (0x140026e20)`

**指示路径**（第二轮已解到序列化器层）：

```
CWdi*IndicationsObserver::handle<X>
 → 字段翻译器（FUN_1400dc6xx–dcc00 一批）
 → GenerateWdi<X>FromIhv（34 个薄壳 0x1403cf7b8 起 + 1 个空消息壳 0x1403d003c）
 → FUN_1403d1760（TLV 序列化器）
 → oscWdiIndicate<X>
 → FUN_140003be0 → NdisMIndicateStatusEx
```

**关键澄清**：`FUN_1403d1760` 不是"WDI 对象工厂"，而是**通用 TLV 序列化器**——34 个薄壳的调用者里只有 21 个是指示观察者，另 9 个是 `osal::CCmdPropGet*::buildCompleteOidBuffer` 与 `osal::CCmdTask*::buildCompleteIndicationBuffer`。**OID 完成、任务完成、指示三者共用同一套 TLV 生成器**。

描述表结构（用原始 PE 字节解出）：

- `_TLV_CONTEXT`（16 B 头）：`+0x00 entries*`、`+0x08 u16 count`、`+0x0A u16 typeId`（与薄壳第一参数 34/34 全等）
- `TLV_ENTRY`（24 B）：`+0x00 valueDef`、`+0x08 versionGate*`、`+0x10 u16 fieldId`、`+0x12 u16 srcOffset`、`+0x14 u16 flags`（bit0=叶子/嵌套、bit1=数组）
- `valueDef` 二态：嵌套表（递归）或 `FIELD_LAYOUT{u16* chunk, u16 n, u16 sizeA, u16 stride, u16 flags}`
- `versionGate`：`+0x20 loVersion`、`+0x24 hiVersion`、`+0x28 altEntryIndex`（真实分支不是直观的 `[lo,hi)` 窗口）
- 线格式：`{u16 fieldId, u16 payloadLen, payload}`

`NdisMIndicateStatusEx` 有 3 个调用点：`FUN_140003be0`（主发送器，33 个调用者）、`FUN_140003b50`（空消息）、`FUN_140118380`（本地状态，与 WDI TLV 无关）。


结构偏移：

- `CPort`：`+0xb8 currTask`、`+0xc0 currProperty`、`+0xc8 队列property`
- `CPortMgr`：`+0x808 端口数`、`+0x810 owner`、`+0x880 + i*0x10` 六个端口槽（i<6）
- 端口类型：0=ADHOC 1=AP 2=STA 3=P2P_DEVICE 4=P2P_GO 5=P2P_CLIENT
- `CCmdProperty/CCmdTask` 基类：`+0x00 主vtable`（+0x18 名字、+0x38 完成、+0x78 超时）、`+0x08 次接口`（+0x1f8 id、+0x238 完成挂起、+0x248 OID码）、`+0x80 timer`、`+0x88 owner`、`+0xa4 state`、`+0xe0 hdrLen`、`+0xf0 buf`、`+0xf8 len`、`+0x128 OID`

---

## 7. 固件命令层 MHIF（本次最完整的一块）

### 7.1 命令描述符表

- 位置：节区 `PAGEdBla`，VA `0x1405B6060`，文件偏移 `0x536460`
- **118 条，步长 0x28**

| 偏移 | 类型 | 含义 |
|---|---|---|
| `+0x00` | u32 | cmdId |
| `+0x04` | u32 | 表索引（0=下行请求 / 1=上行响应） |
| `+0x08` | u16 | 请求结构大小 |
| `+0x10` | u64 | 构造函数指针 |
| `+0x18` | u32 | 命令版本 |
| `+0x20` | u64 | 校验函数（本版本全 0） |

已独立复核：表项 cmdId、reqSize、函数指针（均落在 `.text`）、版本号彼此自洽。

### 7.2 运行期版本覆盖表

`.data` VA `0x1404B6D50`，同 0x28 布局，**27 条**，由 `mhiffUpdateMhiffTblCommandVersion (0x1401d4990)` 按固件上报的 FW API 版本整条替换。

例：FTM `LocationRng` Ver12→Ver13、`TxBeacon` v12→v13、`PhyContext` v4→v5、`SendP2pActionFrame` v1→v2。

### 7.3 分发与帧头

上下文 0x38 字节（池 tag `IWBP`）：`+0x20` 命令号上限，`+0x28+ver*8` 两张表基址；表项 0x20 字节（tag `IWBH`），由 `MmLockPagableDataSection` 保护。

主入口：`prvMhiffTranslateCheckAndSend (0x140165140)`，配合 `mhiffTranslateCmd (0x140173f90)`、`mhiffCheckCommand (0x140172e00)`。

MHIF 帧头：

| 偏移 | 含义 |
|---|---|
| `+0x00` | cmdId 低字节 |
| `+0x02` | 载荷长度 |
| `+0x08` | 驱动源结构指针 |
| `+0x18` | 完成回调 |
| `+0x20` | 回调上下文 |
| `+0x40` | cmdId 高字节 |

即 `cmdId = (frame[0x40] << 8) | frame[0]`。

### 7.4 一个值得注意的兼容行为

`0xC00000BB`（NOT_SUPPORTED）在主干里被**静默吞掉并按成功回调**——这是"新驱动 + 老固件"的兼容路径。

超时不在本层（无定时器/重试字段），推断在 TX 队列层。

### 7.5 命令清单（已按构造函数断言名重建对应关系）

> **重要修正**：cmdId 与命令名的对应不能凭记忆。下表是按每个构造函数的断言串（`"mhiffBuildXxx"`）逐个重建的，纠正了两处错配。

| cmdId | 版本 | 请求大小 | 命令 |
|---:|---:|---:|---|
| 284 | 10 | 0x1C | `mhiffBuildTxCommandVer10` |
| **778** | 1 | 0x60 | **`mhiffBuildAddStaCommandVer1`**（此前误记为 435） |
| **264** | 4→5 | 0x20 / — | **`mhiffBuildPhyContextCommandVer4/Ver5`**（此前误记为 512） |
| 435 | 1 | 0xB0 | `mhiffBuildRSSConfigCommandVer1` |
| 512 | 4 | 0x104 | `mhiffTranslateSharedMemNotifVer4`（上行解析，非下行命令） |
| 193 | 5 | 变长 | RxMpdu |
| 268 | 5 | 0x0C | 扫描数据库配置 |
| 401 | 12→13 | 变长（固定头 0x20） | TxBeacon |
| 441 | 1→2 | 0x21C | 发送 P2P Action Frame |
| 456 | — → 8 | — | MccUpdateNotif |
| 514 | 1 | — | DutyCycle |
| 773 | 1→2 | — | SessionProtection |
| 1304 | 1 | 0x50 | SecKey |
| 1288 | 2 | 0x20 | RlcCfg |
| 2048 | 12→13 | 0x250 → 0x264 | LocationRng（FTM） |
| 3073 | 6→7→8 | — | LariConfig |
| 3076 | 1→2 | 0x154 | SarOffsetMapping |
| 4096 / 4098 / 4100 | — | 步长 0x98 / 0x98 / 0x166 | Statistics 族 |
| 4101 | — | 0x54 | Statistics（最干净，0x00 16B + 0x10 60B） |
| 102 / 103 / 104 | — | — | TimingMsmt |

**27 条运行期覆盖表不仅"覆盖"，还"补充"**：`401 TxBeacon Ver13`、`456 MccUpdateNotif Ver8`、`3073 LariConfig Ver7/Ver8`、`264 PhyContext Ver5` 等**根本不在 118 条静态表里**——只读静态表会直接漏掉整条命令。这正是"同一 `.sys` 内新旧两版构造函数并存、由固件上报的 API 版本选路"的硬证据。

**`+0x08` 的大小字段只在方向 0（请求）可信**：方向 1（响应/通知）经常登记值小于实际 memset 长度（如 4096 登记 444、实际 memset 620）。还原时应以构造函数里的 `memset` / 断言常量为准。

### 7.6 固件演进的三种固定形态

| 形态 | 样本 |
|---|---|
| 新增保留字节 | PhyContext Ver4→Ver5：唯一差别是 Ver5 多写 `+0x14 = 0`，其余字段逐字相同 |
| 头部重排/插入 | SessionProtection Ver1→Ver2（`cfg+0x18` 提到 0 号位）；SendP2pActionFrame Ver1→Ver2（前 6 字节后挪 1 字节）；LocationRng Ver12→Ver13（起点下移 0x24，总长 592→612） |
| 掩码收紧/放宽 | LariConfig Ver6→7→8：Ver7 新增 `+0x18` 能力字（掩码 `0x7FE24F`），Ver8 给 `+0x0C` 加 `&0x3F`、`+0x10` 由低 4 位放宽到低 5 位 |

### 7.7 一处值得注意的缺陷

`TxBeacon (401)` 的构造函数**从不写 `+0x08` 与 `+0x14`，`memset` 也没有覆盖这两个位置**——命令结构里会带出未初始化的栈/堆残留。这是静态分析发现的真实缺陷点，已在字段表中如实记录。


完整 118 条：`out/modules/fw-command.md`、`out/clusters/mhiff_commands.tsv`

---

## 8. 接收数据面

### 8.1 分发修正

`0x1400450e0` **不是**端口分发器，而是**单个 RX MDU 的完成回调** `(adapter, pkt)`。多队列分发在其上层。

分叉条件 `*(int*)(*(adapter+0xcf68)+0x28)`：

- **== 0**：正常路径，但还有两个前置条件——`drop != 1` 且 `FUN_140121300(FC & 0xF0, qctx->portId) == 0`（端口×子类型的过滤器）
- **!= 0**：**抓包镜像模式**（不是错误处理）。栈上 200 字节 radiotap 由 `0x1401a6e80` 填充，经 `0x1400720a0` → `EtwWriteTransfer` 输出；开关是全局 `DAT_1404cc800 & 1`

### 8.2 关键结构

- **MDU 描述符**：0x1C0 字节池对象，原子引用计数在 `+0x1b4`，持有 4 KiB DMA 缓冲描述符 `+0xb0`，释放唯一出口 `0x140044460`
- **密钥表**：基址 `adapter + 0x1d18 + vPortId*0xa68`，每块 **8 × KEY_CTX(0x148)**；`+0x90` cipher、`+0x94` 有效、`+0x98` 类型（0=PTK 1=GTK 2=IGTK）、`+0xa0 + tid*8` 每 TID 16 个 PN 窗口
- **RX 队列上下文**：`adapter + 0x1020 + qid*0x1f0`，`+0x00` portId、`+0x18` 队列类型
- **每 peer 三张表**：`+0x19e0` 安全状态、`+0x578` 重复检测、`+0x610` BA 上下文
- **解密状态字 `pkt+0x64`**：bit8–10 cipher、bit11 硬件已解密、bit5 受保护、bit6 解密+ICV 成功、bit7 MIC 失败
- **协议豁免表** `dp+0xb770+portId*0x1f0`：52 字节 = count + 4×12，比较的是 LLC/SNAP 后的 EtherType

### 8.3 上报

数据帧 `0x1400448b0`、管理帧 `0x140044bb0`（`prvRxCreateOsMgmtPacket`），共用处理器表 `adapter+0xcde0 + (qgroup & (qcnt-1) + peer)*8`，经 `0x1400084b0` 建 NBL → `0x1400086b0` 绑定 → `0x14000aab0` 指示。

---

## 9. 发送数据面与 NDIS 接口

### 9.1 注册

`DriverEntry = 0x14000d320` 调 `NdisMRegisterWdiMiniportDriver`，**硬性要求 NDIS ≥ 6.82**（`NdisGetVersion()>>16==6 && minor < 0x52` 即拒绝）。

已确证回调：SetOptions `0x1400f6a30`、Unload `0x1401202b0`、**DevicePnPEventNotify `0x140014d60`**、Shutdown `0x1400f6380`、CancelOid `0x1400f5bf0`、FilterResourceRequirements `0x1400f5d20`。

### 9.2 结构性异常

导入表里**没有** `NdisMSendNetBufferListsComplete` / `NdisMIndicateReceiveNetBufferLists`。发送完成走运行时函数指针：`adapter->[0x68]+0x18` 是回调、`+0x90` 是上下文。

### 9.3 发送链路

```
oscMiniportSendNetBufferList (0x1400f6110)   // MiniportSendNetBufferLists，只做端口分发
 → (*(code**)(Port*0x20 + 0xd8 + adapter->[0x68]))
 → FUN_14004c260   // per-port submit core
 → TID/AC 分类
 → TID 队列
 → txFlowProcessTidQueueApi (0x14008ce00)  // 位图批量 kick
 → FUN_14008f840
完成侧：dpReportPacketCompleteApi (0x14008ca00) → 0x14000a5a0 → SG 解映射 → 上层回调
```

### 9.4 聚合

AMSDU 集中在两个大函数：`0x140045ba0`（15,063 字节，`prvTxCommitFragment`）、`0x140049690`（9,244 字节）。

**AMPDU 没有独立聚合调度函数**——只有注册表参数 `txAmpduDensity`/`txAmpduMaxSize` 与 TID 掩码配置，推断由固件 TLC 决定。

### 9.5 结构偏移

Adapter：`+0x10` SG-DMA 句柄 / `+0x68` TX 端口分发块（`+0xd0` 起 per-port 数组，步长 0x20）/ `+0xa8` 状态（6=运行 4=暂停）/ `+0xb0` osc 对象 / `+0x138→+0x50` 1000 项 × 0x10 包跟踪环。

---

## 10. 配置与参数体系

### 10.1 三张描述符表首尾相接

| 表 | 起始 | 项数 × 大小 |
|---|---|---:|
| 字符串参数 | `0x1405C0000` | 12 × 0x134 |
| 二进制参数 | `0x1405C0E70` | 3 × 0x1830 |
| 整型参数 | `0x1405C5700` | **641 × 0x3C** |

接缝地址严丝合缝（0x1405C0000 + 12×0x134 = 0x1405C0E70；+ 3×0x1830 = 0x1405C5700），与配置描述符里的计数字段（`+0x28`=641、`+0x2c`=12、`+0x30`=3）完全吻合。

### 10.2 加载链

`mibInitialize → prvMibRegTblInitialize → paramLoadInt (0x14024f9e0) → regPrvTryReadRegKeyFromMachineRegistry (0x1402503a0)`

**优先读 machine 注册表**，失败回落编译期缺省值。

641 项中 626 项名字可解析，构成驱动的完整可配置面（`[0]debugInt … [640]BlazarCnviChipId`）。

### 10.3 信道表

`mibChTbl` 是最大参数表：**0x3A630 = 239,152 字节**，123 槽 × 0x798（2.4G 14 + 5G 45 + 6G 64），分配大小与分项求和逐字节吻合。

### 10.4 字段访问器

`mibFldAccessor`：`Accessor{+0 count, +8 flds}`，`Fld` 步长 0x18，只用 `+0x00` 的 i32 偏移，静态表以 `entry[0] == -1` 终止。

**"偏移是数据，索引是代码"**——业务代码只写 `mibBssTblGetFld(tbl, 键, 字段号, &out)`，字段偏移完全不出现在指令常量里，必须查 `.data` 中的三张表（`0x1404B9820` Bss、`0x1404B9900` Sta、`0x1404B98B0`）。

### 10.5 与 OID 的关系

`hsysHandleEvOid (0x14027cf70)` 一级深度就直接调 `mibRegTblGet` / `mibOrdTblGet`——**OID 层不做名字翻译，直接以序号读写 MIB 槽位**；一批只读 OID 实质上就是"查注册表参数即返回"。

---

## 11. 管理帧

### 11.1 分派键

`hmfmEvRxMgmtFrame (0x1402d0ad0)` 的分派键是 **`FC[0] & 0xF0`**（subtype 已左移 4 位），不是 802.11 原值：

| 键 | 帧 | 处理 |
|---|---|---|
| 0x10 / 0x30 | (Re)AssocResp | `prvhmfmBuildReceivedCnctFrame` + 事件 0x51/0x52 |
| 0x50 / 0x80 | ProbeResp / Beacon | `hmfmCommonUpdateBssEntry` + 事件 0x4f/0x66/0x67 |
| 0xA0 / 0xB0 / 0xC0 | (De)Auth / Disassoc | 事件 0x55/0x53/0x54 |
| **0xD0** | **Action** | `return prvHmfmHandleActionFrame` |
| 0x40 / 0x90 | ProbeReq / ATIM | break，不处理 |
| 其余 | — | default，静默丢帧 |

早筛：只有 0x80/0x50 做 DA/SA 校验，0xD0 跳过。载荷长 = 帧长 − 0x18，上限 0x8F0。

### 11.2 Action 类别表

`prvHmfmHandleActionFrame (0x1402d70f0)`：

| 类别 | 去向 |
|---|---|
| 0x00 | 事件 0x56 |
| 0x01 / 0x11 | 事件 0x57 |
| 0x03 | 事件 0x58 |
| 0x04 / 0x09 | 二级 action：0→0x5A，其余丢弃 |
| 0x05 | action 0 → `FUN_14022ac20` |
| 0x07 | 事件 0x59 |
| 0x08 | `FUN_14021e420` |
| 0x0A | action 7 → `prvHmfmHandleBssTransitionManagementRequest (0x1402d7ac0)` |
| 0x13 | 子动作 1/5 → `FUN_1402304a0` / `0x140230120` |
| 0x15 | 事件 0x59 |
| 0x7E | `FUN_1402d8280` |
| **0x7F** | **break（不处理）** |
| ≥0x80 | 直接 return |

### 11.3 Action 帧发送：两条通道

`prvActionFrameApiDeciderRequest (0x140141580)` 返回通道选择：

- **1 = USING_NEW_DAF**：`prvActionFrameHandleFrameInDaf → prvActionFrameSendNewDafRequest (0x140142c60)`，走固件 DAF 命令（dwell / 重试上限 0xFE）
- **3/4/5 = VIF_STA 等**：`prvActionFrameStartProtectedSession (0x140142360) → prvActionFrameSendUsingDp (0x140143060)`，走数据路径

MAC 头构造 `prvActionFrameAddMacHeaderToFrame (0x140141440)`：`FC[0]=0xD0`（整帧先清零，Protected 位=0），`Addr1(+4)=Addr3(+16)=DA`，`Addr2(+10)=vif MAC`，body 从 `handle+0x38` 拷 `handle+0x30` 字节到 `+24`。

帧句柄：`+0x18 DA`、`+0x30 体长`、`+0x38 体指针`、`+0x50 方向`、`+0x54/0x56 vif idx`、`+0x58 state`、`+0x60 mode`；state/mode 字符串表在 `0x1404b2290` / `0x1404b2250`。

---

## 12. 安全、P2P、平台

### 12.1 安全

- 密钥表结构见第 8.2 节（每 vPort 8 个 KEY_CTX，每 TID 16 个 PN 窗口）
- 重放窗口两套实现：CCMP/GCMP `0x140095560`（每 TID 6 字节 PN + 首帧标志，按 `frag == 0` 推进）；WEP/TKIP `0x140095330`（IV/TSC + ExtIV 位）
- PMF/802.11w `0x14005cf40`：识别未保护的 (De)Auth/Disassoc，`0x140095be0` 解析 MMIE 取 IGTK，`0x140095c30` 做 **BIP-CMAC MIC 校验**，失败触发 `0x140054d70` 反制

### 12.2 P2P

本簇只有"动作帧发出/回收 + 停扫描 + vlink 状态"；**GO/Client 角色判定不在其中**（GO Intent 仅被打印，`param_2[0x0c]>>1`）。

角色状态机在别处：`GO_VIF_CONTROLLER_SM (0x1402123f0)`、`GO_VIF_CLIENT_SM (0x140370cc0)`、`GO_VIF_RESOURCE_MANAGER_SM (0x14035f540)`、`CVCM_* (0x14059cc70)`、`CLIENT_COMMON_CHANNEL_SWITCH_SM (0x140324530)`。

### 12.3 命名澄清

被聚为 `coex` 的 88 个文件里，24 个有名函数中 22 个是 `amt*` —— **它不是天线分配，而是 Intel AMT/vPro 带外管理通道**（12 个到 Intel ME 的 TLV 作业）。

与 BT 有关的只有一个 `btToWifiCapabilitiesTlv`（类型 2=PAUSE / 3=RESTART / 0xA=QUERY_RESET / 0xC=空操作）。

真正的 BT/LTE 共存实现（`hBtCoex*`、`lteCoex*`、`mhiffBuildSnowLTECoex*`）散落在其它簇中。

### 12.4 平台层

镜像内混有 OEM 定制（`prvLenovoSensorReadData`），但本簇看不到 OEM ID 比较，该分支是否可达未定。

---

## 13. 尚未还原的部分

按重要性排序，不掩饰：

1. **83% 的函数仍无名。** 命名依赖断言埋点，没有断言的核心逻辑无从取名。
2. **虚表已恢复（第二轮完成）**：125 张确认虚表、91 张定出类归属、补出 562 条间接派发边。但仍有 34 张「结构确定是虚表、拿不到类名」，且多重继承的二级虚表调用、非 8 倍数偏移的函数指针成员调用未覆盖——**562 条是保守下界**。
3. **固件 ABI 只解到字段层的一部分。** 118 条命令的命令号、版本、请求大小已知；**20 条重要命令的字段布局已还原**（见 `fw-command-layouts.md`），其余 98 条未展开；`netwfw14.dat`（16.8 MB）仍未解包。
4. **无类型系统。** 全部结构体是 `param + 0xNN` 形式，仅对约 30 个关键结构推断了字段含义。
5. **并发与生命周期**：锁、引用计数、对象销毁时序基本未触及。
6. **算法性模块**：信道选择、速率自适应、聚合决策的内部逻辑未读。
7. **「真孤立」函数 815 个**（入度与出度均为 0），其中只有 96 个能被虚表解释，其余约 719 个是真无引用（死代码 / ICF 残体 / 只被数据表间接引用），不宜硬塞进调用图。
8. **具体未解项**（各报告共 60+ 条），最关键的几条：
   - `0x140121300` 端口×子类型过滤器的真语义（Ghidra 判 void 但被比较返回值）
   - `0x14005e580` 返回值域（决定"直通上报"还是"完整安全校验"）
   - `TLV_ENTRY +0x16` 的 u16 字段语义（三个 writer 都不读它）
   - `DAT_14047f000` 追踪上下文表的精确布局（stride 与字段存在矛盾）
   - 641 项参数表中 12 项字符串表、3 项二进制表的内容未展开
   - `3076 SarOffsetMapping` 的位打包映射未追完


---

## 14. 对既有结论的修正

| 早前结论 | 修正 |
|---|---|
| `FUN_1400b37e0` 是日志函数 | **是断言/看门狗检查点记录器**，参数为 `(模块, __FUNCTION__, 行号, 站点)` |
| 模块编号即模块 | 是**编译单元 ID**，同一 TU 多函数共用，不能切函数边界 |
| `0x1400450e0` 是接收分发器 | 是**单个 RX MDU 的完成回调**，多队列分发在其上层 |
| 嗅探分支是错误处理 | 是**抓包镜像模式**，正常功能 |
| `coex` 簇 = 天线/BT 共存 | 是 **AMT/WiMa 带外管理** |
| 簇名 = 模块名 | 簇是地址段，横跨多个子系统 |

---

## 15. 独立交叉校验

子智能体的结构性结论并非全部采信，以下三处由主控独立复算原始二进制确认（自行解析 PE 节区表完成 VA→文件偏移映射，未依赖子智能体的转述）：

| 声明 | 校验方法 | 结果 |
|---|---|---|
| 固件命令表位于 VA `0x1405B6060`（文件 `0x536460`），步长 0x28 | 直接读原始字节 | ✅ 前三条 cmdId=193/284/435，版本 5/10/1，请求大小 0/0x1C/0xB0，与报告一致 |
| 运行期版本覆盖表位于 `0x1404B6D50`，含 LocationRng 升级 | 同上 | ✅ 第二条 cmdId=2048、版本 13、大小 `0x264`，与"Ver12→Ver13、0x250→0x264"一致 |
| 整型参数描述符表位于 `0x1405C5700`，641 项 × 0x3C，首项 `debugInt` | 同上 | ✅ 槽号 0、名字 `debugInt`、缺省值 3563 |

PE 布局（供复核）：ImageBase `0x140000000`，33 个节区，`.text` RVA `0x1000`/文件 `0x800`，`PAGEdBla` RVA `0x5B6000`/文件 `0x536400`。

## 16. 产物

| 内容 | 路径 |
|---|---|
| 伪代码 + 汇编 | `C:\ProgramData\AX201re\out\p1..p6`（26,712 文件，55 MB） |
| 元数据 | `out/meta`（functions / call_edges / strings / imports / vtables） |
| 聚类 | `out/clusters`（assignment / tag_modules / mhiff_commands / cpp_classes / iregisters_methods） |
| 调用图 | `out/graph`（top_indegree / top_outdegree / cluster_edges） |
| 模块报告 | `out/modules/*.md`（9 份） |
| 交叉索引 | `out/modules/_names.tsv`（13,348 函数 addr→名） |
