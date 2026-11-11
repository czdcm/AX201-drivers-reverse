# AX201 收发送边界与平台可行性裁定

2026-11-11。本轮目标：把「驱动内部做了什么」和「用户态能拿到什么」分开，回答 对等发现协议 在 Windows + AX201 上到底卡在哪。

证据等级：**[实测静态]** = 从样本反汇编/伪代码直接读出；**[文档]** = 微软/Intel 公开文档；**[推断]** = 由前述二者推出，未见直接证据。

## 1. 结论

**[推断] 在 AX201 + Windows 上，纯用户态实现 对等发现协议 不可行。** 卡点不是「找不到 API」，而是三层同时封闭：

1. Intel 明确不支持 monitor / 注入 / 混杂模式（[文档]）；
2. Windows 的 WDI 只把 Action Frame 的**帧体**上报给操作系统 WLAN 栈，不向普通用户态进程交付原始 802.11 帧（[文档] + [实测静态]）；
3. 驱动内唯一能发私有无线命令的通道，被 Intel 自己的签名组件与客户端校验把守（[实测静态]）。

要突破必须改内核驱动或固件，属于全新授权级别的工作，且不保证可行（固件闭源、驱动有签名、CNVio2 无 USB 旁路）。

## 2. 驱动接收侧：两条独立路径

### 2.1 管理帧总入口

`0x1402d0ad0` 的日志字符串即 `hmfmEvRxMgmtFrame`，说明它是「收到管理帧」事件处理器。它在派发前先调 `0x1402d67d0`（`prvHmfmIsSourceMacAddressValid`）校验源 MAC。

其分派表的 case 值就是 802.11 帧控制字节：

| FC 值 | 含义 | 目标块 |
|---|---|---|
| 0x10 / 0x30 | 关联请求 / 关联响应 | `0x1402d109a` |
| 0x40 | 探测请求 | `0x1402d16b8` |
| 0x50 | 探测响应 | `0x1402d2317` |
| 0x80 | Beacon | `0x1402d1d57` |
| 0x90 | Action No Ack | `0x1402d16b8` |
| 0xA0 | 去关联 | `0x1402d132b` |
| 0xB0 | 认证 | `0x1402d16bf` |
| 0xC0 | 去认证 | `0x1402d198c` |
| **0xD0** | **Action** | **`0x1402d27ed`**（内含 `0x1402d280c` 调 `prvHmfmHandleActionFrame`） |

「[实测静态]」分派地址 `0x1402d1098`，case 表见本轮 REA 证据。0xD0 这一项 Ghidra 无法给出可表示的 case 标签（置信度 medium），但其目标块正是调用 `prvHmfmHandleActionFrame` 的那一段，与伪代码中的 `case 0xd0` 相互印证。

### 2.2 Action Frame 的类别处理

`prvHmfmHandleActionFrame`（`0x1402d70f0`）按类别字节（帧体第 0 字节）分派：

- 类别 **0x7f（厂商自定义）** 与 0x02/0x06/0x0b–0x0f 一起落到 `break`，随后函数返回 0。
- 其余类别各有专门处理（0x08 = SA Query、0x0a = WNM、0x13 = 扩展、0x15 = 等）。

「[实测静态]」这里的 0 只是本函数的返回值，**不能推断为「驱动全局丢弃该帧」**，也不代表上层没有别的观察者。

### 2.3 面向操作系统的上报

另一条独立路径 `CWdiCommonClientIndicationsObserver::handleActionFrameReceived`（`0x140035660`）：

- 取 BSSID 6 字节、信道信息、帧体；
- 组装 indication 号 **`0x40050067`**；
- 调 `GenerateWdiIndicationActionFrameReceivedFromIhv`。

对应微软文档 `NDIS_STATUS_WDI_INDICATION_ACTION_FRAME_RECEIVED`，其负载为 `WDI_TLV_BSSID`、`WDI_TLV_BSS_ENTRY_CHANNEL_INFO`、`WDI_TLV_ACTION_FRAME_BODY`。

关键点：**上报的是「帧体」，不是完整 802.11 帧**；接收方是操作系统 WLAN 栈，不是任意用户态进程。

### 2.4 数据帧与管理帧的接收完成路径

`0x140045250` 把接收描述符的元数据整理进输出包结构（帧控制、地址、序列号、信道、时间戳等），随后按帧控制分叉：

- 数据帧（FC & 0x0c == 8）→ `0x1400448b0`
- 管理帧 → `0x140044bb0`
- 两者最终都汇到 `0x14000aab0`（`prvOscDpRxIsIndicationState` + `oscDpRxAddPacketToIndicationApi`）

`0x1400448b0` 里有一处真实丢弃判定：`0x14016d1a0`/`0x14016d130` 组合检查后，若不满足条件或标志位 `(desc+0xd0) & 0x120000` 为 0，就直接走释放路径。这说明**接收不是全量上送，存在按队列/上下文/标志的过滤**；具体位含义尚未还原。

## 3. 驱动发送侧：确实能构造原生 802.11 头

`0x140049690`（发送准备，1346 行，仅人工读了前 459 行）在 `0x140171560` 处处理帧头：

- 复制输入头部到帧缓冲；
- 检查 ToDS/FromDS 位；
- 提取并回写地址字段；
- 按端口上下文改写数据帧标志。

「[实测静态]」内部表示是原生 802.11 头，不是纯以太网载荷。这一点修正了「驱动只认以太网帧」的直觉判断。

但这不等于有注入接口：该函数的上游是 NDIS 发送路径（`0x14003a790` → `0x1400f6110` 需 miniport 处于可发送状态），且要经过 peer/队列/加密/QoS 处理。

另外 `0x1400f6110` 的失败路径是把包状态写回并释放，而不是绕过。

## 4. 私有命令通道被谁把守

已确认的链路：`IntelIHVRouter14.dll` 通过 NIC-specific OID（`0x0d01035c`）与驱动通信，驱动用 `GenerateWdiIhvRequest` / `ParseWdiIhvRequest` 收发。

访问控制（前几轮已核实，本轮沿用）：

| 检查 | 位置 | 作用 |
|---|---|---|
| `IsClientElevated` | DLL `0x18000bdd0` → `0x1800692d0` | 要求调用方提权 |
| `IsIntelOnlyApplication` | DLL `0x18000b780` | 维护 Intel 专用应用白名单 |
| `ValidateClient` | DLL `0x18000c540` | 校验客户端签名，`_ValidateCertificate` 检查签名者为 `Intel Corporation` |
| 会话状态位 | DLL `0x18003ffc0` 等 | 未通过校验的会话在发 OID 时直接失败 |

「[推断]」因此第三方程序即使知道 RPC 端点和报文格式，也拿不到可用会话；这不是「参数没猜对」，而是设计上的封闭。

## 5. 平台层证据

- Intel 官方支持文档：现行 Intel 无线网卡**不支持 monitor 模式与数据包注入**（[Intel KB 000058933](https://www.intel.com/content/www/us/en/support/articles/000058933/wireless/intel-wireless-ac-products.html)）。
- Intel 社区针对 AX201 的答复：Windows 下 monitor 模式、注入、混杂模式均不支持（[Intel Community](https://community.intel.com/t5/Wireless/supporting-monitor-mode-and-packet-injection/m-p/1531622)）。
- Npcap `WlanHelper` 在 AX201 上设置 monitor 模式返回错误 50「请求不受支持」（[Nmap-dev 邮件列表](https://seclists.org/nmap-dev/2020/q4/11)）。
- WDI 的 Action Frame 上报只带帧体（[NDIS_STATUS_WDI_INDICATION_ACTION_FRAME_RECEIVED](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/ndis-status-wdi-indication-action-frame-received)）。

这几条互相独立，指向同一结论：在 Windows 上无法通过受支持的接口让 AX201 收发任意 802.11 帧。

## 6. 对 对等发现协议 目标的影响

对等发现协议 需要的能力与现状对照：

| 对等发现协议 需要 | AX201 / Windows 现状 |
|---|---|
| 收发厂商自定义 Action Frame（类别 0x7f，OUI 00:17:f2） | 驱动内部有类别分派，但 0x7f 在本函数内不处理；上报给 OS 的只有帧体，且不含完整 MAC 头 |
| 原始 Data Frame 收发 | 驱动内部是原生 802.11 头，但对用户态无接口 |
| 精确的信道切换与驻留时序 | 有 Action Frame 的 channel/dwell 参数（`0x1400329a0` 等），但由 OS 任务驱动，用户态无法直接下发 |
| 接收全部空口帧（含管理帧） | 需要 monitor 模式，Intel 明确不支持 |

「[推断]」结论：**要在这台机器上用 AX201 跑 对等发现协议，必须改内核驱动（甚至固件），而不是写一个用户态后端。**

## 7. 可选路线（按代价排序，均需新授权）

1. **换硬件**：用支持 monitor + 注入的外置网卡（Atheros/MT76 系列），在用户态走 Npcap 原始收发。这是 上层协议栈项目 同类方案的现实路径，但偏离「用本机 AX201」的目标。
2. **内核驱动改造**：在 Netwtw14 上增加一个受控的原始帧收发接口。需要处理驱动签名、HVCI、CNVio2 初始化、固件命令构造；且固件是否允许任意帧发送仍未知。
3. **放弃 AX201，改用软件无线电/虚拟介质**：与目标偏离更远。

在拿到 2 的可行性证据（固件命令表、发送路径的实际限制）之前，不建议投入。

## 8. 本轮未完成 / 下一轮可做

- `0x1400448b0` 的接收过滤位（`0x120000`、`0x10000`、`0x20000`）语义未还原。
- `0x140049690` 只人工读了 459/1346 行，发送路径后半段（队列、加密、聚合）未读完。
- `prvHmfmHandleActionFrame` 中 0x7f 返回 0 之后，是否存在其它观察者另行上报，未闭合。
- IHV 通道是否真的存在「发送 Action Frame」的私有 opcode，未在驱动侧定位到具体分支。
- 固件容器与命令 ABI 完全未触及。

## 9. 工具与效率备注

本轮起用 REA（Ghidra 12.1.4 provider）替代部分自写脚本流程。相对收益：

- **跳转表还原**：自写脚本导出的伪代码里 Ghidra 明确报 `Could not find normalized switch variable`，REA 的 `inspect_native_api` 直接给出 case→目标块映射。这是本轮能确认 0xD0 分支的关键。
- **引用查询**：`xrefs` 与 `procedure_references` 覆盖间接与指令内部引用；自写脚本对虚表槽返回空。
- **响应速度**：一次导入后单次查询为秒级，不必每次启动 headless。

未解决：`0x1403e7f38` 这类虚表槽仍然查不到直接引用，说明观察者对象是通过基址+偏移在运行时访问的，静态引用不可达。这类问题应改用「找对象构造点」而非「找槽引用」的策略。
