# Intel AX201 无线网卡驱动静态逆向记录

对一个 Windows 内核网络驱动的**只读静态分析**记录：函数级反编译、结构还原、数据表提取与工具脚本。

本仓库只包含分析结果、事实数据与自研脚本，**不包含任何厂商二进制文件**。

---

## 分析对象

| 项 | 值 |
|---|---|
| 目标 | `Netwtw14.sys` |
| 版本 | 23.50.21.2 |
| 平台 | Windows 11 x64（PE32+，x86-64） |
| 大小 | 5,646,928 字节 |
| SHA256 | `87C083010DAD3FB6AC8CAC99DDB5E274DF300DA789CC8774B4A25DA137DA38B8` |
| 框架 | NDIS 6.82+ WDI 迷你端口（`NdisMRegisterWdiMiniportDriver`） |
| 依赖 | `ndis.sys` / `ntoskrnl.exe` / `cng.sys` / `wdflr.sys` / `wdfldr`，共 177 个导入符号 |

配套分析过的还有同包的 IHV 路由 DLL 与固件镜像，未纳入本仓库。

---

## 分析规模

| 指标 | 数值 |
|---|---:|
| 反编译导出函数 | **13,348**（`.pdata` 运行时条目 15,741） |
| 汇编导出 | 13,348 |
| 调用边 | 52,522 |
| 字符串 | 11,076 |
| 恢复真实函数名 | 2,246（16.8%） |
| 确认虚表 | 125（91 张定出所属类） |
| 模块编号（编译单元） | 381 |
| 人工/代理逐行读过的函数 | 600–800（约 5%） |

**注意**：导出覆盖 100%，理解覆盖约 5%，两者不可混为一谈。

---

## 架构概览

```
┌──────────────────────────────────────────────────────────┐
│ NDIS 小端口（WDI）                                        │
│   回调：SetOptions / Unload / DevicePnPEventNotify /      │
│         Shutdown / CancelOid / FilterResourceRequirements │
├──────────────────────────────────────────────────────────┤
│ 命令对象框架  CPort / CPortMgr / CCmdTask / CCmdProperty  │
│   OID 路径 · Task 路径 · 指示路径                          │
├──────────────────────────────────────────────────────────┤
│ WDI ↔ IHV 语义翻译                                        │
│   CWdi*IndicationsObserver（7 个观察者）                   │
│   通用 TLV 序列化器（OID/任务/指示共用）                   │
├──────────────────────────────────────────────────────────┤
│ 控制面                                                    │
│   管理帧 · 连接 · 扫描/漫游/FTM · P2P/WFD                  │
│   MIB 参数体系 · 安全（密钥/PMF）· 电源/SAR · AMT         │
├──────────────────────────────────────────────────────────┤
│ 数据面                                                    │
│   RX：MDU 描述符 / 密钥表 / 重放窗口 / 上报                │
│   TX：端口分发 / TID 队列 / AMSDU 聚合 / 完成回调          │
├──────────────────────────────────────────────────────────┤
│ 固件命令层 MHIF（118 条命令描述符 + 27 条运行期版本覆盖）  │
├──────────────────────────────────────────────────────────┤
│ 硬件抽象与基础设施                                         │
│   HalLayer → SolarHalLayer / BlazarHalLayer               │
│   IRegisters（381 个寄存器访问器）                         │
│   OSAL：内存 / 锁 / 定时器 / Job / trace                  │
└──────────────────────────────────────────────────────────┘
```

### 几个关键结构

- **命令对象模型**：每个端口一个 `CPort`，串行化 OID 与 Task；`CAdapterProxy` / `CVifProxy` 管理适配器与虚拟接口。
- **固件命令表**：静态描述符 118 条（`cmdId` / 方向 / 请求大小 / 构造函数 / 版本），另有 27 条运行期版本覆盖，用于匹配固件上报的 API 版本。
- **参数体系**：641 项整型 + 12 项字符串 + 3 项二进制描述符，三张表在 `.data` 中首尾相接，优先读 machine 注册表，失败回落编译期默认值。
- **寄存器接口**：`IRegisters` 的 381 个 `get_*` 访问器覆盖 CSR / WFPM / LMPM / DBGC / RFH / SCD 等寄存器族。

详细的模块划分、类清单、数据结构偏移与未解问题见 [`docs/16-full-structure.md`](docs/16-full-structure.md)。

---

## 仓库结构

```
docs/
  02-static-analysis.md              静态基线
  03-ihv-request-and-action-frame.md IHV 请求封套与动作帧构造
  04-oid-dispatch-table.md           OID 分派表还原
  05-wdi-ihv-transport.md            WDI IHV 请求的传输方式
  06-sniffer-and-etw.md              监听模式与 ETW 输出链路
  07-driver-sniffer-subsystem.md     驱动内监听子系统
  08-firmware-command-layer.md       固件命令层勘查
  09-user-mode-attempts.md           用户态通道实测记录
  10-wlanihvcontrol-investigation.md WlanIhvControl 路径与 DACL
  11-rx-tx-boundary.md               收发边界与平台层限制
  16-full-structure.md               全量结构还原报告
  17-lessons-learned.md              逆向工程经验总结

data/
  oid-table.tsv                      146 条 OID 分派表（名称 / 数值 / 处理函数）
  manifests/                         产物清单与校验
  detection/                         格式识别结果

src/
  tools/ghidra/                      只读证据导出脚本与配置
  driver/oidproxy/                   自研 NDIS 协议驱动（OID 测试工具）
  probes/                            探测脚本
```

---

## 方法要点

1. **并行反编译**：6 个 Ghidra headless 实例按地址区间切分，项目复制多份避免锁冲突，全量导出约 54 秒。
2. **符号恢复**：驱动剥除了符号，但诊断断言字符串保留了 `__FUNCTION__` 全名，据此恢复 2,246 个函数名与类名。
3. **虚表恢复**：目标以 `/GR-` 编译、无 RTTI，改用 vptr 安装现场（`LEA + MOV [this]`）识别，得到 125 张虚表并补出 562 条间接调用边。
4. **静态数据表**：命令表、参数表等直接按 PE 节区映射从原始字节读取，不依赖反编译视图。

完整的方法与踩坑记录见 [`docs/17-lessons-learned.md`](docs/17-lessons-learned.md)。

---

## 复现

需要 Ghidra 12.x（置于纯 ASCII 路径）与 JDK 21+：

```
analyzeHeadless.bat <project> <name> \
  -process Netwtw14.sys -noanalysis -readOnly \
  -scriptPath src/tools/ghidra \
  -postScript Ax201ReadOnlyExport.java <config.json>
```

导出脚本只读：不修改程序字节、不写项目状态。配置见 `src/tools/ghidra/configs/`。

自研驱动编译环境：Windows SDK 10.0.26100 + WDK 10.0.22621 + MSVC 14.51，见 `src/driver/oidproxy/build.cmd`。

---

## 局限

- 除标注「实测」的项目外，结论均来自静态分析，未在硬件上验证。
- 13,348 个函数全部导出，但逐行读过的仅约 5%。
- 固件镜像（16.8 MB）未解包，固件侧行为未知。
- 118 条固件命令中仅 20 条还原了字段布局。
- 结构体未做类型恢复，全部为 `param + 0xNN` 偏移形式。

---

## 版权与免责

见 [NOTICE.md](NOTICE.md)。
