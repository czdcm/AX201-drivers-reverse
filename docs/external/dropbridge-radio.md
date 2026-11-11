# DropBridge radio 后端契约（面向 Intel AX201 替换的精确接口清单）

- 分析对象：`C:\Github\DropBridge\repo`（官方 main 分支 ZIP 快照，commit `68519f5f4d703965e2db33674cdb4ba10eb33908`；**不是 git 工作树**，未恢复 `upstream/`，无 `build/devourer-airbridge`）
- 分析方式：**纯只读**。未编译、未运行仓库脚本、未执行任何无线/USB/驱动命令、未修改仓库任何文件。
- 分析时间：2026-11-11
- 输出位置（本次唯一写入）：本文件
- 结论适用范围：只描述**本仓库快照里能看到的** radio 后端契约；devourer 内部实现不在快照内，凡涉及它的地方都按「文档/补丁级证据」标注。

## 证据分级（全文统一使用）

| 等级 | 含义 | 本文标记 |
| --- | --- | --- |
| **源码事实** | 本仓库 `.cpp/.h/.cs/.ps1` 里直接读到的语句/常量/调用 | 直接给 `文件:行号` |
| **静态推断** | 由源码结构推出、但没有运行验证的结论（含顺序依赖、边界条件） | 标「静态推断」 |
| **历史硬件报告** | 仓库内文档/日志里记录的 RTL8821CU 真机结果，本次未复现 | 标「历史硬件报告」 |
| **本机未验证** | 涉及本机 AX201、Windows 平台能力、驱动行为，本次完全没碰设备 | 标「本机未验证」 |

> 所有涉及 Windows 平台能力与 AX201 的陈述都属于**静态推断 + 本机未验证**：本次没有查询 PnP、没有调用 WLAN API、没有读驱动文档原文。它们是判断路线用的结构性论据，不是实测结论。

---

## 0. 结论先行

1. **可替换的接缝是 `radio_link` v3 这条线，不是驱动。** 线协议（8 字节头 + 载荷、6 种消息、radiotap+802.11 载荷、TCP 127.0.0.1:49876）是硬件无关的，`src/radio_usb/radio_link.h` 是 MIT 头文件，可以原样保留。真正的硬件耦合全部压在 `main.cpp` 对 `devourer`（`IRadio`/`DeviceConfig`/`WiFiDriver`/`UsbOpen`）的调用后面，一共 **14 个 API 面**（见 §11.1），其中只有 3 个真正硬件无关。
2. **RTL8821CU 专有的东西不在本仓库里。** 固件下载、EFUSE、PHY/RF 表、H2C/C2H、FastRetune 固件路径、功率跟踪、coex、USB claim/reset 全在 devourer（GPL-2.0）与本仓库的补丁 `patches/devourer-airbridge.patch`。本仓库只写「协议壳 + 队列 + radiotap 拼装 + 生命周期」。
3. **radio 后端对接 AWDL 的硬需求是四条**：原始 802.11 帧收、原始 802.11 帧发、毫秒级跨频段换台、硬件 ACK 可用。前三条是 AWDL 时隙调度决定的，第四条决定对端 ARQ 会不会停摆。这四条在 `radio_link` 里都没有显式消息，是**通过 RX/TX/SET_CHANNEL/SET_ADDRESS 隐式要求后端具备**的。
4. **AX201 的最大阻塞点不是协议，而是「没有任何合法用户态 Windows 接口能同时提供原始 802.11 注入 + 受控信道驻留 + 硬件 ACK 配置」。** AX201 走 CNVio2、不是 USB 设备（主会话已验证），WinUSB/libusb 路线在物理层就不成立；WLAN API 只能扫描/连接、不能注入；NDIS 轻量过滤驱动看到的是 802.3 而不是 802.11；Network Monitor 模式（若该网卡暴露）本身只收不发，也不提供强制信道/宽度驻留。所以「换 INF」或「再写一个 `radio_usb`」都不够，必须动内核侧（NDIS LWF/厂商配合），或换无线硬件。
5. **本仓库从未把 Intel 网卡当过 radio 目标。** `docs/HARDWARE_INTAKE.md:83` 只把机器上的 Intel 无线网卡标为「非目标」（原文写的是 **AX211**，与本机 AX201 型号不同，属历史记录，不可混用）。

---

## 1. 分析范围

### 1.1 必读入口（按 `AGENTS.md:5` 要求）

已读：`AGENTS.md`、`README.md`（关键段）、`docs/PHASE0_AUDIT.md`、`docs/PLAN.md`、`docs/FINAL_PLAN.md`、`docs/WORK_QUEUE.md`（radio 相关行）、`WORK_LOG.md`（按关键词定位，未逐行通读 135 KB）。

### 1.2 radio 相关源码与文档清单

| 文件 | 行数/大小 | 作用 |
| --- | --- | --- |
| `src/radio_usb/radio_link.h` | 35 行 | 线协议唯一定义（MIT，双端共用） |
| `src/radio_usb/main.cpp` | 828 行 | radio 守护进程：USB→radio_link 全部逻辑 |
| `src/radio_usb/radio_pipe_bridge.cpp` | 187 行 | 命名管道 ↔ TCP 字节泵（给 awdld 用） |
| `src/radio_usb/peer_telemetry.h` | 48 行 | 只统计「发给自己的单播数据帧」的链路遥测 |
| `src/radio_usb/channel_completion_test.cpp`、`peer_telemetry_test.cpp` | — | 无硬件单测（未运行） |
| `src/radio_usb/CMakeLists.txt` | 60 行 | 只编 8821C（`DEVOURER_JAGUAR2_8821C=ON`，其余全 OFF） |
| `src/supervisor/Program.cs` | 3678 行 | 生产客户端/监管：拉起、停止事件、日志解析、看门狗 |
| `src/awdl_netd/main.cpp` | 376 行 | 相邻接缝 49877（原始 IPv6 + 20 字节握手） |
| `patches/devourer-airbridge.patch` | 264 行 | 本仓库对 devourer 的唯一改动集（H2C/C2H/功率跟踪） |
| `docs/RADIO_CONTRACT.md` | 98 行 | 已有的接口对照（devourer 源码级，但上游不在快照内） |
| `docs/RADIO_USB.md` | 63 行 | radio 真机验证记录（历史硬件报告的主要来源） |
| `tools/radio_link_client.py` / `.dart` | 213 / 91 行 | 协议客户端参考实现（含 HELLO 解析、radiotap 拼帧） |

### 1.3 快照缺口（必须知道，否则会误引）

- **没有 `upstream/`**：`IRadio.h`、`DeviceConfig.h`、`RxPacket.h`、`RadiotapBuilder.h`、`WiFiDriver.h`、`UsbOpen.h`、`SelectedChannel.h` 都不在仓库里（`glob **/IRadio.h` 无结果）。凡引用这些头文件内容的地方，只能引 `docs/RADIO_CONTRACT.md` 与补丁文件，不能当源码读。
- **没有 `build/`**：`CMakeLists.txt:26-32` 要求的 `build/devourer-airbridge/src/ChannelSwitchCompletion.h` 不存在，按原样无法配置。
- 因此本次无法核实 devourer 的 `Packet.Data` 是否含 FCS、`send_packet` 是否解析 radiotap 的 rate/width、`FastRetune` 的实际耗时——这些一律进 §15「未验证清单」。

---

## 2. 进程拓扑与三条接缝

### 2.1 生产链（源码事实）

```
iPhone ──AWDL 空口──▶ RTL8821CU(USB 0bda:c820, MI_02=WinUSB)
                          │ libusb
                    airbridge_radio.exe        127.0.0.1:49876  radio_link v3
                          │ TCP
                    radio_pipe_bridge.exe      TCP ↔ \\.\pipe\winawdl-radio
                          │ 命名管道（字节泵）
                    awdld.exe                  WinAWDL + OWL（AWDL 控制面 + 原始 IPv6）
                          │ TCP 127.0.0.1:49877（20B 握手 + 2B 长度 + 原始 IPv6）
                    awdl_netd.exe              lwIP 终结 IPv6/NDP，代理 TCP 8771 / mDNS 5353
                          │
                    receiver.py (python.exe)
```

来源：`HANDOFF.md:79-88`、`docs/FINAL_PLAN.md:47-59`、`src/radio_usb/main.cpp:1-18`。

**注意**：`radio.exe` 自己说 TCP，不说命名管道；命名管道是**另一个进程** `radio_pipe_bridge.exe` 提供的（`radio_pipe_bridge.cpp:1-6`、`:92-95`）。所以「radio 侧 TCP 49876 桥到命名管道」这句话要改写成「桥进程把 49876 的字节泵进命名管道」。

### 2.2 端口/对象表

| 对象 | 归属 | 监听/创建方 | 连接方 | 关键源码 |
| --- | --- | --- | --- | --- |
| TCP `127.0.0.1:49876` | radio_link v3 | `airbridge_radio.exe` | `radio_pipe_bridge.exe`（也被 Python/Dart 测试客户端直连） | `main.cpp:387-418`、`radio_pipe_bridge.cpp:21-39` |
| 命名管道 `\\.\pipe\winawdl-radio` | radio_link v3 字节流 | `radio_pipe_bridge.exe` | `awdld.exe` | `radio_link.h:8`、`radio_pipe_bridge.cpp:92-95` |
| TCP `127.0.0.1:49877` | AWDL 主机 IPC（不是 radio_link） | `awdl_netd.exe` | `awdld.exe` | `awdl_netd/main.cpp:38,296-311` |
| TCP `127.0.0.1:8771` / UDP `15353` | 接收/ mDNS | netd / receiver | 内部 | 不在本文范围 |

### 2.3 相邻接缝 49877 的精确格式（补全背景事实）

背景里说「49877 传原始 IPv6」不完整，实际是两段：

1. **握手 20 字节**：`"AWDL"`（4 字节）+ 16 字节 IPv6 地址；netd 阻塞读满 20 字节并校验魔数（`awdl_netd/main.cpp:262-275`），随后用该地址配置 lwIP 接口并写地址文件。
2. **数据帧**：`2 字节小端长度 + 原始 IPv6 包`，长度必须 ≥40（IPv6 固定头），netd 发送方向上限 `kMaxFrame = 2048`（`:40`、`:97-108`、`:110-129`）；IP 层 MTU 设为 `1450`（`:134`）。接收侧没有 2048 上限检查，只检查 ≥40（`:240-250`）。
3. **背压**：lwIP `ERR_MEM` 时按墙钟预算（默认 500 ms）重试后丢弃，`kIpcSendTimeoutMs = 5000` 设在 IPC socket 上（`:41`、`:207-225`、`:259-261`）。
4. **失败语义**：任何 IPC 读写失败 → `shutdown(SD_BOTH)` → 进程退出，让监管重启整链（`:74-81`）。

这条接缝与 radio 无关，列出来是为了说明：**AWDL 侧的对端（awdld）同时是 49876 的客户端和 49877 的客户端**，换 radio 后端不影响 49877。

---

## 3. `radio_link` v3 线协议（精确字节）

### 3.1 帧头与常量（源码事实，`radio_link.h`）

```c
#define RADIO_LINK_PIPE_NAME "\\\\.\\pipe\\winawdl-radio"   // 实际字符串：\\.\pipe\winawdl-radio
#define RADIO_LINK_VERSION 3u
#define RADIO_LINK_MAX_PAYLOAD 16384u

struct radio_link_header {   // 8 字节，小端
  uint16_t type;      // 偏移 0
  uint16_t reserved;  // 偏移 2，发送端必须写 0，接收端不校验
  uint32_t length;    // 偏移 4，仅载荷长度，不含头
};
static_assert(sizeof(radio_link_header) == 8);
```

- `radio_link.h:8-10`（常量）、`:21-25`（头）、`:34`（8 字节断言）。
- 载荷紧跟在头后面，一次连接内是**连续字节流**；没有额外分隔符、没有 CRC、没有帧尾（`main.cpp:624-635` 逐帧 `recv_exact`）。
- 端序：LE。Python 客户端用 `struct.pack("<HHI", type, 0, len)`（`tools/radio_link_client.py:51-53`），Dart 用 `Endian.little`（`tools/radio_link_client.dart:28-36`），与本实现一致。

### 3.2 消息总表

| ID | 名字 | 方向 | 载荷 | 载荷长度 | 应答 | 服务端失败表现 | 源码 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| M-1 | `HELLO=1` | radio → client | `{u32 version, u8 channel, u8 width_mhz, u8 reserved[2]}` | 固定 8 | — | 写失败 → 关连接、回 accept | `radio_link.h:27-32`；`main.cpp:521-535` |
| M-2 | `RX=2` | radio → client | `radiotap(10) + 802.11 frame` | 10 + N，N≥24，总 ≤16384 | — | 见 §8 队列 | `main.cpp:188-232` |
| M-3 | `TX=3` | client → radio | `radiotap + 802.11 frame` | ≤16384（不透明） | **无** | `send_packet()` 返回 false 只加计数 | `main.cpp:637-642` |
| M-4 | `SET_CHANNEL=4` | client → radio | `u8 channel` | 必须 1 | **无** | 抛异常 → `shutdown(client)` 断连 | `main.cpp:643-670` |
| M-5 | `SET_BSSID_FILTER=5` | client → radio | `u8[6] bssid`，全 0 = 清除 | 必须 6 | **无** | 无（纯用户态，不失败） | `main.cpp:671-692` |
| M-6 | `SET_ADDRESS=6` | client → radio | `u8[6] own_mac` | 必须 6 | **无** | `SetStationIdentity` 返回 false 只 warn | `main.cpp:693-717` |

方向约定（源码事实）：
- 客户端**不得**发 `HELLO`：收到就静默忽略（`main.cpp:718-719`）。
- 未知类型 → warn 后继续（`main.cpp:720-723`）。
- **尺寸不符会落进「未知类型」分支**：因为 `SET_CHANNEL/BSSID/ADDRESS` 的分支条件都带 `payload.size()==N`（`:643-644`、`:671-672`、`:693-694`），例如 2 字节的 SET_CHANNEL 会打出 `unknown message type 4 length 2` 并被丢弃，**不会断连、不会报错**（静态推断，由条件结构直接得出）。

### 3.3 HELLO 的语义细节（容易踩）

- **每个连接只发一次，且在 accept 成功后立刻发**（`main.cpp:470`、`:521-535`），此时 USB bring-up 早已完成（`:365-376` 在 listen 之前），所以「连上」就意味着 radio 已就绪。
- `version` 恒为 `3`；服务端**不校验客户端版本**，也**没有版本协商/降级**（全文无相关分支）。
- `channel` 是**当前**信道：`channel` 变量在 `SET_CHANNEL` 时被更新（`:660`），所以同一进程第二个客户端收到的 HELLO 会是新信道。
- `width_mhz` 是**启动参数原值**，不是生效值：`width_from_mhz()` 把不认识的值一律映射成 20 MHz（`:76-84`），但 HELLO 里发的是 `static_cast<uint8_t>(width_mhz)`（`:521-522`）。即「请求 33 MHz → HELLO 报 33、实际 20」。
- `reserved[2]` 写 0（`:522` 的 `{0, 0}`）。

### 3.4 每条消息的同步性（谁阻塞谁）

| 消息 | 处理位置 | 同步性 | 阻塞后果 |
| --- | --- | --- | --- |
| M-3 TX | 协议线程内联调用 `radio->send_packet()`（`:638`） | **同步**（提交到驱动返回才继续） | 慢帧会推迟后续所有消息（含 SET_CHANNEL）的解析；协议线程没有队列 |
| M-4 SET_CHANNEL | 协议线程内联 `FastRetune()`（`:659`） | **同步**，且跨频段回退到完整重调 | 期间不收新消息；RX 线程不受影响（仍在下发 RX 消息） |
| M-5/M-6 | 协议线程内联，只改用户态结构体/调用一次 arm | 同步但极快 | — |
| M-2 RX | USB 回调线程 → `OutQueue` → 独立 writer 线程 | **异步推送** | 慢客户端只影响队列（§8），不阻塞 USB RX 环 |

**结论**：整条协议是「命令单向、无回执、RX 单向推送」。客户端只能通过「后续能不能收到帧 / 连接是否被断 / radio 日志」来判断命令是否生效。

### 3.5 协议里【没有】的东西（源码事实）

- 没有 ACK/回执消息类型；没有错误消息类型；没有 GET 查询（读不到信道/宽度/状态）。
- 没有 TX status（`docs/PHASE0_AUDIT.md:67` 明确写「管道 v3 没有独立 TX-status 消息类型」）。
- 没有心跳/保活；TCP 自身保活未开启。
- 没有分片/重组，没有长度协商（除 16384 上限）。
- 没有鉴权：任何本机进程只要连上 49876 就能注入帧（安全边界仅靠 `SO_EXCLUSIVEADDRUSE` + 端口占用，`:397-402`）。

---

## 4. radiotap 契约

### 4.1 RX：服务端自己拼的 10 字节 radiotap（源码事实，`main.cpp:213-225`）

| 偏移 | 长度 | 字段 | 实际写入 |
| --- | --- | --- | --- |
| 0 | 1 | radiotap version | 0（vector 值初始化） |
| 1 | 1 | pad | 0 |
| 2 | 2 | it_len（LE） | 10 |
| 4 | 4 | it_present（LE） | `0x00000022` = bit1(Flags) + bit5(dBm antenna signal) |
| 8 | 1 | Flags | `0x10` 当 `RxAtrib.fcs_present` 为真，否则 `0x00` |
| 9 | 1 | dBm antenna signal（int8） | `-110 + RxAtrib.rssi[0]`，按 `int8_t` 截断 |
| 10 | N | 802.11 帧 | `Packet.Data` 原样拷贝 |

- 常量：`kRadiotapBytes = 10`、`kRadiotapPresent = (1u<<1)|(1u<<5)`、`kRssiFloorDbm = -110`（`main.cpp:56-58`）。
- dBm 换算依据：`docs/RADIO_CONTRACT.md:67` 记录 devourer `FrameParserJaguar2.h:256` 注释「dBm = value - 110」（**文档级证据**，devourer 源码不在快照内）。
- `0x10` 在 radiotap Flags 里是「帧尾带 FCS」。**是否真的有 FCS 取决于 `Packet.Data` 是否已去掉 4 字节 FCS，本快照无法判定**（§15）。
- 不写 TSFT、不写 Rate、不写 Channel、不写 Antenna，所以客户端**拿不到**每帧速率/带宽/天线信息——这些只在 radio 本地日志里（`main.cpp:604-619` 的 `rate/bw/sgi`），不上线。

### 4.2 TX：完全不解析（源码事实）

- 协议线程把整段 payload（含 radiotap）直接交给 `radio->send_packet(payload.data(), payload.size())`（`main.cpp:637-642`），**没有**校验头、没读 rate/width、没有最短长度检查。
- devourer 一侧要求载荷必须以 radiotap 开头：`docs/RADIO_CONTRACT.md:29`（「与 devourer `send_packet()` 的要求一致（必须以 radiotap 开头）」）。radiotap 里的速率/带宽字段是否被 devourer 采用，**本快照无法确认**；能确认的只有服务端在 bring-up 后用 `SetTxMode()` 设了一个**全局**发送模式，默认 `1M`（`main.cpp:379-385`），可用 `AIRBRIDGE_TX_RATE` 覆盖。
- 参考客户端就是这么发帧的：从 devourer 的 tx demo 里剥注释取前 10 字节当 radiotap，其余当帧，`send(sock, 3, rt+body)`（`tools/radio_link_client.py:70-85,173-181`）。注意该文件记录了一个历史坑：把 C 注释里的 `0x40 0x00` 当成帧字节会让帧整体错位（`docs/RADIO_USB.md:23-25`）。

### 4.3 一次 RX 消息的完整字节示例（源码事实推得）

```
00       01 00       00 00       1a 00 00 00   ← type=2, reserved=0, length=26
0a       00           22 00 00 00  10  9c       ← radiotap: ver0,pad0,it_len=10,present=0x22,flags=0x10,dBm=-100
xx ... 24 字节 802.11 帧 ...                    ← Packet.Data
```

（`length = 10 + frame.size()`；`main.cpp:213-217`）

---

## 5. 帧长、最小帧、分片与聚合

### 5.1 长度上限（源码事实）

| 位置 | 规则 | 超限行为 |
| --- | --- | --- |
| 客户端→radio 的任意消息 | `header.length > 16384` → `error` 日志 + **break**（断连，radio 继续 accept 下一个客户端） | `main.cpp:626-630` |
| radio→client 的 RX | 组包后 `message.size() > 8 + 16384` → 丢弃 | `main.cpp:226-229` |
| 有效 802.11 帧上限 | `16384 - 10 = 16374` 字节（RX 方向） | 同上 |
| 802.11 帧下限 | `< 24` 字节 → 丢弃 | `main.cpp:198-201` |
| TX 侧下限 | 无检查；0 长度会把空 vector 的 `data()` 传进驱动 | `main.cpp:637-642`（静态推断：0 长度行为未定义） |

> 注意一个**计数错标**：RX 超长帧走的是 `g_rx_small.fetch_add(1)`（`:227`），与「帧太小」共用一个计数器。排查时不能只看 `small=` 判断小帧。

### 5.2 分片 / 聚合：本层没有，也不打算有

- **802.11 分片（Fragmentation）**：未观察到任何重组逻辑；收到的分片帧只按「≥24 字节」原样转发（`main.cpp:188-232` 全文无 fragment 判断）。
- **A-MSDU / A-MPDU（接收）**：未观察到本层拆包。`docs/RADIO_CONTRACT.md:9-13,42` 记录：8821C 没有接收方向硬件 BlockAck，因此这棵树上「接收退化为单 MPDU」；这是 **RTL8821CU 专属缺口 + 历史结论**，不能外推到 AX201。
- **A-MPDU（发送）**：`IRadio` 有 `SetAmpduMode`（`docs/RADIO_CONTRACT.md:41`），但本仓库**从未调用**（在 `src/` 下 grep `SetAmpduMode` / `GetTxStats` 零命中，只有文档提及）。
- 802.11 帧本身的最大长度（~2346）在本层不校验，交给驱动。

### 5.3 控制帧被系统性丢掉

`frame.size() < 24` 会丢掉：ACK(10)、CTS(10)、RTS(16)、PS-Poll(16)、CF-End(16)、BlockAckReq(20)。BlockAck(32) 能过尺寸关，但只会在聚合协商后出现。**对端（iPhone）收到的 ACK 是 radio 后端硬件发的，不是这条链路上的软件帧**（见 §9）。

历史硬件报告佐证：`evidence/radio-usb-run-rx.log:144` 记录 `rx cb=349 crc=26 small=12 queued=311 drop=0`——12 个「small」就是被丢掉的小帧/控制帧。

---

## 6. 超时、错误与退出码

### 6.1 radio 侧没有任何 socket 超时（源码事实）

- 没有 `SO_RCVTIMEO` / `SO_SNDTIMEO` / `select`；`recv_exact` 是死等（`main.cpp:115-124`），writer 的 `send_all` 也是死等（`:105-113`）。
- 因此：客户端「连上但不发消息」会让协议线程永远阻塞在 `recv_exact`，**radio 不会再接受第二个客户端**，但 RX/统计线程照常跑（静态推断）。这是可用性缺陷，不是安全边界。
- 收尾时靠 `shutdown(client, SD_BOTH)` 唤醒阻塞的 writer（`:773-774`）。

### 6.2 命令失败的表现（源码事实）

| 失败 | 表现 |
| --- | --- |
| `send_packet` 返回 false | 只 `++tx_failed`，客户端**完全无感**（`:637-642`） |
| `FastRetune` 抛异常 | `error` 日志 → `shutdown(SD_BOTH)` → 断连（`:664-670`）。**进程继续监听、继续用「假设的信道」服务下一个客户端**（静态推断：没有停工/重建状态） |
| `SetStationIdentity` 返回 false | `warn` 一次，继续跑（`:714-716`） |
| HELLO 写失败 | 关连接、`StopRxLoop`、回 accept（`:525-533`） |
| 客户端消息超长 | 断连（`:626-630`） |
| 收到字节流中断（EOF/错误） | 退出消息循环 → 正常收尾 → 回 accept（`:623-625`） |

### 6.3 进程退出码（源码事实）

`run()` 的返回值，`main()` 直接返回（`main.cpp:812-828`）：

| 码 | 含义 | 行号 |
| --- | --- | --- |
| 0 | 停止事件在任何阶段触发；或正常收尾 | `:272`、`:304`、`:363`、`:807`（`exit_code` 默认 0） |
| 1 | `WSAStartup` 失败 / `libusb_init` 失败 | `:276-286` |
| 2 | 找不到 `VID:PID` 设备 | `:291-297` |
| 3 | claim/reset 失败 | `:318-324` |
| 4 | `CreateRadio` 失败（芯片支持没编进去） | `:340-347` |
| 5 | `InitWrite`（bring-up）失败 | `:365-375` |
| 6 | socket/bind/listen 失败 | `:387-417` |
| 7 | 收尾时 RX 线程卡死、只能先停设备；或 `std::_Exit(7)` 直接退出 | `:765`、`:781` |

> **码 2 撞车**：命令行参数非法也返回 2（`:819-824`），与「没有设备」同码。监管无法只靠退出码区分这两种情况（静态推断）。

---

## 7. 生命周期

### 7.1 启动顺序（源码事实，`run()`）

1. 记录启动时刻；建 Logger，级别由 `AIRBRIDGE_LOG_LEVEL`（默认 info，`warn` 可选）。
2. **先打开两个停止句柄**（`:256-273`）：
   - 事件 `Local\DropBridgeRadioStop`（`OpenEventW(SYNCHRONIZE)`）；
   - 父进程句柄：`AIRBRIDGE_PARENT_PID` → `OpenProcess(SYNCHRONIZE)`。
   - 为什么这么早：bring-up 要 40–120 s 且不可中断，句柄晚开会漏掉「父进程已退出」。
3. `WSAStartup`（`:275-279`）。
4. `libusb_init` → 按 `AIRBRIDGE_VID/AIRBRIDGE_PID`（默认 `0bda:c820`）打开设备（`:281-297`）。
5. `find_wifi_interface()` → claim + reset（`claim_interface_reset_reopen`；`AIRBRIDGE_SKIP_RESET=1` 时改用 `claim_interface_then_reset`）（`:307-324`）。历史记录：完整 reset 是重复 TX 的必要条件（`docs/PLAN.md:31`）。
6. 构造 `WiFiDriver` + `DeviceConfig{rx.enable_with_tx=true, rx.keep_corrupted=true, tx.retry_limit=N, tuning.fastretune_fw=N, tuning.fastretune_wait_ms=20}` → `CreateRadio()`（`:326-339`）。
7. `InitWrite(SelectedChannel{channel, offset, width, 0})`（`:349-366`）——**这一段是 40–120 s 的 bring-up**（`docs/RADIO_USB.md:29`）。
8. `SetTxMode(parse_tx_mode_str(AIRBRIDGE_TX_RATE 或 "1M"))`（`:379-385`）。注释说明：不带 rate 的帧可能落到不可用默认值而永远发不出去。
9. 建 TCP listener、`SO_EXCLUSIVEADDRUSE`、`bind 127.0.0.1:port`、`listen(1)`（`:387-418`）。
10. 起停止监听线程（等两个句柄，触发就 `closesocket(listener)`）（`:423-432`）。
11. **向 stderr 打印就绪行** `radio: listening on 127.0.0.1:<port>`（`:434`）——监管靠这一行判就绪（`Program.cs:939`）。
12. 进入 accept 循环。

### 7.2 每个客户端的周期（源码事实）

```
accept
  → TCP_NODELAY
  → 发 HELLO（8+8 字节）
  → client_ready = true
  → 起 RX 线程（radio->StartRxLoop(on_rx)）
  → 起 writer 线程（OutQueue → socket）
  → 起 stats 线程（每 5 s 一行日志，含 GetThermalStatus）
  → 阻塞读消息循环
  → 客户端断开/超长/换台失败 → 停 stats → client_ready=false → StopRxLoop
  → 有界等待 RX 线程（最多 2 s）→ 必要时 radio->Stop() → 再等 2 s
  → queue.stop() → shutdown(socket) → join writer → closesocket
  → （若中途 Stop 过设备：exit 7，退出进程，逼监管重启整链）
  → 否则回到 accept，等下一个客户端
```

- 每个客户端迭代会**清零全部 RX 计数**（`:450-456`）——日志里的计数只覆盖当前连接。
- RX 线程**在 accept 之后才启动**，注释解释：提前启动会被 `StartRxLoop()` 清停止标志的动作弄丢停止请求（`:464-468`）。
- 统计线程 5 s 一跳（50×100 ms，`:577-583`），读 `g_peer` 采样 + 芯片温度（`GetThermalStatus`，异常只 warn，`:592-597`）。

### 7.3 停止/退出（源码事实）

- 停止信号来自：事件 `Local\DropBridgeRadioStop` **或** 父进程句柄 signal（`WaitForMultipleObjects`，任一等）。
- 收尾顺序（`:786-807`）：停 stats → join writer → `radio->Stop()`（若之前没停过）→ `radio.reset()`（析构）→ `closesocket(listener)` → `libusb_release_interface` → `libusb_close` → `libusb_exit` → `WSACleanup`。
- 卡死逃生：RX 线程 2 s 内不返回 → `radio->Stop()` 逼它返回；再等 2 s 仍不返回 → `detach` + `_Exit(7)`（`:735-767`）。注释说明理由：那个线程还引用着本迭代的 queue/state/radio，不能安全析构。
- 为什么不用 `TerminateProcess`：注释记录历史硬件现象——强杀会把芯片卡在 USB 传输中间，「until it is physically replugged」（`:242-255`，历史硬件报告）。

### 7.4 监管（生产客户端）如何驱动 radio（源码事实，`src/supervisor/Program.cs`）

| 行为 | 细节 | 行号 |
| --- | --- | --- |
| 启动参数 | `"<channel> <width>"`（默认 149 / 20，由 `RadioArguments` 决定） | `:374` |
| 环境变量 | `AIRBRIDGE_LOG_LEVEL=warn`（可由 `AIRBRIDGE_RADIO_LOG` 提升为 info）、`AIRBRIDGE_LINK_STATS=1`、`AIRBRIDGE_FASTRETUNE_FW=2`、`AIRBRIDGE_PARENT_PID=<自己 PID>` | `:919-938` |
| 就绪判据 | stdout/stderr 出现 `listening on 127.0.0.1:49876` | `:939` |
| 就绪超时 | 180 s（`StartAll(180, ...)`） | `:2497`、`:3645` |
| 停止 | 先 `SignalRadioStop()`（置事件），**等 15 s**，仍未退才 `Kill()` | `:308-333` |
| 进程组 | radio **故意不进** `ChildJob`（kill-on-close 作业对象），因为 TerminateProcess 会卡芯片 | `:245-249` |
| 残留回收 | 下次启动只杀「本包目录下」的同名进程 | `:853-888` |
| 日志契约 | 从 radio 的 5 s 统计行里解析 `peer frames=N` 与 ` fps=`；用于速率告警 | `:534-583`、`:2553-2609` |
| 假死判据 | radio 日志静默 ≥30 s → 重启整链；3 分钟内第二次 → 提示拔插 | `:2611-2645` |
| 进程死亡 | 任一子进程退出 → 重启整链（receiver 例外） | `:2647-2672` |

**这意味着换后端时必须满足的运维契约（静态推断，但由代码直接决定）：**
1. 必须在 stderr 打 `listening on 127.0.0.1:<port>`（端口号要匹配监管指定的 49876）。
2. **有客户端连接时**必须每 ~5 s 输出一行包含 `peer frames=<int>` 和 ` fps=<float>` 的日志（无帧也要打，计数为 0），否则速率看门狗失效、且会被判假死。注意统计线程是在 accept 之后才启动的（`main.cpp:569-577`），所以「还没客户端」的窗口内是允许静默的——但如果 awdld 一直不连，监管仍会在 30 s 后重启整链。
3. 必须响应 `Local\DropBridgeRadioStop` 与父进程退出，并在 15 s 内干净退出。
4. 不可恢复错误必须**以非零码退出**（监管重启整链），不能挂着不退。

### 7.5 重连语义

- **radio 支持客户端重连**：accept 循环保持设备已初始化，不需要重新 bring-up（`main.cpp:439-441`；历史硬件报告：`docs/RADIO_USB.md:18` 实测连续两个客户端都能收到 HELLO）。
- **桥不支持重连**：`radio_pipe_bridge` 只在启动时 `connect_tcp()`（120 次 ×250 ms），之后任一方向断开就整进程退出（`radio_pipe_bridge.cpp:24-39`、`:146-186`）。所以 radio 若中途重启，awdld 侧会看到管道断开，监管重启整链，而不是桥自动重连。
- 客户端断开后 radio 会停 RX 线程，等下一个客户端（`:735-736`、`:784`）。

---

## 8. 队列与背压

### 8.1 RX 方向（radio → client）

- `OutQueue`：`std::deque<std::vector<uint8_t>>` + mutex + cv，**上限 256 条**（`main.cpp:126-161`，常量 `kMaxQueued = 256` 在 `:156`）。
- `push()` 满时**丢最旧的一条**（`pop_front` 后 push_back），返回「是否丢过」，RX 回调只把它计入 `g_rx_dropped`（`:131-138`、`:230`）。
- 设计意图写在注释里：USB RX 回调**绝不允许**被慢客户端阻塞（`:126-128`）。
- writer 线程阻塞式 `send_all()`；TCP_NODELAY 已开（`:517-519`）；没有设置 `SO_SNDBUF`，也没有发送超时。
- **背压对客户端不可见**：没有丢帧通知、没有序列号、没有计数上线；只有 radio 本地日志（`:598-619`）。

### 8.2 TX 方向（client → radio）

- 没有队列：协议线程读完一条就同步提交（`:637-642`）。
- 因此 TX 的「背压」体现为**TCP 窗口 + 协议线程阻塞**：客户端连续灌帧时，radio 处理不过来会自然让 `recv` 变慢，TCP 窗口收缩；不存在驱动侧队列深度参数。
- TX 失败不重试、不回传（`tx_failed` 仅日志）。

---

## 9. ACK 与重试由谁负责

### 9.1 三层责任划分（源码事实 + 文档级证据）

| 层 | 谁负责 | 证据 |
| --- | --- | --- |
| `radio_link` 传输可靠性 | **TCP**（本机 loopback），无应用层 ACK/重传 | `main.cpp:623-635` 只做 framing |
| 802.11 单播 ACK（对端等我们回 ACK） | **网卡硬件**，前提是 station identity 已 arm | `main.cpp:693-717` 调 `SetStationIdentity(own, bssid)`；`docs/RADIO_USB.md:17` |
| 802.11 发送重试（我们发、没被 ACK） | **网卡硬件 ARQ**，重试次数 = `tx.retry_limit` | `main.cpp:330-333`（`AIRBRIDGE_RETRY_LIMIT`，默认 7，钳 0..63） |
| AWDL 层重传/调度 | **awdld（OWL）**，不在本仓库 | `docs/STALL_DIAGNOSIS.md:47-49` |
| TX 成功与否的判定 | **没有**。`tx_sent` 只表示 `send_packet()` 返回 true | `docs/STALL_DIAGNOSIS.md:47-49` 原文：「radio 的 TX 计数只表示 `send_packet` 返回成功，未报告对端空口 ACK」 |

### 9.2 SET_ADDRESS 的隐藏顺序依赖（静态推断，重要）

```cpp
} else if (header.type == RADIO_LINK_SET_ADDRESS && payload.size() == 6) {
    ... 存 own ...
    if (have_bssid) {                       // ← 只有此刻 BSSID 已存在才 arm
        radio->SetStationIdentity(own_mac, bssid_mac);
    }
}
```

`main.cpp:693-717`。也就是说：

- 先 `SET_BSSID_FILTER` 再 `SET_ADDRESS` → identity 被 arm（正确顺序）。
- 先 `SET_ADDRESS` 再 `SET_BSSID_FILTER` → **永远不会 arm**：`SET_BSSID_FILTER` 分支（`:671-692`）只改结构体，不重试 `SetStationIdentity`。
- 后果：硬件不回 ACK → 对端 ARQ 停摆/退避。这是一个**协议层没有文档化的调用顺序约束**，客户端必须照做。

补充约束（历史硬件报告，`docs/RADIO_USB.md:17`）：BSSID 必须是**单播**（首字节偶数）、非零、且与 own 不同，否则 `SetStationIdentity` 会拒绝。本仓库**没有**在 radio 侧做这些校验（`main.cpp:693-717` 无检查），拒绝只表现为一行 warn。

### 9.3 空口 ACK 本身仍未验证

`docs/RADIO_USB.md:17,30` 明确记录：`SetStationIdentity` 已 armed，但「空口 ACK 行为仍未验证（需要 iPhone 或第三台观察设备）」。`docs/PHASE0_AUDIT.md:127` 记录 `adapter.caps` 里 `ack_responder=0 / station_mode=0 / tx_retry_limit=0`（能力声明）。**不要把「代码里 arm 了」当成「空口确认过」。**

---

## 10. RX 过滤、monitor 模式、管理帧 / Action 帧

这一节按「源码里到底有什么」逐条回答，缺的直接写「未观察到」。

### 10.1 接收过滤：只有用户态一层，按 addr3

源码事实（`main.cpp:188-232`）：

```cpp
if (state.has_bssid && memcmp(frame.data()+16, state.bssid.data(), 6) != 0) {
    ++g_rx_filtered; return;                 // 偏移 16 = 802.11 头 addr3
}
```

- 过滤字段 = **addr3**（3 地址帧里是 BSSID/SA 组合位；对管理帧是 BSSID）。
- `SET_BSSID_FILTER` 全 0 → 关闭过滤（`:673-684`）。
- 过滤在**用户态**、在 `client_ready` 之后、在 CRC/长度检查之后。
- **没有**任何硬件 RX 过滤寄存器的写入出现在本仓库（全仓未观察到寄存器操作；`RCR` 只出现在 devourer 的日志行里，见下）。

### 10.2 硬件接收配置：本仓库没有，只有日志痕迹

- 本仓库唯一的「接收使能」是 `radio->StartRxLoop(cb)`（`:543`）与 `radio->StopRxLoop()`（`:478`、`:736`）。
- 历史硬件报告：`evidence/radio-usb-run-rx.log:124` 有 devourer 的行 `RX enabled (CR=0x06ff, RCR=0xf000032f, IGI=0x40)`。这说明**devourer 在使能 RX 时写过 RCR/CR**，但写寄存器的代码不在本快照内，本仓库也无法改变它。
- 因此：「radio 如何设置接收过滤」的准确答案是——**radio 不设置硬件过滤；它只做 addr3 软件过滤，硬件过滤由 devourer 的 RX 使能路径固定配置（具体位含义无法在本仓库核实）**。

### 10.3 是否依赖 monitor 模式：未观察到显式 monitor 请求

- 全仓 grep `monitor/Monitor` 只命中三类：`Monitor-Soak.ps1`（监控脚本）、`SetMonitorChannel`（信道设置函数名）、文档里的「不要以开启 monitor mode 代替通过」（`docs/PLAN.md:35`）。
- radio 启动只调 `InitWrite(SelectedChannel)`（`:366`）与 `StartRxLoop()`（`:543`）；没有任何 `monitor` 开关、没有 `NL80211_IFTYPE_MONITOR` 之类概念、没有「promiscuous」字样。
- 按现有证据只能说：**它把芯片置于「固定信道 + RX 使能」的可收帧状态**；是否等价于 802.11 monitor（收所有 BSS 的管理帧）取决于 devourer 的 RCR/MAC 配置，本仓库无法证明。
- 事实边界：它能收到**自己信道上的** beacon/管理/Action 帧（`docs/RADIO_USB.md:10` 记录 RX 含真实 beacon；`evidence/awdld-149.log:25` 记录 `rx action 33` 增长）。

### 10.4 管理帧 / Action 帧能不能收到：能，且被原样转发

- `on_rx` **没有** type/subtype 过滤：只要求 `pkt_rpt_type == NORMAL_RX`、无 CRC 错、长度 ≥24（`:192-201`）。所以管理帧（beacon、probe、action）只要 ≥24 字节就照转。
- 硬件侧证据（历史硬件报告）：
  - `docs/RADIO_USB.md:10`：RX 10 秒 311 帧、含真实 beacon。
  - `evidence/awdld-149.log:25`：awdld 自己的计数 `rx action 33, data 0` 在增长——awdld 只能从 radio 拿帧，这证明 **Action 帧确实穿过了 radio 并上行**。
  - `evidence/sockets-awdld.log:52-134`：`rx action` 与 `data (joined)` 同时增长，说明数据帧/聚合也上行。
- 控制帧（<24 字节）被丢（§5.3），所以软件看不到 ACK/CTS/RTS。

### 10.5 C2H / 固件事件不会上行

`on_rx` 只放行 `NORMAL_RX`（`:192`），devourer 会把 C2H 标成 `C2H_PACKET`（`patches/devourer-airbridge.patch:225-228`），因此固件事件/换台完成通知**不会**出现在 radio_link 上，只在 radio 内部被用于 FastRetune 确认（补丁 `:63-88`）。

---

## 11. 分层：哪些是 RTL8821CU 专有，哪些是硬件无关

### 11.1 后端必须实现的接口面（`main.cpp` 对 devourer 的全部调用点）

| 接口面 | 调用点 | 语义要求 | 可移植性 |
| --- | --- | --- | --- |
| `devourer::find_wifi_interface(handle)` | `:307`、`:316` | 在多接口复合设备里找出 Wi-Fi 接口号 | **USB/厂商专有** |
| `claim_interface_then_reset` / `claim_interface_reset_reopen` | `:311-317` | 独占接口 + USB reset + 重新打开 | **USB 专有** |
| `WiFiDriver::CreateRadio(handle, ctx, lock, config)` | `:326-339` | 按芯片建 IRadio | **厂商专有**（工厂里按 ChipVariant 分支） |
| `DeviceConfig{rx.enable_with_tx, rx.keep_corrupted, tx.retry_limit, tuning.fastretune_fw, tuning.fastretune_wait_ms}` | `:327-338` | RX 与 TX 并发、保留 CRC 错帧、硬件重试次数、固件换台开关 | 前两项通用；后三项是**芯片/固件专有** |
| `IRadio::InitWrite(SelectedChannel)` | `:366` | 固件下载 + PHY/RF 表 + 校准 + 定信道 | **厂商专有** |
| `IRadio::SetTxMode(parse_tx_mode_str(...))` | `:384` | 全局发送速率/模式 | 语义通用、实现专有 |
| `IRadio::StartRxLoop(cb)` / `StopRxLoop()` / `Stop()` | `:543`/`:478,:736`/`:390,:411,:496,:744,:797` | RX 生命周期 | 语义通用、实现专有 |
| `IRadio::send_packet(buf,len)` | `:638` | 提交一帧 radiotap+802.11 | 语义通用、实现专有 |
| `IRadio::GetSelectedChannel()` / `FastRetune(ch)` | `:645`/`:659` | 读当前信道 / 快速换台 | **厂商专有**（固件 H2C 路径） |
| `IRadio::SetStationIdentity(own,bssid)` | `:714` | arm 硬件 ACK 应答器 | **厂商专有** |
| `IRadio::GetThermalStatus()` | `:594` | 芯片温度 | **厂商专有** |
| `Packet` / `RxAtrib`（`pkt_rpt_type, crc_err, fcs_present, rssi, physt, drvinfo_sz, data_rate, bw, sgi`） | `:192-224`、`peer_telemetry.h:19-36` | 每帧接收元数据 | 字段语义通用，来源专有 |
| `SelectedChannel{Channel, ChannelOffset, ChannelWidth, ...}`、`CHANNEL_WIDTH_*` | `:76-84`、`:349-351` | 信道/带宽/主信道偏移 | **Jaguar2 语义专有**（`ChannelOffset` 是 8821C 的主信道索引） |
| `UsbDeviceLock` | `:308` | 跨进程 USB 互斥 | **USB 专有** |

**这 14 个面里，只有 3 个是真正硬件无关的**：`send_packet(帧字节)`、`StartRxLoop(回调)`、`Stop/StopRxLoop`。其余全部绑定 USB、具体芯片或厂商固件。

### 11.2 RTL8821CU / 厂商固件专有清单（换后端时全部作废）

| 专有项 | 证据 |
| --- | --- |
| USB 复合设备、MI_02 绑 WinUSB、VID/PID `0bda:c820` | `main.cpp:288-297`；`docs/PHASE0_AUDIT.md:103-107`；`docs/BINDING_RUNBOOK`/`packaging/driver/airbridge-winusb.inf` |
| claim interface + USB reset + reopen（重复 TX 的前提） | `main.cpp:307-324`；`docs/PLAN.md:31` |
| 固件下载（`dlfw_end_flow`，FW ready 轮询 0xC078，最长 1 s） | `patches/devourer-airbridge.patch:130-168` |
| EFUSE / PHY 表 / 固件 | `docs/PHASE0_AUDIT.md:28`（`HalJaguar2.cpp`、`hal8821c_fw.c`、`Phy8821cTables.cpp`） |
| 芯片 ID（SYS_CFG2 0x00FC=0x09）/ cut / 1T1R | `HANDOFF.md:59-61`；`docs/PHASE0_AUDIT.md:109` |
| BB/RF 校准与 IQK（"TX/RX path re-asserted post-IQK"） | `evidence/rx-first.log:84-89` |
| H2C `0x1D`（FastRetune 固件命令）与 C2H `0x10`（CUR_CHANNEL） | `main.cpp:334-337`；`patches/devourer-airbridge.patch:16-38,63-88` |
| 功率跟踪 `pwr_track` / `update_pwr_track_channel` / TXAGC | `patches/devourer-airbridge.patch:170-215` |
| coex（`coex_wlan_only`）与天线授予 | `patches/devourer-airbridge.patch:243-261` |
| 硬件重试寄存器（`tx_retry_limit`）与 ACK 应答器 | `main.cpp:330-333`；`docs/RADIO_CONTRACT.md:40,65` |
| `ChannelOffset`（80 MHz 主信道索引 {0,+6,+2,-2,-6}） | `main.cpp:86-103` |
| `SetMonitorChannel`（完整换台） | `main.cpp:657-659`；`docs/RADIO_CONTRACT.md:44` |
| 芯片温度原始读数（`thermal.raw / delta`，无摄氏度换算） | `main.cpp:592-608`；`docs/STALL_DIAGNOSIS.md:22` |
| 1T1R / 单空间流、80 MHz 不可用等能力上限 | `evidence/rx-first.log:24`（`adapter.caps`）；`docs/FINAL_PLAN.md:80` |

### 11.3 硬件无关、可原样复用的清单

| 可复用项 | 位置 | 说明 |
| --- | --- | --- |
| `radio_link.h`（MIT） | `src/radio_usb/radio_link.h` | 双端共用；换后端不用改 |
| TCP 服务端骨架（bind/listen/accept 循环/`SO_EXCLUSIVEADDRUSE`/`listen(1)`） | `main.cpp:387-418`、`:449-516` | 与硬件无关 |
| HELLO 发送 | `main.cpp:521-535` | 只有 `channel/width` 取自硬件状态 |
| 10 字节 radiotap 拼装 | `main.cpp:213-225` | 只要后端能给出 `rssi[0]/fcs_present` |
| `OutQueue`（256、丢最旧） | `main.cpp:126-161` | 与硬件无关 |
| TX 同步提交语义 | `main.cpp:637-642` | 与硬件无关 |
| addr3 软件过滤 | `main.cpp:203-211`、`:671-692` | 与硬件无关（但依赖硬件把管理帧送上来） |
| 停止句柄 / 有界收尾 / 退出码框架 | `main.cpp:256-273`、`:735-807` | 与硬件无关 |
| 桥（字节泵） | `radio_pipe_bridge.cpp` 全文 | 完全硬件无关，可不动 |
| 监管与日志契约 | `Program.cs:534-583`、`:919-939`、`:2611-2645` | 只要求行格式，不要求硬件 |

---

## 12. AX201 后端最小能力清单

> 下列每一条都是**现有 `radio_link` 契约 + AWDL 使用方式**推出来的必要条件，不是 AX201 的实测结论。编号供主会话引用。

| ID | 能力 | 量化要求（由现有实现反推） | 对应现有实现 | AX201 侧状态 |
| --- | --- | --- | --- | --- |
| A-1 | 设备独占打开 | 单一进程独占无线适配器；外部 WLAN 服务不得并发管理 | `main.cpp:288-324` | 未知/本机未验证；Windows 上适配器默认归 WlanSvc |
| A-2 | 初始定信道 + 带宽 | 2.4 GHz（6）与 5 GHz（149/44）均可；20/40/80 MHz；启动即定 | `:349-366`、`:76-84` | 需要能强制驻留，非扫描式 |
| A-3 | 运行时换台 | 同步命令、毫秒级；同频段与**跨频段**都要；生产环境显式打开固件快路径（~2 ms vs ~90 ms，历史硬件报告） | `:643-670`、`:334-338`、`Program.cs:930-933` | 最大缺口，见 §13 G-3/G-4 |
| A-4 | 原始 802.11 接收 | 把该信道上的 mgmt/action/data 帧原样交上来，≥24 字节；带 CRC 错标记；**不得**转换为 802.3 | `:188-232`、`:543` | 需要 monitor 类接收，见 G-2 |
| A-5 | 每帧接收元数据 | RSSI（dBm）、FCS 是否存在、CRC 错、pkt_rpt_type；可选 rate/bw/sgi | `:192-224`、`peer_telemetry.h:19-36` | 部分可由 ETW/Netmon 提供，非注入同源 |
| A-6 | 原始 802.11 注入 | 发送 radiotap+802.11 帧，含管理/Action 帧与单播数据；0 长度不崩 | `:637-642` | 最大缺口，见 G-1 |
| A-7 | 发送速率控制 | 至少能设全局 legacy 速率（默认 1M）；按帧速率未知亦可接受 | `:379-385` | 需驱动侧支持，见 G-6 |
| A-8 | 硬件 ACK / station identity | 能让硬件对「发给自己的单播帧」回 ACK；可设 own MAC 与 BSSID；BSSID 单播/非零/异于 own | `:693-717`；`docs/RADIO_USB.md:17` | 最大缺口，见 G-5 |
| A-9 | 发送重试次数 | 0..63 可配（默认 7） | `:330-333` | 需驱动侧支持 |
| A-10 | RX 过滤 | 至少「全收」+「addr3 白名单」两种状态；软件实现即可，但硬件必须把帧交上来 | `:203-211`、`:671-692` | 依赖 A-4 |
| A-11 | 收发并发 | RX 环运行时可以 TX（不是半双工切换） | `:539-555` 与 `:637-642` 并行 | 需要驱动支持，未知 |
| A-12 | 生命周期 | 初始化（可 40–120 s）、干净停止、不楔死、无需拔插即可重开 | `:234-418`、`:735-807` | 需实测；AX201 无 USB 复位概念 |
| A-13 | 运维接口 | stderr 就绪行、5 s 统计行（含 `peer frames=`/` fps=`）、响应停止事件、非零退出码 | `:434`、`:577-622`；`Program.cs:939,534-583,2611-2645` | 纯软件，可由新后端实现 |
| A-14 | 协议壳 | `radio_link` v3 全部消息、10 字节 radiotap、16384 上限、256 队列 | §3/§4/§8 | 可直接复用现有代码 |
| A-15 | （可选）温度/链路遥测 | 仅写日志，不上线 | `:592-619` | 可不实现 |

---

## 13. 无法由现有 Windows 合法接口提供的能力（需驱动侧改动）

> 以下均为**静态推断 + 本机未验证**：没有查询本机驱动、没有调用 API、没有读 WDI 规范原文。措辞按「公开用户态接口模型」给出，供路线判断，不作为法律/技术定论。

| ID | 能力 | 为什么公开用户态接口给不了 | 要什么才可能 | 与契约的关系 |
| --- | --- | --- | --- | --- |
| G-1 | 原始 802.11 注入 | WLAN API（`wlanapi.dll`）只有扫描/连接/配置，没有注入；NDIS 轻量过滤驱动（LWF）在 802.3 层，看不到也发不出 802.11 帧 | 内核态 NDIS LWF/miniport 侧注入，或厂商提供注入 IOCTL（公开资料中不存在） | A-6 直接阻塞 |
| G-2 | Monitor/混杂接收 802.11 | Network Monitor（`DOT11_OPERATION_MODE_NETWORK_MONITOR`）是**可选**能力，且本身**只收不发**；普通 extSTA 模式只向上送 802.3 | 驱动暴露 monitor 模式 + 另一条注入路径 | A-4 与 A-6 同时阻塞 |
| G-3 | 强制信道/带宽驻留 | 无用户态 API 可把管理态适配器钉在指定信道/宽度；扫描是异步的（秒级）且会离开当前信道 | 驱动侧 OID/WDI 信道控制 | A-2/A-3 阻塞 |
| G-4 | 亚 10 ms 级换台（AWDL 时隙） | 即便能钉信道，用户态也没有「立即切到 X 信道并在 Y µs 后回来」的原语；扫描调度不可控 | 驱动/固件级信道切换 + 完成通知 | A-3 阻塞（AWDL 社会时隙依赖） |
| G-5 | 任意 own MAC + ACK 应答器 | 无公开 API 设置任意 MAC 或 arm 硬件 ACK 应答；station identity 由关联状态机持有 | 驱动侧 station 模式/地址配置 | A-8 阻塞 |
| G-6 | 每帧速率 + 硬件重试次数 | 无公开 API 指定注入帧的 MCS/legacy 速率或 ARQ 次数 | 驱动侧 TX 描述符控制 | A-7/A-9 阻塞 |
| G-7 | 与 WlanSvc 争用适配器 | WLAN 服务持有管理态适配器；用户态没有「接管但不关联」的模式 | 停用/接管服务 + 过滤驱动，或专用适配器 | A-1 阻塞 |
| G-8 | 固件 / EFUSE / 厂商 H2C-C2H | 固件由厂商驱动签名加载；没有公开的固件下载或厂商命令通道 | 厂商合作，基本不可行 | A-2/A-3/A-8 的底层依赖 |
| G-9 | 硬件级每帧 PHY 元数据 | 抓包方案（ETW/Netmon/Npcap）能给一部分，但与注入不同源、且不保证在目标信道上连续 | 驱动侧 RX 描述符 | A-5 降级 |

### 13.1 与本机硬件事实的交叉

- 主会话已验证：本机是 **Intel Wi-Fi 6 AX201，CNVio2，不是 USB 设备**。→ 本仓库 `libusb + WinUSB + VID/PID 0bda:c820 + claim interface` 整条路线（§11.2 前两项）**物理上不可用**，不是改 INF 能解决的。
- AX201 的 Wi-Fi 由 Intel 的 WDI 驱动 + Windows WLAN 服务管理；本仓库从未针对 Intel 做过任何适配（`docs/HARDWARE_INTAKE.md:83` 只把机器上的 Intel 网卡标为「非目标」，且型号写作 AX211，与本机 AX201 不同——历史记录，不可当本机事实）。
- **不得外推**：8821C 的 `adapter.caps`（1T1R、bw_max 80、fastretune=1、ack_responder=0）、~1 MB/s 吞吐、BlockAck 缺口、40–120 s bring-up、80 MHz 不可用，全部是 **RTL8821CU 历史硬件报告**，与 AX201 无关（§15.2 列了禁止外推清单）。

---

## 14. 路线判断与最大阻塞点

### 14.1 三条可选路线（按代价排序）

1. **保留 8821CU，不换后端**：契约已闭环，只需继续解决发现/稳定性问题。AX201 继续做本机 Wi-Fi。
2. **换一块支持 monitor+inject 的 USB 网卡**（不在本任务范围，仅列为对照）：能保留 `radio_link` 壳与大部分 `main.cpp`，只需替换 devourer 那一层。这是工程量最小的「换硬件」路线。
3. **在 AX201 上做内核侧驱动**：需要 NDIS LWF/厂商级支持来实现 G-1..G-6；工作量与不确定性远超现有项目，且 `radio_link` 壳能复用但下层要重写。

### 14.2 最大阻塞点（一句话）

**AX201 无法通过任何合法用户态 Windows 接口提供「原始 802.11 注入 + 受控信道驻留（毫秒级跨频段）+ 硬件 ACK/station identity 配置」这三件套；而这三件是 `radio_link` 契约里被隐式要求、AWDL 又离不开的。** 其中注入与 monitor 接收在 CNVio2 + Intel WDI 驱动的组合下无法由 WinUSB/libusb 路线绕开——现有 `radio_usb` 后端一行都不能直接复用。

### 14.3 如果仍要推进，先做的（合法、非硬件）判定实验

这些是**建议**，本次未执行、也未获授权：

1. 只读确认 AX201 的驱动/接口形态（设备栈、是否有 monitor 能力声明）——**需要另行授权**，本次未做。
2. 用最小原型验证「能不能在用户态拿到 802.11 帧」（纯抓包，不注入）——失败即证明 A-4 不可达。
3. 只有在 1、2 都通过后，才谈注入与信道控制（G-1/G-3/G-4）。

---

## 15. 未观察到 / 未验证清单（防止把推测写成结论）

### 15.1 本仓库中「未观察到」的东西

| 项 | 结论 |
| --- | --- |
| 硬件 RX 过滤寄存器写入 | **未观察到**（仓库内无寄存器操作；只有 devourer 日志行 `RCR=0xf000032f`） |
| monitor 模式请求 / promiscuous 开关 | **未观察到** |
| 802.11 分片重组 | **未观察到** |
| A-MSDU/A-MPDU 拆包（RX） | **未观察到** |
| `SetAmpduMode` 调用 | **未观察到**（IRadio 有，本仓库不调） |
| `GetTxStats` 调用 | **未观察到** |
| TX status 上行消息 | **未观察到**（文档亦确认不存在，`docs/PHASE0_AUDIT.md:67`） |
| 协议版本协商 / 鉴权 / 心跳 | **未观察到** |
| `AIRBRIDGE_HOP_SKIP_CROSSBAND` | **当前源码不存在**（只在 `WORK_LOG.md:1227`、`evidence/q15-follow-sequence.log:16` 等历史文档里出现） |
| 客户端↔radio 的错误码/重试 | **未观察到**（只有断连与日志） |

### 15.2 禁止外推到 AX201 的 RTL8821CU 历史结论

- 吞吐 ~1.1 MB/s、700–850 帧/s、CRC 比例、断流现象（`docs/STATUS.md:9`、`docs/STALL_DIAGNOSIS.md:8-34`）。
- 1T1R、`bw_max=80`、`fastretune=1`、`ack_responder=0`、`station_mode=0`、`tx_retry_limit=0`（`evidence/rx-first.log:24`）。
- 接收方向无硬件 BlockAck → 单 MPDU 上限（`docs/RADIO_CONTRACT.md:9-13,42`）。
- bring-up 40–120 s、`FW ready 0x80 != 0xC078` 重试、强杀楔死需拔插（`docs/RADIO_USB.md:29-32`、`main.cpp:242-255`）。
- 跨频段换台 ~2 ms（固件快路径）/ ~90 ms（完整路径）。
- 80 MHz 不可用、40 MHz 更慢（`docs/FINAL_PLAN.md:80`、`HANDOFF.md:115-116`）。

### 15.3 本次无法判断、必须看 devourer 源码或实测的点

1. `Packet.Data` 是否包含 4 字节 FCS（决定 radio 的 radiotap `0x10` 标志是否正确）。
2. `send_packet` 是否读取 TX radiotap 里的 rate/width（决定客户端是否需要精确填 radiotap）。
3. `FastRetune` / `SetMonitorChannel` 的真实耗时分布（决定 A-3 的量化门槛）。
4. `SetStationIdentity` 是否真的让硬件回 ACK（决定 A-8）。
5. `RCR=0xf000032f` 各位的过滤含义（决定「能不能收到别人的管理帧」的边界）。
6. `AIRBRIDGE_TX_RATE` 之外的速率能力（MCS/VHT/带宽）如何映射。

---

## 16. 复现指引（只读）

本文所有结论都可以用只读方式复核：

```powershell
# 1) 线协议定义
Get-Content C:\Github\DropBridge\repo\src\radio_usb\radio_link.h

# 2) radio 主体（按本文章节号定位行）
Get-Content C:\Github\DropBridge\repo\src\radio_usb\main.cpp | Select-Object -Skip 187 -First 46   # on_rx
Get-Content C:\Github\DropBridge\repo\src\radio_usb\main.cpp | Select-Object -Skip 622 -First 104  # 消息循环

# 3) 监管契约
Select-String -Path C:\Github\DropBridge\repo\src\supervisor\Program.cs -Pattern 'peer frames=|listening on 127.0.0.1:49876|DropBridgeRadioStop|AIRBRIDGE_'

# 4) 厂商专有边界
Get-Content C:\Github\DropBridge\repo\patches\devourer-airbridge.patch

# 5) 历史硬件报告
Get-Content C:\Github\DropBridge\repo\docs\RADIO_USB.md
Select-String -Path C:\Github\DropBridge\repo\evidence\rx-first.log -Pattern 'adapter.caps'
```

---

## 附录 A：消息字节表（可直接实现）

```
通用帧：
  offset 0  u16 type        LE
  offset 2  u16 reserved    = 0
  offset 4  u32 length      LE，仅载荷
  offset 8  payload[length]

M-1 HELLO (type=1, radio→client, length=8)
  +0  u32 version       = 3
  +4  u8  channel       当前信道
  +5  u8  width_mhz     启动参数原值
  +6  u8  reserved[2]   = 0,0

M-2 RX (type=2, radio→client, length=10+N)
  +0  u8  rt_version = 0
  +1  u8  rt_pad     = 0
  +2  u16 rt_len     = 10
  +4  u32 rt_present = 0x00000022
  +8  u8  rt_flags   = 0x10 if FCS present else 0
  +9  i8  rt_dbm     = (int8)(-110 + rssi[0])
  +10 u8  frame[N]   802.11（N≥24）

M-3 TX (type=3, client→radio, length≤16384)
  payload 与 M-2 的 +0.. 同构（radiotap + 802.11），radio 不解析

M-4 SET_CHANNEL (type=4, client→radio, length=1)
  +0 u8 channel

M-5 SET_BSSID_FILTER (type=5, client→radio, length=6)
  +0 u8 bssid[6]；全 0 = 清除

M-6 SET_ADDRESS (type=6, client→radio, length=6)
  +0 u8 own_mac[6]
```

## 附录 B：环境变量（radio 相关，源码事实）

| 变量 | 默认 | 作用 | 行号 |
| --- | --- | --- | --- |
| `AIRBRIDGE_CHANNEL` | 6 | 启动信道（argv[1] 优先） | `main.cpp:814` |
| `AIRBRIDGE_WIDTH` | 20 | 启动带宽 MHz（argv[2] 优先） | `:816` |
| `AIRBRIDGE_PORT` | 49876 | 监听端口（argv[3] 优先） | `:818` |
| `AIRBRIDGE_VID` / `AIRBRIDGE_PID` | `0x0bda` / `0xc820` | USB 设备匹配 | `:288-289` |
| `AIRBRIDGE_RETRY_LIMIT` | 7（钳 0..63） | `tx.retry_limit` | `:330-333` |
| `AIRBRIDGE_FASTRETUNE_FW` | 0（监管设 2） | 固件快路径换台 | `:337`；`Program.cs:933` |
| `AIRBRIDGE_TX_RATE` | `1M` | 全局发送模式 | `:382-385` |
| `AIRBRIDGE_NO_RX` | 关 | 跳过 RX 环（隔离 TX 测试） | `:463,539,554` |
| `AIRBRIDGE_SKIP_RESET` | 关 | 跳过完整 reset | `:825`、`:310-317` |
| `AIRBRIDGE_LOG_LEVEL` | info | `warn` 时降噪 | `:237-240` |
| `AIRBRIDGE_LINK_STATS` | 关（监管设 1） | 5 s 计数走 warn 级 | `:575-608` |
| `AIRBRIDGE_PARENT_PID` | 无 | 父进程句柄，用于干净退出 | `:258-261` |
| `AIRBRIDGE_RADIO_LOG` | — | **监管读**，透传成 `AIRBRIDGE_LOG_LEVEL` | `Program.cs:919-926` |

## 附录 C：退出码

见 §6.3。补充：`std::_Exit(7)` 是「RX 线程卡死时的最后逃生」，它跳过所有析构（`main.cpp:765`），所以那种情况下 USB 接口不会被 `libusb_release_interface` 释放——依赖进程退出由系统回收。

## 附录 D：换后端时的文件级改动面

| 文件 | 动作 |
| --- | --- |
| `src/radio_usb/radio_link.h` | **保留**（MIT，线协议不变） |
| `src/radio_usb/main.cpp` | 保留协议壳（§11.3），把 14 个 devourer 调用点换成新后端 |
| `src/radio_usb/radio_pipe_bridge.cpp` | **完全保留**（与硬件无关） |
| `src/radio_usb/peer_telemetry.h` | 保留逻辑，`Packet/RxAtrib` 字段名需随新后端适配 |
| `src/radio_usb/CMakeLists.txt` | 重写（现在是 8821C-only + `build/devourer-airbridge` 依赖） |
| `src/radio_usb/channel_completion_test.cpp`、`peer_telemetry_test.cpp` | 前者依赖 devourer 的 `ChannelSwitchCompletion.h`，需重写或删除 |
| `tools/radio_link_client.py` / `.dart` | 保留（客户端协议参考） |
| `src/supervisor/Program.cs` | 不改（只要新后端满足 §7.4 的日志/停止契约） |
| `packaging/driver/*`、`packaging/setup/*`（Zadig/WinUSB INF） | 全部作废（USB 专用） |

---

*本报告只做只读分析。未编译、未运行、未接触任何无线设备或驱动。*
