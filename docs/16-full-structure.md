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

**虚表**：`.rdata` 中扫描出 **132 个候选虚表**（最大 99 项）。由于 Ghidra 完全未做 vtable 解析，所有经虚表的调用在调用图中**不存在**——这是全局入度统计系统性偏低的主因，也是 947 个"孤立函数"大部分其实是 vtable thunk 的原因。

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

**指示路径**：
```
CWdi*IndicationsObserver::handle<X>
 → 字段翻译器（FUN_1400dc6xx–dcc00 一批）
 → GenerateWdi<X>FromIhv（35 个 63 字节薄壳，0x1403cf7b8 起）
 → FUN_1403d1760（WDI 对象工厂）
 → oscWdiIndicate<X>
 → NdisMIndicateStatusEx
```

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

### 7.5 命令清单（节选）

| cmdId | 版本 | 大小 | 命令 |
|---:|---:|---:|---|
| 284 | 10 | 0x1C | `mhiffBuildTxCommandVer10` |
| 435 | 1 | 0xB0 | 添加站点 |
| 512 | 4 | 0x104 | PHY 上下文 |
| 1527 | 3 | 0x14 | 通知类 |
| 2048 | 12→13 | 0x250→0x264 | 位置测量（FTM） |
| 401 | 12→13 | — | TX Beacon |
| 268 | 5 | 0x0C | 扫描数据库配置 |
| 441 | 1→2 | — | 发送 P2P Action Frame |
| 3076 | 1→2 | — | SAR 偏移映射 |

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
2. **虚表未连接。** 132 个候选虚表未解析成类层次，调用图中经虚表的边全部缺失，全局入度不可信。
3. **固件 ABI 只到描述符层。** 118 条命令的命令号、版本、请求大小已知，但**每个命令内部字段布局**基本未知；`netwfw14.dat`（16.8 MB）仍未解包。
4. **无类型系统。** 全部结构体是 `param + 0xNN` 形式，仅对约 20 个关键结构推断了字段含义。
5. **并发与生命周期**：锁、引用计数、对象销毁时序基本未触及。
6. **算法性模块**：信道选择、速率自适应、聚合决策的内部逻辑未读。
7. **具体未解项**（各簇报告共 60+ 条），最关键的几条：
   - `0x140121300` 端口×子类型过滤器的真语义（Ghidra 判 void 但被比较返回值）
   - `0x14005e580` 返回值域（决定"直通上报"还是"完整安全校验"）
   - 35 个 `GenerateWdi*` 薄壳的类型 id / 消息 id 编码表
   - `DAT_14047f000` 追踪上下文表的精确布局（stride 与字段存在矛盾）
   - 641 项参数表中 12 项字符串表、3 项二进制表的内容未展开

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

## 15. 产物

| 内容 | 路径 |
|---|---|
| 伪代码 + 汇编 | `C:\ProgramData\AX201re\out\p1..p6`（26,712 文件，55 MB） |
| 元数据 | `out/meta`（functions / call_edges / strings / imports / vtables） |
| 聚类 | `out/clusters`（assignment / tag_modules / mhiff_commands / cpp_classes / iregisters_methods） |
| 调用图 | `out/graph`（top_indegree / top_outdegree / cluster_edges） |
| 模块报告 | `out/modules/*.md`（9 份） |
| 交叉索引 | `out/modules/_names.tsv`（13,348 函数 addr→名） |
