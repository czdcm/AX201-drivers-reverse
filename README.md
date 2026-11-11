# AX201 驱动逆向记录

Intel Wi-Fi 6 AX201（CNVio2）在 Windows 上的驱动静态逆向与可行性验证。

本仓库只包含**分析结果、事实数据、脚本**，不包含任何 Intel 二进制文件，也不包含大规模反编译产物。

---

## 结论

**在「使用阶段保持 Secure Boot 开启、不新增硬件」的前提下，目标无法达成。**

两道不可绕过的限制叠加：

1. 未获微软签名的内核组件无法在 Secure Boot 开启状态下加载；
2. 修改过的 `Netwtw14.sys` 永远无法获得签名，也不能合法分发。

技术路径本身是通的（见 [`docs/05-wdi-ihv-transport.md`](docs/05-wdi-ihv-transport.md)），但落地需要 EV 代码签名证书 + 微软 attestation 签名，属于采购与审核流程。

---

## 目标与约束

| 项 | 内容 |
|---|---|
| 目标 | 在本机 AX201 上实现 AirDrop 接收 |
| 硬件约束 | 不新增任何硬件 |
| 安全约束 | 使用阶段 Secure Boot 保持开启（安装时临时关闭可接受） |
| 已确认前提 | 接收端不需要 Apple 签发的身份证书 |

---

## 环境与样本

| 项 | 值 |
|---|---|
| 主机 | ASUS TUF Gaming F16 FX607JIR |
| 系统 | Windows 11 Pro x64 `10.0.26300` |
| 网卡 | Intel Wi-Fi 6 AX201 160MHz |
| 硬件 ID | `PCI\VEN_8086&DEV_7A70&SUBSYS_00748086&REV_11` |
| 总线 | CNVio2（**不是** USB，WinUSB/libusb 路线不可用） |
| 驱动版本 | `24.50.0.4`，`oem73.inf` |
| 驱动包 | `netwtw08.inf_amd64_7d404936069a9b78` |

样本 SHA256：

| 文件 | SHA256 |
|---|---|
| `Netwtw14.sys` | `87C083010DAD3FB6AC8CAC99DDB5E274DF300DA789CC8774B4A25DA137DA38B8` |
| `IntelIHVRouter14.dll` | `60B7F7BC371E711FDA6BD957A252F779B4D326F9637BFD4751D27D88826B9ACF` |
| `netwfw14.dat` | `23FC171B845E40613969FB8480FC5660D634E6050EB1EEFF010B35D1349DDB5A` |

---

## 目录结构

```
docs/                                分析报告
  01-overview.md                     最初调查：硬件、驱动包、模块构成
  02-static-analysis.md              第一轮静态基线
  03-ihv-request-and-action-frame.md IHV 请求封套与 Action Frame 构造
  04-oid-dispatch-table.md           OID 分派表还原（146 条）
  05-wdi-ihv-transport.md            WDI IHV 请求的真实传输方式 ★
  06-sniffer-and-etw.md              嗅探帧经 ETW 输出 ★
  07-driver-sniffer-subsystem.md     驱动内嗅探子系统与 MAC 类型枚举
  08-firmware-command-layer.md       固件命令层（MHIF）勘查
  09-user-mode-attempts.md           用户态三条通道的实测记录
  10-wlanihvcontrol-investigation.md WlanIhvControl 路径与 DACL
  11-rx-tx-boundary.md               收发边界与平台层限制
  12-receive-paths-retrospective.md  接收路径全量复盘
  13-deliverable-and-signing.md      交付形态、签名与社区版安装设计
  14-conclusion.md                   阶段性裁定
  15-handoff.md                      交接记录
  external/
    dropbridge-radio.md              DropBridge radio 后端契约
    dropbridge-awdl.md               DropBridge AWDL 上层复用面

data/                                结构化数据
  oid-table.tsv                      146 条 OID 分派表（名称 / 数值 / 处理函数）
  wlan-capabilities.txt              系统报告的网卡能力
  manifests/                         证据清单、驱动清单、下载校验
  detection/                         DIE 格式识别结果

src/                                 源码根目录
  tools/ghidra/
    Ax201ReadOnlyExport.java         只读证据导出脚本
    configs/                         各轮导出配置
  driver/oidproxy/
    oidproxy.c                       自写 NDIS 协议驱动（可编译，未部署）
    build.cmd                        编译脚本（SDK 26100 + WDK 22621 + MSVC）
  probes/                            提权探测脚本，按执行顺序编号
```

## 仓库位置约定

本仓库的工作副本位于如下结构，`repo/` 才是版本库根：

```
C:\Github\AX201-drivers-reverse\
├── repo/       ← 版本库根（本 README 所在）
└── private/    证据存档（反编译产物、字符串转储、日志），不纳入版本库
```

---

## 核心发现

### 1. OID 分派表

`.rdata` 中一张起始于文件偏移 `0x52FC60` 的连续表，共 **146 条**，每条 `0x50` 字节：

| 偏移 | 宽度 | 含义 |
|---|---|---|
| 0x00 | 0x40 | OID 名称 |
| 0x40 | u32 | OID 数值 |
| 0x44 | u32 | 保留 |
| 0x48 | u64 | 处理函数 |

交叉验证：`OID_802_11_BSSID_LIST_SCAN` 对应 `0xFF800000`，与 Windows 标准定义一致。

完整数据：[`data/oid-table.tsv`](data/oid-table.tsv)

### 2. WDI IHV 请求的真实传输方式

`dot11wdi.h` 中：

```c
#define WDI_OID_PREFIX   0x0e4400000U
#define WDI_IHV_REQUEST  93
```

得 **`OID_WDI_IHV_REQUEST = 0xE440005D`**。

Intel 私有命令不走裸 OID：

```
操作系统 ──OID_WDI_IHV_REQUEST + WDI TLV──▶ 驱动
                                            │ ParseWdiIhvRequest
                                            ▼
                          prepareNicSpecificOidFromWdiIhvRequest
                                            ▼
                              私有 NIC-specific OID (0x0D01035C)
```

这是标准 WDI OID，理论上普通 NDIS 协议驱动也能发送。

### 3. 嗅探模式与 ETW

`0x1400450e0` 是接收分发入口，按模式标志分叉：

```c
if (*(int*)(*(adapter + 0xcf68) + 0x28) == 0)
    → 正常上报操作系统
else
    → 构造 radiotap → EtwWriteTransfer → 丢弃该帧
```

`0x1401a6e80` 负责拼 radiotap（TSFT / flags / rate / channel / MCS / VHT / HE）。

即：嗅探模式下帧走 ETW，用户态可订阅；但启用嗅探需要私有命令。

### 4. 驱动内可改点

| # | 位置 | 现状 | 难度 |
|---|---|---|---|
| 1 | `utilOpModeToMacType` `0x1400432a0` | 永不返回 SNIFFER(5) | 低 |
| 2 | `prvHmfmHandleActionFrame` `0x1402d70f0` | 类别 `0x7f` 落 break | 低 |
| 3 | OID 分派表 | 私有 OID 用户态不可达 | 中 |
| 4 | `mhiffSendP2pActionFrameCmdVer2` `0x1403455c0` | 只收帧体，头部由驱动生成 | 中 |
| 5 | `rxPacketProcessValidMpduFrame` `0x1400456e0` | 需加旁路出口 | 高 |
| 6 | 嗅探子系统 | 代码在，无调用者 | 高 |
| 7 | 换台命令族 | 需暴露 | 中 |

---

## 实测排除的路径

| 路径 | 结果 |
|---|---|
| `WlanIhvControl`（service） | `ERROR_DEV_NOT_EXIST` |
| `WlanIhvControl`（driver） | `ERROR_NOT_SUPPORTED` |
| 放开 `wlan_secure_ihv_control` DACL 后重试 | 仍失败，限制不在 ACL |
| Npcap `PacketRequest` + 标准 OID | 成功（读回真实 MAC） |
| Npcap + 私有 OID `0xFF100015` | `0xC00000BB` NOT_SUPPORTED |
| Npcap + 私有 OID `0x0D01011A` | `0xC0010017` INVALID_OID |
| Npcap 自带 `WlanHelper` | 可读 mode/channel，但走 WlanAPI 而非 OID |

用户态没有任何路径能把私有命令送进 AX201 驱动。

---

## 复现

静态分析：Ghidra 12.2 + JDK 25，全程只读。

```
analyzeHeadless.bat <project> <name> \
  -process Netwtw14.sys -noanalysis -readOnly \
  -scriptPath src/tools/ghidra \
  -postScript Ax201ReadOnlyExport.java <config.json>
```

脚本不修改程序字节、不写项目状态。配置见 `src/tools/ghidra/configs/`。

驱动编译：Windows SDK 10.0.26100 + WDK 10.0.22621 + MSVC 14.51，见 `src/driver/oidproxy/build.cmd`。

---

## 还缺什么

| 缺口 | 性质 |
|---|---|
| 微软 attestation 签名 | 采购流程（EV 证书 + Partner Center） |
| WDI TLV 封装格式 | 可从 SDK 头文件与文档还原 |
| Intel 内层载荷格式 | 需继续静态还原 |
| 固件是否响应嗅探命令 | 只能实测 |

签名是必要条件，不是充分条件。

---

## 限制

- 除标注「实测」的项目外，结论均来自静态分析，未在硬件上验证。
- `netwfw14.dat` 未解包，固件侧能力未知。
- 嗅探模式能否被固件接受，静态无法判定。
- Ghidra 对 CFG 间接调用与自动类型推断存在已知失真，相关结论已在各文档标注。

---

## 版权与免责

见 [NOTICE.md](NOTICE.md)。
