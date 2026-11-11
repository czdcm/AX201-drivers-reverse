# DropBridge AWDL 上层实现分析（只读）

- 日期：2026-11-11
- 分析对象：`C:\Github\DropBridge\repo`（官方 main 分支 ZIP 快照，commit `68519f5f4d703965e2db33674cdb4ba10eb33908`；不是 git 工作树；`upstream/` 未恢复）
- 主机目标：Windows + Intel AX201（CNVio2，非 USB）
- 本轮约束：只读；未修改仓库、未运行仓库脚本、未构建、未下载依赖、未安装软件、未操作驱动或无线设备
- 事实分级（全文统一）：
  - 【源码事实】仓库内可直接读到并给出 `文件:行号` 的代码/文档/补丁文本；
  - 【静态推断】由源码或日志推出、但缺少上游实现或运行时证据支撑；
  - 【历史记录】仓库文档里记录的过去实测结果（本人未复现）；
  - 【本机未验证】按本轮授权无法验证、需要真机或需要恢复 upstream 的点。

---

## 0. 结论摘要（先看这 10 条）

1. **AWDL 协议本体（邻居发现、同步、选举、时隙/信道调度）不在这个仓库里。** 它在 WinAWDL 的 `awdl/`（基于 OWL）里，而 `upstream/` 被 `.gitignore` 排除（`AGENTS.md:12`、`README.md:158`）。仓库里能读到的只有：三个补丁的 hunk、awdl_netd 的数据面、supervisor 的编排、以及证据日志。任何"OWL 实现了/没实现 availability window"的判断，本快照都无法静态证实。
2. **真正可跨后端复用的是"用户态 AWDL 数据面 + 应用层接缝"**：`src/awdl_netd`（lwIP IPv6/NDP、TCP 8771 代理、mDNS 5353 代理）、`patches/` 里 receiver 的代理模式与稳定实例 ID、`radio_link.h` v3 协议定义、`src/beacon` 蓝牙唤醒。这些与具体网卡无关。
3. **不可复用的是 radio 后端本身**：`src/radio_usb` 硬编码 `0bda:c820`（`src/radio_usb/main.cpp:288-290`）、依赖 devourer 的 RTL8821C 寄存器/firmware 路径。AX201 上这条路完全不存在。
4. **AWDL 上层对 radio 的契约是"帧级透明 + 自有 MAC + 可换台 + 硬 ACK"**：`radio_link` v3 只有 6 种消息（`src/radio_usb/radio_link.h:12-19`），但语义上要求 radio 能把 awdld 构造好的整帧 802.11（radiotap 前缀）原样发出去、把收到的整帧带 radiotap 上报、并接受逐时隙换台与自有地址布防。
5. **时序上最紧的是换台，不是数据通路**：跨频段换台从 65–90 ms 降到 **0.22–0.28 ms** 才能用（`docs/STATUS.md:68`、`evidence/awdl-sequence-and-fastretune.log:21-27`）。上层其余环节都是毫秒到秒级容忍（IPC 握手重试 200×100 ms、mDNS 0.5 s、看门狗 30 s）。
6. **AWDL 的地址是随机 MAC 派生的，且每次启动都变**：`patches/awdl-ipc-host.patch:117-127` 明确写 "awdld picks a new random AWDL MAC every start"，日志里 `AWDL address ce:99:e6:09:ba:8f`（`evidence/awdld-first.log:9`）。这与 AX201/WDI 的"端口上下文决定源地址"直接冲突（见 §5.4、§13）。
7. **AirDrop 接收链路有四道接缝**：mDNS(UDP 5353↔15353) → lwIP TCP 8771 → 本地明文 TCP 8771 → Python `ssl` 终止 TLS。TLS 由 Python 标准库做，证书是自签 RSA-2048 且 `BasicConstraints(ca=True)`（`patches/airdrop-identity.patch:39-41`）。
8. **发送方向"失败"是证书/信任问题，不是协议不可能**：发现、地址、端口、出站 TCP、TLS 握手全部走通，iPhone 用 TLS alert 拒绝自签证书（`docs/SEND_PATH.md:11-19`、`:79-100`；`docs/WORK_QUEUE.md:76` Q48）。这不构成"协议层面不能发"的证据，也不能反推 AX201 不能发。
9. **源码 ≠ 最后一次实测过的包**：最后完整编译打包是 Q50（2026-10-30），之后 Q59–Q67 只重编托盘，**Q68/Q69/Q70 只提交源码、从未编译**（`README.md:249`、`docs/STATUS.md:16`、`docs/WORK_QUEUE.md:96-98`）；且 `sources.lock.json` 与构建记录不一致（§10）。
10. **AX201 路线的第一道门槛不是 AWDL，而是"能不能由第三方用户态进程发出一个 802.11 管理帧并在用户态看到它"**：静态逆向目前只到"存在 WDI Action Frame 与 IHV 控制路径"，源地址/MAC 头由驱动构造，类别 `0x7f` 的 RX 到用户态未闭合（`TARGETED-REVERSE.md:76-98`、`HANDOFF-MODEL-SWITCH.md:48-96`）。有 Action Frame 支持 ≠ AWDL 可用。

---

## 1. 范围、方法与"我读了什么"

### 1.1 入口文档（按 `AGENTS.md:5` 要求）

| 文档 | 作用 | 关键点 |
| --- | --- | --- |
| `AGENTS.md` | 项目约定 | 阶段 0 优先：先确认硬件与原始收发，再移植 AWDL，最后 GUI（`:8`）；不自动换驱动（`:11`）；`upstream/` 不在仓库（`:12`） |
| `README.md` | 用户/开发总览 | 需要 RTL8821CU USB 卡（`:3`）；内部测试版、只能接收（`:5`）；进程拓扑（`:117-127`）；GPL 边界（`:129`） |
| `docs/PHASE0_AUDIT.md` | 源码审计与 Go/No-Go | 只用于交叉核对，本轮未逐行引用 |
| `docs/PLAN.md` | 阶段计划 | Phase 3 验收写"真实 AWDL 帧、邻居发现与同步证据"（`:49`） |
| `docs/FINAL_PLAN.md` | 最终方案与验收指标 | V1 门槛（`:19-26`）、四条提速线（`:89-120`） |
| `docs/WORK_QUEUE.md` | **进度唯一入口** | 授权状态（`:16-18`）、Q15/Q31/Q38/Q41/Q48/Q51/Q68–Q70 |
| `WORK_LOG.md` | 时间倒序工作记录 | 只做交叉核对（选举、时隙、IPC、Q50 编译） |

### 1.2 AWDL 相关精读清单

- 补丁：`patches/awdl-ipc-host.patch`（578 行，含新增 `host_if_ipc.c`）、`patches/owl-airbridge.patch`（111 行）、`patches/airdrop-identity.patch`（71 行）、`patches/devourer-airbridge.patch`（仅作契约参照，未精读 radio 细节）
- 数据面：`src/awdl_netd/{main.cpp,lwip_proxy.cpp,native_mdns.cpp,local_io.cpp,lwipopts.h,CMakeLists.txt,tcp_diag.cpp}`
- 编排与协议：`src/supervisor/Program.cs`（3678 行，重点 380–560、860–1040）、`src/radio_usb/{main.cpp,radio_link.h,peer_telemetry.h}`
- 服务发现/唤醒：`src/beacon/airdrop-beacon.ps1`、`src/awdl_netd/native_mdns.cpp`、`patches/awdl-ipc-host.patch` 中的 `airdrop/mdns.py` 与 `receiver.py` hunk
- 文档：`README.md`、`docs/STATUS.md`、`docs/FINAL_PLAN.md`、`docs/PLAN.md`、`docs/USERSPACE_DATAPATH.md`、`docs/RADIO_CONTRACT.md`、`docs/RADIO_USB.md`、`docs/PHASE3_AWDL.md`、`docs/SEND_PATH.md`、`docs/DISCOVERY.md`、`docs/NATIVE_RECEIVER.md`、`docs/LICENSE_MATRIX.md`、`docs/BUILD_WINDOWS.md`、`docs/WORK_QUEUE.md`
- 证据：`evidence/awdld-*.log`、`evidence/*-awdld.log`、`evidence/q15-master-mode.log`、`evidence/awdl-sequence-and-fastretune.log`、`evidence/transfer-970kbs.log` 等
- 外部输入（只读、不改）：`sessions\2026-11-11-wifi-driver\analysis\TARGETED-REVERSE.md`、`HANDOFF-MODEL-SWITCH.md`

### 1.3 本轮没做的事

未执行 git（快照非工作树）、未构建、未跑 `Apply-AwdlPatches.ps1`、未跑 `Start-Chain.ps1`、未联网、未读 `upstream/`（不存在）。所以：**所有涉及 OWL/WinAWDL 内部函数体的结论，一律是"补丁上下文 + 日志 + 文档"三者互证的推断，不是读源码得来的事实。**

---

## 2. 快照的物理边界：为什么"AWDL 上层"大半不在这里

【源码事实】

- `AGENTS.md:12`：`upstream/` 是未纳入主仓库的原样研究副本，版本见 `docs/sources.lock.json`。
- `README.md:158`：`upstream/` 被 `.gitignore` 排除，按 `docs/sources.lock.json` 恢复。
- 仓库实际目录只有 `assets/ docs/ evidence/ packaging/ patches/ src/ tools/` 七个（顶层列表）；`src/` 下只有 `awdl_netd`、`beacon`、`radio_usb`、`sfx`、`supervisor`。
- 锁定的上游（`docs/sources.lock.json:1-32`）：
  | 名称 | commit | 在本项目中的角色 |
  | --- | --- | --- |
  | winawdl | `2196fb48…` | 提供 `awdld`（AWDL 控制面）与 `airdrop/`（接收端 Python） |
  | devourer | `34a9e6f9…` | radio 的 RTL8821C 驱动库（GPL-2.0） |
  | owl | `0ee3263f…` | awdld 内嵌的 AWDL 协议库（GPL-3.0） |
  | swooshdrop | `c0eaff15…` | 行为参考，不进入路线 |
  | opendrop | `11fe7ba7…` | 参考/候选，未使用 |
- 但 `patches/awdl-ipc-host.patch:573-578` 又把 OWL 子模块钉在 `da255a70f221784c836d943dd3f243bc798f223b`（且标 `-dirty`）——**与 `sources.lock.json` 的 `0ee3263` 不是同一个提交**。这条不一致后文 §10 会再提。

【静态推断】因此本快照能给出的"AWDL 上层"信息只有三类：
1. **接缝定义**：`radio_link.h`、host_if IPC 的线格式、supervisor 的启动顺序与环境变量；
2. **对上游的三处改动**：选举 metric/counter 可配、可跟随主控信道序列、slot 8 设为社交信道；
3. **可观测行为**：awdld 日志格式（`switch channel to N (slot M)`、`sync master is now X`、`peers N | rx action …, data …`、`peer … changed channel sequence to …`）与实测数值。

---

## 3. 进程拓扑、启动顺序与状态机

### 3.1 五个后端的固定顺序

【源码事实】`src/supervisor/Program.cs:958-1038`：

```csharp
Child[] chain = { radio, bridge, netd, awdld, receiver };   // :958
foreach (Child child in chain) { … child.WaitReady(timeout) … }  // :976-1038
```

- 顺序：**radio → bridge → netd → awdld → receiver**（`:958`），每个都等 ready 行再起下一个。
- 端口/监听（`docs/STATUS.md:55`、`docs/USERSPACE_DATAPATH.md:7-20`）：
  `radio` 听 `127.0.0.1:49876`（`src/radio_usb/main.cpp:387-418`）→ `radio_pipe_bridge` 转成命名管道 `\\.\pipe\winawdl-radio` → `awdld` → 原始 IPv6 打到 `127.0.0.1:49877`（`src/awdl_netd/main.cpp:38`）→ `awdl_netd` → 本地 `8771`（TCP 代理，`src/awdl_netd/lwip_proxy.cpp:27`）+ 本地 `15353`（mDNS UDP 代理，`:28`）→ `receiver.py`。
- 超时策略（`Program.cs:1026-1032`）：awdld 至少 90 s；radio 至少 300 s（"固件启动失败会重试 ~80 s"）。
- 地址文件握手（`Program.cs:999-1025`）：起完 receiver 后**等 `awdl_netd` 写出地址文件**（最长 `readyTimeoutSeconds`），超时判失败。netd 侧写在 `src/awdl_netd/main.cpp:162-185`（宽字符 API），由 awdld 的 16 字节地址派生。

### 3.2 awdld 的启动参数与环境（上层"配置面"全在这）

【源码事实】`Program.cs:374-376`、`:523-532`：

- `RadioArguments` = `"<channel> <width>"`（默认 `149 20`）
- `AwdldArguments` = `"-c <channel> -s <streams> -j <join_us> -v"`（默认 `-c 149 -s 1 -j 400 -v`）
- 环境：`AWDL_ELECTION_METRIC=200`、`AWDL_ELECTION_COUNTER=100000`、`AWDL_CHANSEQ=social`（fixed 时为 null）、`AWDL_FOLLOW_MASTER_SEQ`（**显式置 null**，即默认不跟随）
- radio 环境：`AIRBRIDGE_LOG_LEVEL`、`AIRBRIDGE_LINK_STATS=1`、`AIRBRIDGE_FASTRETUNE_FW=2`、`AIRBRIDGE_PARENT_PID`（`:921-938`）
- netd 环境：`AWDL_NETD_MDNS_PROXY=1`、`AWDL_NETD_ADDR_FILE`、可选 `AWDL_NETD_OUTBOUND=8772`（`:943-948`）

### 3.3 失败与自恢复（上层的"状态机"其实在这里）

【源码事实】`Program.cs` + `docs/STATUS.md:89-106`：

- 进程退出 / radio 静默 > 30 s → 整链重启；退避 1 s / 5 s / 30 s；连续 5 次且未稳定 10 min → 停止并显示"多次失败，已停止"（`README.md:48`、`docs/STATUS.md:99-101`）
- receiver 单独死亡只重启 receiver；10 分钟内单独重启超过 3 次 → 改整链重启（`docs/STATUS.md:100`）
- 主动停止走"停止事件 + 父进程句柄"双保险（`src/radio_usb/main.cpp:242-259`），radio 不进 Job 对象（`docs/STATUS.md:90`、`README.md:127`）
- **上层没有"AWDL 协议状态机"**：它把状态完全托付给 awdld，只观测三件事：ready 行、地址文件、radio 的 `peer frames=` 遥测行（`Program.cs:534-579`、`:2565-2570`）

【静态推断】这意味着：**换 radio 后端时，只要新后端仍然提供这三个可观测点（ready 行、帧遥测、可被静默检测），supervisor 这一层几乎不用改**。这是 AX201 路线可复用的最大一块。

---

## 4. 两条 IPC 契约（逐字节）

### 4.1 上层 ↔ radio：`radio_link` v3

【源码事实】`src/radio_usb/radio_link.h`：

| 项 | 值 | 行 |
| --- | --- | --- |
| 管道名 | `\\.\pipe\winawdl-radio` | `:8` |
| 版本 | `3` | `:9` |
| 最大载荷 | 16384 B | `:10` |
| 头 | `uint16 type; uint16 reserved; uint32 length;`（小端，8 B） | `:21-25` |
| 消息 | HELLO=1, RX=2, TX=3, SET_CHANNEL=4, SET_BSSID_FILTER=5, SET_ADDRESS=6 | `:12-19` |
| HELLO 体 | `{version, channel, width_mhz, reserved[2]}`（8 B） | `:27-32` |

【源码事实】方向与语义（`src/radio_usb/main.cpp`）：
- `HELLO` 是 **radio → 客户端**（`:521-535`）；客户端连上后第一件事是收 HELLO。
- `TX` 载荷 = radiotap + 完整 802.11 帧，radio 直接 `radio->send_packet(payload)`，**不在这一层解析 AWDL**（`:637-642`；文件头注释 `:4-5`）。
- `SET_CHANNEL` 载荷 1 字节，走 `FastRetune`，**换台失败即 `shutdown(client)` 断链**（`:643-670`）。
- `SET_BSSID_FILTER` 载荷 6 字节，全零=清除（`:671-692`）。
- `SET_ADDRESS` 载荷 6 字节，与已设 BSSID 一起布防硬件 ACK（`:693-709`）。
- RX 上报：24 B 以上的正常帧 + 10 B radiotap（`kRadiotapBytes`），RSSI 写在第 9 字节（`kRssiFloorDbm + rssi[0]`）（`:213-225`）。

### 4.2 awdld ↔ netd：`host_if` IPC（本项目新增）

【源码事实】`patches/awdl-ipc-host.patch:383-572`（新文件 `awdl/win/host_if_ipc.c`）：

- TCP `127.0.0.1:49877`，连接重试 200 次 × 100 ms（`:408`、`:462-472`）→ **20 s 容忍窗口**。
- 握手 20 B：`"AWDL"` + 16 B 地址（`:479-486`、`src/awdl_netd/main.cpp:262-270`）。
- 帧格式：2 B 小端长度 + 载荷；载荷 > `HOST_IF_MAX_PACKET` 或 ≤0 时**复位状态并 shutdown**，不尝试重新同步（`:517-564`）。
- netd 侧：`len < 40` 视为非法（`main.cpp:243-246`）；超过 `kMaxFrame=2048` 的 **TX** 直接 `ERR_VAL`（`main.cpp:40`、`:110-114`）。
- **背压语义**：netd 的 `tcpip_input()` 返回 `ERR_MEM` 时按 1 ms 重投，最长 500 ms（`main.cpp:44-49`、`:187-226`）。这是"不丢帧"的关键设计，直接决定了吞吐（`docs/LWIP_INPUT_QUEUE.md` §14、Q38 实测 0.38→0.85 MB/s）。

【静态推断】这两条 IPC 都是"后端无关"的。AX201 方案的 radio 侧只要实现 4.1 的 6 条消息，awdld/netd/receiver **一行都不用改**——前提是能实现 4.1 的语义（见 §5）。

---

## 5. 对 radio 后端的契约：消息之外还要求什么

### 5.1 五条硬要求（缺一即不可用）

| # | 要求 | 依据 | 可容忍度 |
| --- | --- | --- | --- |
| R1 | **整帧透明注入**：上层构造 802.11 头（含目的/源/BSSID/帧控制），radio 不得重写 | `radio_link.h:12-19`、`main.cpp:637-642`、`RADIO_CONTRACT.md:29` | 不可协商 |
| R2 | **自有 MAC 可设**（`SET_ADDRESS`）并被硬件用于 ACK 过滤 | `main.cpp:693-709`、`RADIO_USB.md:17-19` | 不可协商；AWDL 地址每次启动随机（见 §5.4） |
| R3 | **逐时隙换台**且时延有界、可确认 | `main.cpp:643-670`、`STATUS.md:68` | 跨频段 ≤ ~0.3 ms 是实测可用值；65–90 ms 不可用 |
| R4 | **RX 整帧上报**（radiotap + 帧 + RSSI/rate/bw/sgi） | `main.cpp:188-232` | 允许丢帧（上层是 TCP over IPv6） |
| R5 | **单客户端独占**、断链即整链重启 | `main.cpp:387-418`、`Program.cs:976-1038` | 不可协商（多客户端会抢信道状态） |

### 5.2 隐含但真实存在的要求

- **不要求接收方向 A-MPDU/BlockAck**：8821C 根本没有（`RADIO_CONTRACT.md:9-12`、`:42`），接收方向退化为单 MPDU 仍能跑到 1.1 MB/s（`README.md:262`）。→ 对 AX201 是"可以不要"，不是"必须有"。
- **要求可配 TX 重试上限**：`AIRBRIDGE_RETRY_LIMIT` 默认 7（`main.cpp:330-333`）；空口 ACK 未布防时 devourer 会警告 `retry_limit=0`（`RADIO_USB.md:19`）。
- **要求"发送是同步提交"**：radio 的客户端消息循环是串行处理（`main.cpp:623-709`），TX 与 SET_CHANNEL 共享同一条连接，**换台会排在 TX 后面**。
- **要求错误以断链表达**：换台失败不重试、只断链（`main.cpp:664-670`），让 supervisor 重启整链。这是"宁可重启，不带着不确定的信道状态继续发"的显式决策。

### 5.3 硬实时 vs 可容忍（按截止时间排序）

| 环节 | 数量级 | 性质 | 依据 |
| --- | --- | --- | --- |
| 单帧 ACK | µs（硬件） | 硬实时，软件不参与 | `docs/ARCHITECTURE.md:28`；`RADIO_USB.md:17`（ACK 行为**未验证**） |
| 逐时隙换台 | 0.22–0.28 ms（固件快切）/ 65–90 ms（完整路径） | **最紧的软件截止时间** | `STATUS.md:68`、`evidence/awdl-sequence-and-fastretune.log:21-27` |
| 同步/信标帧周期 | awdld 实测 ~24 帧/s（`tx action` 每 2 s +48） | 软实时，错过由下一周期补 | `evidence/awdld-first.log:12-18` |
| ICMPv6/NDP、TCP 重传 | ms～百 ms | 可容忍 | lwIP 默认；`lwipopts.h:72-76` |
| IPC 握手 | 20 s 重试窗口 | 可容忍 | `host_if_ipc.c:408`（patch 内行号） |
| mDNS 公告 | 0.5 s / 上传期暂停 | 可容忍 | `DISCOVERY.md:13-26`、`awdl-ipc-host.patch:80-84` |
| 进程监管 / 看门狗 | 1/5/30 s、30 s 静默 | 非实时 | `Program.cs:1026-1032`、`STATUS.md:90` |

【静态推断】唯一"错过就掉一半吞吐"的窗口是**换台落在时隙边界之外**：一旦换台慢于时隙宽度，awdld 在原信道停留时间不足，iPhone 的 149 时隙上收不到我们的 ACK/数据。仓库没有给出 slot 时长的常量（全仓无 `slot length` 定义），所以**不能从本快照算出安全余量**——只能以"实测 0.25 ms 可用、65 ms 不可用"为经验边界。

### 5.4 契约里最容易被忽略的一条：源 MAC 是随机的

【源码事实】`patches/awdl-ipc-host.patch:117-127`（`stable_service_id` 的 docstring）：

> "awdld picks a new random AWDL MAC every start, so the address (and the ID) changes (observed: 8e2c9afffe41, b011eefffed7, ...)"

`evidence/awdld-first.log:9`：`AWDL address ce:99:e6:09:ba:8f on channel 44`。

【静态推断】后果：
- AWDL 的 IPv6 link-local 是 EUI-64，由这个随机 MAC 派生 → **radio 必须接受任意 locally-administered MAC 作为自己的地址**；
- 上层的服务实例 ID 也就跟着变（所以才要持久化，见 §8.3）；
- AX201/WDI 的源地址来自端口/peer 上下文（`TARGETED-REVERSE.md:82-88`：MAC 头由驱动构造），**这是与 R2 的正面冲突**，也是我认为最关键的单点风险。

### 5.5 一个可疑的契约缺口（提请注意，不下结论）

【源码事实】radio 只在 bring-up 后设置**一次**全局 TX 模式：`radio->SetTxMode(...)`，默认 `"1M"`（`src/radio_usb/main.cpp:379-385`）。逐帧速率控制不在 `radio_link` 的任何消息里。
【静态推断】radiotap 头里的 rate 字段是否被 devourer 采纳，本仓库无法看到（devourer 不在快照）。若未采纳，则 AWDL 的"管理帧用 6 Mbps、数据帧用高 MCS"这一分离**在当前契约里做不到**。这一点建议在做 AX201 后端前先用一个回环 stub 验一遍，因为它决定 API 形状。

---

## 6. AWDL 的邻居发现、同步、信道调度到底在哪

### 6.1 实现位置（源码事实 + 缺口）

| 功能 | 实现位置（应在此处） | 本快照可见证据 | 可验证性 |
| --- | --- | --- | --- |
| 邻居发现 / peer 表 | `upstream/winawdl/awdl/src/peers.c`、`rx.c` | 补丁上下文出现 `struct awdl_peer *src`、`src->addr`、`src->sequence`、`state->election`（`patches/owl-airbridge.patch:58-80`）；日志 `peers N`（`evidence/awdld-first.log:12`） | 仅补丁+日志，**函数体不可见** |
| 同步（PSF / sync tree） | `awdl/src/sync.c`（`AWDL_SYNC_THRESHOLD 3`）、`election.c` | `patches/owl-airbridge.patch:53`（`#define AWDL_SYNC_THRESHOLD 3`）、`:69-74`（`awdl_election_is_sync_master`）；日志 `sync tree … (met 60, ctr 0)`（`evidence/awdld-first.log:12`） | 同上 |
| 选举（主控） | `awdl/src/election.c` | 补丁全文（`:13-32`）；日志 `sync master is now X, chosen among:` | 补丁可读，逻辑见 §6.2 |
| 信道调度（逐时隙） | `awdl/daemon/core.c` 的逐时隙循环 + `state->channel.sequence[slot]` | `evidence/q15-follow-sequence.log:9`（"`owl/daemon/core.c` 的逐时隙循环读的正是 `state->channel.sequence[slot]`"） | 仅一句文档转述 |
| Host 后端（数据面出口） | `awdl/win/host_if*.c`、`host_frame.c` | `patches/awdl-ipc-host.patch:383-572`（**新增文件全文可读**） | **完全可读** |
| 数据面 IPv6/NDP | 本项目 `src/awdl_netd` | 全文可读 | **完全可读** |

**结论：真正与"邻居发现/同步/AVW-EW"相关的代码，本快照一行都没有。** 能读到的只有 111 行 OWL 补丁和日志字符串。

### 6.2 能确定的三条协议行为（补丁级事实）

1. **选举先比 counter、再比 metric；只在对方更小时才拒绝对方**（`patches/owl-airbridge.patch:19-25` 注释）。
   OWL 自己**从不递增** `self_counter`（`state->self_counter = AWDL_ELECTION_COUNTER_INIT`），而 iPhone 的 counter 大约每 3.14 s +1（补丁注释：`seen at 1514`；`WORK_LOG.md:1262` 同述）。→ 静态上必然被反超，所以要写死 `100000`。
2. **AWDL_CHANSEQ=social 只改第 8 个槽位**（`patches/owl-airbridge.patch:100-108`）：
   ```c
   state->channel.sequence[8] = CHAN_OPCLASS_6;   /* 其余仍由 awdl_chanseq_init_static 填主控信道 */
   ```
   这与实测的 Apple 序列形状一致（第 9 个 0 基索引 = slot 8 恒为 6）：`evidence/awdld-149.log:15`、`:11`、`:33`。
3. **从属时可选跟随主控序列**（`patches/owl-airbridge.patch:69-80`），由 `AWDL_FOLLOW_MASTER_SEQ` 开启，**默认关闭**（supervisor 显式置 null，`Program.cs:530`）。关闭的理由是实测负结果：跟随会跳到 36/6 槽位空等，吞吐腰斩（`evidence/q15-master-mode.log:18`）。

### 6.3 时隙模型的实证（16 槽 + 社交信道）

【历史记录】`evidence/awdl-149.log:10-15`：

```
19:00:29 DEBUG: switch channel to 149 (slot 0)
19:00:29 DEBUG: peer … changed channel sequence to 149,0,149,0,0,0,0,0,6,149,149,0,0,0,0,0
19:00:30 DEBUG: peer 8e:b4… changed channel sequence to 36,36,149,0,0,0,0,36,6,36,149,36,0,0,0,36
```

- 序列长度 **16**（这 16 个数字即 16 个时隙的信道；0 表示该槽不驻留）。
- **第 8 槽恒为 6**（社交信道），跨设备一致。
- awdld 只在启动时打印一次 `switch channel to 149 (slot 0)`——因为默认序列是"全 149"，逐时隙循环里每槽都是 149（`evidence/q15-follow-sequence.log:9`）。**这也解释了为什么"有 Action Frame 能力"丝毫不等于"会按时隙换台"**：能不能换台是 radio 的 `SET_CHANNEL` 决定的。

【历史记录】换台实测（`evidence/awdl-sequence-and-fastretune.log:21-27`）：

```
13:40:50.095 radio: channel 149 -> 6 (274 us, fastretune)
13:40:50.161 radio: channel 6 -> 149 (246 us, fastretune)
13:40:51.144 radio: channel 149 -> 6 (220 us, fastretune)
```

同一份日志 `:12-18` 记录了"iPhone 立刻跟随我们的序列"和"起步 930 帧/s"。

### 6.4 Availability Window / Extended Window：本快照无法判定

【源码事实】全仓 Markdown + 源码中，`availability`、`extended window`、`AWE`、`AWDL_AW` 等术语 **零命中**（grep `availability|extended window|AWDL_|beacon|PSF|periodic sync` 命中的全是蓝牙 beacon 与 env 变量）。
【静态推断】只能谨慎地说：
- **可见的调度模型是"16 时隙信道序列 + 同步主控 + 逐时隙换台"**，这是 AWDL 可用性调度的一种实现形式；
- OWL 是否实现了 Apple 规范里完整的 availability window / extended window 语义（即按 AWE 参数动态协商窗口），**必须先取回 upstream 才能回答**；
- 不能因为"有时隙序列"就宣称"实现了 AW/EW"，也不能因为没看到术语就宣称"没实现"。这是本轮最需要保留的空白之一。

---

## 7. IPv6 over AWDL、地址分配、peer 表

### 7.1 地址分配链路（三处，必须一致）

【源码事实】

1. **awdld 生成 AWDL 地址**：日志 `AWDL address <mac> on channel N`（`evidence/awdld-first.log:9`），即随机 MAC + EUI-64 link-local。
2. **awdld 把 16 B 地址在 IPC 握手里给 netd**：`host_if_ipc.c` 的 20 B hello（`awdl-ipc-host.patch:479-486`），netd 侧解析（`src/awdl_netd/main.cpp:262-275`）。
3. **netd 反推 MAC 并配置 lwIP**（`main.cpp:142-160`）：
   ```cpp
   g_netif.hwaddr[0] = address[8] ^ 0x02;   // U/L 位翻转
   g_netif.hwaddr[1..2] = address[9..10];
   g_netif.hwaddr[3..5] = address[13..15];  // 跳过 ff:fe
   ```
   注释明确写了"拷贝 8-13 会把 ff:fe 塞进 MAC"，而 Q69 又修过一次同样的字节位置问题（`docs/STATUS.md:97` 末段）。→ **这段是实现过两次 bug 的高风险处**。
4. netd 写地址文件（`awdl_netd.addr`）供 receiver 的 mDNS 公告使用（`main.cpp:162-185`、`Program.cs:999-1025`）。

### 7.2 数据面（lwIP 配置）

【源码事实】`src/awdl_netd/lwipopts.h`：

| 项 | 值 | 行 |
| --- | --- | --- |
| IPv4 | **0**（IPv6-only） | `:21` |
| IPv6 ND / MLD / ICMPv6 | 1 / 1 / 1 | `:23-27` |
| IPv6 分片 | **0**（不支持） | `:25` |
| TCP MSS | 1360 | `:65` |
| TCP 窗口 | 240 KiB + 窗口缩放 | `:66-68` |
| 网络接口 MTU | 1450（`netif->mtu`） | `main.cpp:134` |
| IPC 输入消息池 | `MEMP_NUM_TCPIP_MSG_INPKT=64`（默认 8 会丢帧） | `:48-60` |
| 邻居表 | `LWIP_ND6_NUM_NEIGHBORS 8` / `DESTINATIONS 8` | `:72-73` |

【静态推断】MTU 1450 + MSS 1360 + 不支持分片，意味着 **IPv6 数据报必须小于 1450**；AirDrop 的 TCP 段因此被限制在 1360。上行的 mDNS 报文（iPhone 的 297 B 应答）没问题，但任何 >1450 的 IPv6 单包会被 lwIP 丢弃。`docs/USERSPACE_DATAPATH.md:77`、`:85` 把它列为已知限制。

### 7.3 peer 表：其实是四张不同的表

| 表 | 位置 | 内容 | 备注 |
| --- | --- | --- | --- |
| AWDL peer 表 | OWL（`awdl/src/peers.c`，**不可见**） | MAC、序列、election 参数、sync 关系 | 日志 `peers N` 即此表规模 |
| lwIP 邻居表 | `awdl_netd` 内 lwIP ND6 | 链路层地址 ↔ IPv6 | 容量 8（`lwipopts.h:72`） |
| radio 遥测 | `src/radio_usb/peer_telemetry.h:17-43` | 只统计"目的=own 的单播数据帧"的帧数/字节/rate/rssi | 供 supervisor 算 fps（`Program.cs:556-579`） |
| mDNS 实例 | `receiver.py` + `awdl_netd` 代理 | 服务实例 ID、SRV 端口、TXT flags | 见 §8 |

**这四张表互不同步**，也没有任何一致性检查。AX201 后端只需要驱动第一张表（通过 TX/RX 转发），但**必须保证链路层地址与 awdld 认为的 own MAC 一致**，否则 NDP 与硬件 ACK 都会错。

---

## 8. AirDrop 接收链路：四道接缝与依赖

### 8.1 端到端（含每段的实现归属）

```
iPhone ──AWDL 空口──▶ radio（radiotap+802.11）                 [后端相关]
  └▶ awdld（AWDL 控制面：同步/选举/时隙）                        [upstream，不可见]
  └▶ 原始 IPv6 帧，TCP 49877（2 B 长度前缀）                     [本项目 patch 新增]
  └▶ awdl_netd：lwIP IPv6/NDP + mDNS 代理 15353 + TCP 8771 代理   [本项目，可读]
        ├─ UDP 5353 ↔ 127.0.0.1:15353  （mDNS / DNS-SD）
        └─ lwIP TCP 8771 → 127.0.0.1:8771（明文，TLS 在下一跳）
  └▶ receiver.py：TLS 终止 + HTTP/1.1 + /Discover /Ask /Upload + DVZip  [upstream，仅补丁可见]
  └▶ 落盘
```

### 8.2 接缝 1：mDNS / DNS-SD

【源码事实】
- 记录集（原生实现，与上游 `mdns.py` 对齐）：`PTR _airdrop._tcp.local → <id>._airdrop._tcp.local`；`SRV <id>… → <id>.local:8771`；`TXT flags=0x3fb`；`AAAA <id>.local → AWDL link-local`；`NSEC`（`src/awdl_netd/native_mdns.cpp:2-10`、`:75-107`）。
- 实例 ID = 地址字节 8–13 的 12 位 hex（`native_mdns.cpp:67-73`），但**持久化版本**来自 `stable_service_id()`（`patches/awdl-ipc-host.patch:117-152`），存在 `<keys>/airdrop-service-id`。
- 代理路由：本地→AWDL 发 `ff02::fb:5353`（`lwip_proxy.cpp:181-189`）；AWDL→本地时**应答优先回最后一个提问者**（`:205-216`）。
- MLD：必须先 `mld6_joingroup_netif(ff02::fb)`，否则 lwIP 在 `ip6_input` 就丢掉手机的全部 mDNS 组播（`main.cpp:337-351`；`SEND_PATH.md:22-28` 记录了这个真 bug）。
- 公告节奏：0.5 s 一次、启动连发 3 次、收到查询回 2 次（`awdl-ipc-host.patch:250-282`）；上传期 `TRANSFER_BUSY` 全暂停（定义 `:112-116`，置位/清除 `:185`/`:193`，跳过逻辑 `:264-267`；`DISCOVERY.md:13-26`）。

【本机未验证 / 已记录的失败】原生 responder 的 iPhone 兼容性**未通过**：日志 `native mDNS ifindex=0 join=-1`，iPhone 看不到设备，默认仍走 Python mDNS（`docs/NATIVE_RECEIVER.md:8-22`、`docs/STATUS.md` Q12 状态）。

### 8.3 接缝 2：TCP 8771

【源码事实】
- lwIP 侧 `listen(8771)`（`lwip_proxy.cpp:400-446`），每条连接起两个线程做双向泵，`TCP_NODELAY`，1 s 轮询让线程能看见 `stop`（`:46-121`）。
- 上游侧 `local_tcp_connect(8771)`（`:48`）→ receiver 以 `--listen 127.0.0.1` 绑定（`awdl-ipc-host.patch:293-341`）。
- 代理模式下 `verify_request` 直接返回 True，不再按接口索引过滤（`awdl-ipc-host.patch:173-178`）——**这是安全边界的变化**：任何本机进程都能连 8771 并冒充 iPhone。

### 8.4 接缝 3：TLS 与证书

【源码事实】`patches/airdrop-identity.patch:17-57`：

- RSA-2048 自签，CN=`AirDrop receiver`，有效期 `VALID_DAYS`；
- **`BasicConstraints(ca=True, path_length=None)` 且 critical**（`:39-41`）——把叶子证书当 CA 用；
- 私钥 PKCS8 无加密写盘，先写 `.tmp` 再 `os.replace`（`:44-56`）；
- 缺 `cryptography` 时回退 `openssl.exe`（`:60-71`）。

【历史记录】接收方向：iPhone **接受**这张自签证书（首次真实传输成功，`docs/PHASE3_AWDL.md:3`）。发送方向：iPhone **拒绝**（`Unwilling`，`docs/SEND_PATH.md:92-100`）。
【静态推断】接收/发送的信任模型不对称（接收端只需 iPhone 主动连；发送端 iPhone 要校验发起方），所以**不能把"接收能过"当成"证书没问题"**，也不能把"发送被拒"当成协议不可行。

### 8.5 接缝 4：接收（DVZip / 落盘）

【源码事实】`receiver.py` 负责 chunked HTTP、DVZip（= gzip + cpio）解码、路径穿越防护、空间预算、断流恢复（`docs/FINAL_PLAN.md:63-65`、`docs/STATUS.md:52`）。`/Discover` 返回 binary plist（`ReceiverMediaCapabilities` / `ReceiverComputerName` / `ReceiverModelName`）（`docs/NATIVE_RECEIVER.md:24-34`）。
【历史记录】离线吞吐 228 MB/s（compressed）/ 278 MB/s（stored），说明 Python 不是瓶颈（`evidence/bench-receiver.md`、`docs/WORK_QUEUE.md:117`）。
【已知缺陷】`/Discover` 分块解析过严，日志有 `WARNING /Discover rejected: invalid or overlong chunk-size line`，**未修**（`docs/WORK_QUEUE.md:71` Q43、`docs/STATUS.md:114`）。

### 8.6 第三方依赖与版本（照抄，不推测）

| 依赖 | 版本 | 出处 |
| --- | --- | --- |
| Python | 3.12.10 embeddable x64（**未锁定**） | `docs/BUILD_WINDOWS.md:132` |
| cryptography / cffi / pycparser | 50.0.2 / 2.1.1 / 3.12（**未锁定**） | `docs/BUILD_WINDOWS.md:133` |
| lwIP | `STABLE-2_2_1_RELEASE`，commit `77dcd25a…`（**未锁定**；更早文档写 2.2.2，Q50 时该 tag 不存在） | `docs/BUILD_WINDOWS.md:130`、`:135` |
| lwip-contrib | 同源码树（win32 port） | `docs/BUILD_WINDOWS.md:131` |
| libusb | 1.0.30（仅 radio 用） | `docs/BUILD_WINDOWS.md:17` |
| devourer | 锁定 `34a9e6f9…`（Q50 构建记录里是 `f7e0731`，见 §10） | `docs/sources.lock.json:9-13` |
| WinAWDL `airdrop/` | `2196fb48…`，MIT（adapt 自 omdrop） | `docs/LICENSE_MATRIX.md:16` |
| TLS | Python 标准库 `ssl`（**没有第三方 TLS 库**） | `docs/STATUS.md:52`、`SEND_PATH.md:37` |
| .NET | Framework 4.8（系统自带） | `README.md:17` |

---

## 9. 构建 / 许可证 / 状态文档的明确表述

### 9.1 构建（`docs/BUILD_WINDOWS.md`、`README.md:161-205`）

- 【源码事实】依赖全部隔离在 `build/deps/`，不改系统 PATH、不做全局 vcpkg 集成（`BUILD_WINDOWS.md:25`）。
- 【源码事实】**awdld 必须用 MinGW 编**（vcpkg 里的便携 MinGW），并**必须带 `-DAWDL_HOST_IPC=ON`**（`tools/Build-Awdl.ps1:47-57`；`awdl-ipc-host.patch:360-367`：默认 OFF 走 Wintun，ON 走 `host_if_ipc.c`）。
- 【源码事实】其他组件 MSVC / CMake；netd 没有构建脚本，直接 `cmake -S src\awdl_netd`（`README.md:190-192`）。
- 【历史记录】**最后完整编译打包 = Q50（2026-10-30）**；netd 测试 6/7 通过，IPC 测试 15 s 与 90 s 均超时未解决（`docs/WORK_QUEUE.md:100`）。

### 9.2 许可证（`docs/LICENSE_MATRIX.md`、`README.md:286-302`）

明确表述（原文要点）：
- 本仓库自写代码 **MIT**（2026-11-10 定，`LICENSE_MATRIX.md:23`）；
- `airbridge_radio.exe` 因链接 devourer **整体按 GPL-2.0 分发**（`:32`）；
- `awdld.exe` 基于 OWL，**GPL-3.0-or-later**（`:33`）；
- 两者**不链接**，靠 `radio_pipe_bridge` + MIT 的 `radio_link` 隔离（`:34`）——这是唯一能避免 GPL-2.0-only 与 GPL-3.0 合并的边界；
- `patches/` **随被改的上游**，不因放在本仓库变 MIT（`:24`）；
- Realtek 固件**没有独立授权**，发布前三选一：取得许可 / 运行时加载 / 只发源码（`:39-48`）；
- 结论原文：**"固件授权和安装包聚合边界尚未解决，所以 Phase 0 的许可证项只能算「已识别风险」，不能算通过"**（`:80`）；
- 包内文本缺口：libusb LGPL、lwIP BSD、VC++ 运行库条款**都还没附**（`:99`）。

### 9.3 状态（`README.md:240-284`、`docs/STATUS.md`）

四层验证分开记录、互不替代（`README.md:242-253`）：

| 层 | 明确表述 |
| --- | --- |
| 源码实现 | 接收链路、托盘监管、设置、通知、自动装驱动、beacon 均已实现 |
| 本机编译 | 最近完整编译 **Q50**；**Q68/Q69/Q70 只提交源码，未编译未测试**（Q69/Q70 是在没有 Windows 工具链的 Linux 上做的） |
| 本机硬件 | 网卡初始化、收发、起停、强杀不残留、停止不卡死（Q55/Q57/Q58）真机验证 |
| 真实文件传输 | 29,456,959 B / 26.84 s ≈ 1.10 MB/s，落盘哈希一致 |

明确"做不到/没解决"（`README.md:269-274`、`docs/STATUS.md:108-119`）：
1. **只能接收**；Windows→iPhone **已确认无法实现**（Q48，用户 2026-11-04 确认）；
2. 传完一次后有时再连不上、两台手机同时在线掉到 0.08–0.12 MB/s，**根因未查清**（Q51）；
3. 24 h 常驻未跑完（Q7）；
4. `/Discover` 分块解析过严未修（Q43）；
5. 驱动"未绑定→已绑定"转换**没在真机验证**（Q53）；
6. MI_00 蓝牙接口长期 Problem 31（不影响，beacon 用主机 Intel 蓝牙）。

---

## 10. 源码 vs "最后一次实测可用的发布包"

### 10.1 仓库里没有语义化版本号

【源码事实】`tools/Package-Distributable.ps1:138-152` 生成的 `VERSION.txt` 只有：构建时间、`git rev-parse --short HEAD`、五个二进制的 SHA-256。**没有 `vX.Y.Z`**。所以"最后实测可用的包"只能用 **Q 编号 + 构建时间 + 哈希** 来指认，且 `VERSION.txt` 本身没有提交进仓库（`dist/` 不入库）。

### 10.2 时间线（这是差异的核心）

| 时间 | 事件 | 编译/测试？ |
| --- | --- | --- |
| 2026-10-30 | **Q50 完整编译 + 打包 + 真机 A/B**（devourer 升级） | ✅ 编译 ✅ 真机 |
| 2026-10-29 ~ 10-31 | Q41/Q46/Q54 真机传输（1.10 MB/s 的来源） | ✅ 真机 |
| 2026-11-01 ~ 11-02 | Q53–Q67 托盘/驱动/通知/设置类功能，期间重编托盘 | 部分 ✅ |
| 2026-11-03 | Q68 源码修复 | ❌ 未见编译证据 |
| 2026-11-09 | Q69 源码修复（Linux 环境） | ❌ 未编译 |
| 2026-11-10 | Q70 源码修复（44 条审查） | ❌ 未编译 |

→ **当前 HEAD 的源码 ≠ 最后一次真机跑过的二进制**。受影响的正是 radio/netd/bridge/awdld/托盘五个可执行文件里的四个（`docs/STATUS.md:112`）。

### 10.3 依赖锁定与实际构建不一致（文档自述）

【源码事实】

| 项 | 锁文件写的 | 实际构建用的 | 出处 |
| --- | --- | --- | --- |
| devourer | `34a9e6f9…` | Q50 完整编译记录里是 `f7e0731`（同日更早升到 `34a9e6f`） | `WORK_LOG.md:16`、`docs/WORK_QUEUE.md:100`、`docs/BUILD_WINDOWS.md:5` |
| OWL 子模块 | 锁文件 `0ee3263`；补丁头写 `da255a7` | 构建用子模块 `da255a7`（`-dirty`） | `sources.lock.json:21-25`、`awdl-ipc-host.patch:573-578`、`LICENSE_MATRIX.md:20` |
| lwIP | 未锁 | `STABLE-2_2_1_RELEASE`（`77dcd25`） | `BUILD_WINDOWS.md:130`、`:135` |
| Python / cryptography | 未锁 | 3.12.10 / 50.0.2 | `BUILD_WINDOWS.md:132-133` |

【静态推断】这意味着**即使把 HEAD 编译出来，也不是 Q46/Q54 那个 1.10 MB/s 的二进制**；任何"速度回退"都要先分清是源码变了还是依赖变了。

### 10.4 补丁在最后一次构建之后又被改过

【源码事实】Q70 修改了 `patches/awdl-ipc-host.patch` 里的 `host_if_read`（非法帧长时复位并断链，`WORK_QUEUE.md:98` 末段"补丁 `host_if_read` 非法帧长时复位并断开"）。而 `awdld.exe` 的最后一次构建在 Q50（2026-10-30）。
【静态推断】→ **shipped 的 `awdld.exe` 里没有这个修复**；如果按 HEAD 重建，awdld 行为会变（非法帧从"卡住"变成"断链退出 2"）。

### 10.5 其他已知的源码/文档不一致（供接手者避坑）

- `docs/WORK_QUEUE.md` **Q50/Q51 编号重复**（`:78-79` 与 `:100-106` 是两组不同事项）。查"Q50"时要看上下文。
- `docs/STATUS.md:51` 写 `awdl_netd` 编译进去的 lwIP 是 BSD-3-Clause，但 `LICENSE_MATRIX.md:25` 标注"未在本仓库内核对"。
- `patches/awdl-ipc-host.patch` 与 `patches/airdrop-identity.patch` **都改了 `airdrop/identity.py`**，且第一个补丁里包含第二个补丁的全部内容（`awdl-ipc-host.patch:1-71` vs `airdrop-identity.patch:1-71` 逐字相同）。按 `Apply-AwdlPatches.ps1:21-25` 的顺序应用时，第二个会被判为"already applied"（`apply --check` 失败但 `-R` 成功），**不会报错，但意味着两个补丁不是正交的**。
- `docs/ARCHITECTURE.md` 是历史文档（Dart/Flutter 方案已于 2026-10-28 废弃，`:3-4`），其中"AWDL 目标用 Dart"已被 `FINAL_PLAN.md` 取代（`PLAN.md:15`）。
- **MSS 口径不一致**：`docs/USERSPACE_DATAPATH.md:77` 写"TCP MSS 固定 1024"，而 `src/awdl_netd/lwipopts.h:65` 是 `TCP_MSS 1360`，`:73` 又写"应限制在 1440"。三者互不相同，改这段前先以源码为准，并确认线上包用的是哪一版。
- **IPC 帧长上限的说法**：`src/awdl_netd/main.cpp:40` 是 `kMaxFrame=2048`，Q70 却把"`ipc_reader` 2048 上限（awdld 合并 TCP 段后帧长可达 64 KB）"列为"不成立"的审查项（`WORK_QUEUE.md:98`）。两者至少有一处表述需要核实：TX 方向确实被 2048 卡住（`main.cpp:110-114`），RX 方向 `ipc_reader` 只查 `len<40`（`:243-246`）。

---

## 11. 因 upstream 缺失而无法静态验证的点

按"影响 AX201 决策的程度"排序：

1. **AWDL 同步/信标帧的具体构造**（IE、category/OUI、发送时刻、重传策略）——决定 AX201 后端是否需要"按时隙精确发送"还是"尽力而为"。
2. **availability window / extended window 是否实现、如何协商**——术语零命中，无法判定。这是"能不能被 iPhone 当成合法 peer"的核心。
3. **owd 的 channel sequence 状态机**：什么时候接受 peer 的序列、什么时候改自己的、`-j`（join_us=400）到底改了哪段时序。
4. **awdld 对 radio RX 的过滤期望**：`SET_BSSID_FILTER` 是谁设的？本快照里 supervisor 的 radio 环境只有日志级别/链路统计/固件快切/父进程 4 项（`Program.cs:923-938`），没有地址与过滤项，说明 `SET_ADDRESS`/`SET_BSSID_FILTER` 是 awdld 在运行时自己发的——但看不到调用点。
5. **TX 速率是否按帧**（§5.5）。
6. **`host_frame.c` 的 radiotap 构造**：netd 收到的 IPv6 是纯 IP 包还是带 radiotap？从 `host_if` 接口看是**纯 IPv6**（`HOST_IF_MAX_PACKET`、`host_if_write(packet,len)`），说明 radiotap/802.11 的封装在 awdld 内部完成——但看不到。
7. **`awdl_chanseq_init_static` 的默认序列语义**（除 slot 8 外到底是"主控信道"还是"全 149"）。
8. **`AWDL_CHANSEQ` 只认"存在性"不认值**（`STALL_DIAGNOSIS.md:44-46`）：设成 `fixed` 或 `0` 都关不掉社交时隙，必须移除变量。这条是本快照里少见的"明确记录的上游行为"，但仍无法看到代码。
9. **OWL 对 peer 数量/内存的上限**、断线回收时机。
10. **`awdld` 的 `-s`（streams）与 `-j`（join_us）语义**：只知道 `-s 1|2` 影响空口流宣告（Q54），`-j 400` 与 TCP 合并相关（Q39–Q41），具体实现不可见。

---

## 12. AX201 适配的最小验收顺序（S0–S7）

> 前置说明（必须写清）：**这条路不是"改一个 radio 后端"那么简单**。DropBridge 的 radio 契约假定"用户态能透明收发 802.11 帧、能设自己的 MAC、能逐时隙换台"。AX201 走的是 Windows 内置驱动（`Netwtw14.sys` + `IntelIHVRouter14.dll`），静态逆向目前只到"存在 WDI Action Frame 与 IHV 控制通路"，**没有证明第三方用户态进程能用它发出任意 802.11 帧**。因此下面的顺序是"逐级证伪"设计：任何一步失败，后面全部无意义。
>
> 另：S0 不改动任何硬件，可以先做；S1 起涉及发射，**需要单独授权**（对齐 `AGENTS.md:11`、`WORK_QUEUE.md:18`）。

### S0. 冻结契约 + 造一个回环 radio（不需要网卡、不需要授权）

**做什么**：用现有资产把"上层"单独跑起来——`awdl_netd` + `receiver.py` + `tools/test_netd_tcp.py` 的既有离线台（`src/awdl_netd/CMakeLists.txt:61-93` 已注册 7 项测试）；再写一个**只实现 `radio_link` v3 的假 radio**（TCP 49876，回 HELLO，TX 丢弃/回环，RX 可注入），让 `awdld` 能连上（需要恢复 upstream + 应用 3 个补丁 + MinGW 构建）。

**通过标准**：
- `ctest -R netd_` 7/7（`docs/WORK_QUEUE.md:63` Q35 记录过 7/7）；
- 假 radio + awdld：`awdld` 打印 `host interface`、IPC 握手成功、netd 写出地址文件、10 分钟无 `IPC failed`；
- `DropBridge.exe --check` exit 0 无 MISSING（`README.md:200`）。

**失败判据**：awdld 起不来先查 upstream/补丁，不查 AX201。

**为什么先做**：把"上层是否可用"与"AX201 是否可用"彻底解耦。这一步失败，说明问题在开源侧，不在驱动。

### S1. AX201 帧原语：能否发出一个 802.11 管理帧并被第三方看到

**做什么**（只做最小、可回滚的尝试）：走静态逆向已定位的 Action Frame 路径（`TARGETED-REVERSE.md:72-98`：请求字段 ChannelNumber/SendTimeout/PostACKDwellTime、`0x140141440` 构造 24 B MAC 头、`0x1b9` 下层消息），用**独立见证设备**（ESP32-S3 收 2.4 GHz，或第二张网卡 monitor）确认空口出现该帧。

**通过标准**（四条全满足才算过）：
1. 空口见证到帧，且 **category/OUI 是我们指定的**（不是驱动替换成别的）；
2. 目的地址、**源地址**是我们指定的（对照 §5.4 的随机 MAC 需求）；
3. 重复 3 次、每次唯一序号，见证 3/3；
4. 记录完整调用链（哪个 OID/IHV 方法、哪一层构造头），并确认**非 Intel 签名的第三方进程**也能走通（`TARGETED-REVERSE.md:118-122` 显示 `ValidateClient` 会校验签名者名称 `Intel Corporation`——这是硬门槛）。

**失败判据**：任一条不满足 → **AX201 路线在"发射"上不成立**，应立即停，不要继续做 S2。特别地：
- 只看到"有 Action Frame 代码"、只走通"Intel 自己的客户端" → **不算通过**；
- 能发但源 MAC 由驱动决定 → 即使能发，也**不能让 iPhone 把我们当 AWDL peer**（AWDL 要求 own MAC = AWDL 地址）。

### S2. RX 原语：能否在用户态看到 vendor-specific Action Frame（category 0x7f）

**通过标准**：
1. 对端（ESP32 或第二张卡）注入 category `0x7f` 的 Action Frame，用户态能收到 indication；
2. **能**看到 802.11 头（源/目的/BSSID）与至少 RSSI；
3. 与 S1 的发送路径同进程/同会话内可并发（收发不互斥）。

**依据与风险**：静态逆向显示管理帧 dispatcher 对 `0x7f` 只 `break` 返回成功、本函数内没有上报动作（`HANDOFF-MODEL-SWITCH.md:68-76`）；通用 Action Frame observer 存在但到用户态的路未闭合（`:78-84`）。**因此这一步很可能失败。**

**失败判据**：收不到或收不到 `0x7f` → AWDL 的同步帧永远进不来，路线不成立。

### S3. 换台原语与时延分布

**通过标准**：
1. 存在一个可由用户态触发的信道/频段切换（哪怕是间接的）；
2. 切换**可确认**（能读回真实信道，不能只看调用返回）；
3. 跨频段 p50/p99 时延记录在案，且 p99 **不劣于 1 ms 量级**（DropBridge 的可用值是 0.22–0.28 ms，不可用值是 65–90 ms；中间地带需要按 S4 的实测吞吐判定）；
4. 切换期间不崩、不掉 USB/PCIe 枚举。

**失败判据**：没有可用换台原语，或 p99 在几十 ms → **AWDL 的社交时隙模型无法成立**，只能退化成"固定在一个信道"（历史上 fixed 模式实测 0.114/0.104 MB/s，`WORK_QUEUE.md:55` Q27，且 discovery 也会退化）。

### S4. 时序闭环：按 slot 发送/接收

**通过标准**：
1. 能在 S3 的换台粒度上，让"发送发生在指定时隙"被见证设备确认；
2. 连续 10 分钟，slot 边界命中率、丢帧率、awdld 的 `peers` 稳定性有量化记录；
3. 不出现"换台把正在进行的 TX 挤掉"（对照 §5.2 的串行语义）。

**失败判据**：边界命中率不可测或极低 → 即便 S1–S3 都过，也做不出可用的 AWDL。

### S5. AWDL 协议级：iPhone 会不会把我们当 peer

**通过标准**（对齐 `docs/PLAN.md:49` Phase 3 验收）：
1. `awdld` 日志出现 `peers 1` 且持续 ≥ 60 s；
2. `rx action` 单调增长（说明收到 iPhone 的 action 帧）；
3. `sync master is now …` 出现且稳定（不来回抖动）；
4. 无 `IPC failed`、无整流重启。

**注意**：这一步之前**不要**去调吞吐，也不要用 `-s 2`/40 MHz 之类的历史调参——那些是 8821C 上的结论（Q54 明确说 `-s 1`/`-s 2` 只差 0.9%，是噪声），不能外推。

### S6. IPv6 数据面：NDP + mDNS 发现

**通过标准**：
1. netd 的 mDNS 代理能看到 iPhone 的 `_airdrop` 查询，并发出应答（`AWDL_NETD_MDNS_DEBUG=1` 可看 hex，`SEND_PATH.md:29-30`）；
2. iPhone 隔空投送列表里出现设备（发现延迟有记录，目标 P50 ≤ 2 s，`FINAL_PLAN.md:19`）；
3. netd `ipc stats` 的 `input_fail` 为 0（Q38 的验收口径，`WORK_QUEUE.md:66`）。

**失败判据**：mDNS 双通但列表不出现 → 检查 NSEC/记录集（`native_mdns.cpp` 与上游 `mdns.py` 的差异），这条历史上已经失败过一次（`NATIVE_RECEIVER.md:8-22`）。

### S7. AirDrop 闭环：TLS + /Discover + /Ask + /Upload

**通过标准**：
1. `/Discover` 返回 200 且 body 是合法 plist；
2. `/Ask` 返回 200；
3. `/Upload` 完整落盘，**SHA-256 与源文件一致**；
4. 连续 3 次成功，不重启链路；
5. 记录真实字节/墙钟时间（不能用 PHY 速率替代，`AGENTS.md:13`）。

**失败判据**：TLS 握手失败 → 先分清是证书（接收方向历史上是通的）还是 IPv6/端口问题；`/Discover` 分块解析告警（Q43）要单独记录，不要混算成链路失败。

### 12.1 关于"最小"的一句话总结

**S0 不需要硬件，应当先做；S1 与 S2 是生死门（发得出、看得见）；S3/S4 是 AWDL 特有门槛（换得动、跟得上）；S5–S7 才是"AirDrop 能不能用"。** 在 S1/S2 未过之前，讨论吞吐、GUI、打包都没有意义。

---

## 13. 关键风险（按严重度）

| # | 风险 | 性质 | 依据 | 如果成立 |
| --- | --- | --- | --- | --- |
| R-1 | **AX201 可能根本不提供第三方可用的 raw TX** | 静态推断（已有强线索） | `TARGETED-REVERSE.md:100-104`（没有可用的 monitor OID）、`:118-122`（客户端签名校验）、`HANDOFF-MODEL-SWITCH.md:80-84`（`0x7f` 未上报用户态） | 整条路线的 S1/S2 失败，应尽早止损，不要写驱动 |
| R-2 | **源 MAC 不可控** | 静态推断 | `awdl-ipc-host.patch:117-127`（awdld 每次随机 MAC）+ `TARGETED-REVERSE.md:82-88`（驱动构造 MAC 头） | 即使能发帧，也无法成为合法 AWDL peer |
| R-3 | **换台时延不可控** | 未知 | `STATUS.md:68` 的 0.22–0.28 ms 是 Realtek 固件快切（H2C 0x1D）的专属能力，**AX201 没有对应证据** | AWDL 时隙模型退化，吞吐掉一个数量级 |
| R-4 | **"有 Action Frame 支持"被误当成"AWDL 可用"** | 方法论风险 | `TARGETED-REVERSE.md:152`、`HANDOFF-MODEL-SWITCH.md:68-76` | 会在错误的层面投入数周 |
| R-5 | **上层源码本身未验证** | 源码事实 | Q68–Q70 未编译（`README.md:249`）；netd IPC 测试超时未解决（`WORK_QUEUE.md:100`） | 即使 AX201 通了，也要先修上层 |
| R-6 | **许可证/固件问题会阻塞分发** | 源码事实 | `LICENSE_MATRIX.md:39-48`、`:80` | 只能内部测试；AX201 路线若改用 Windows 内置驱动，反而**绕开了**固件再分发问题（这是少见的好处，但要另行核查 IHV 路径的许可） |
| R-7 | **单点耦合：上一跳的 MAC 与 NDP 必须一致** | 源码事实 | `main.cpp:142-160`（EUI-64 → hwaddr，改过两次 bug） | 地址不一致 → NDP 失败 → mDNS/TCP 全断，且症状隐蔽 |
| R-8 | **"只能接收"被误读成"协议不能发"** | 记录风险 | `SEND_PATH.md:92-100`（是证书被拒） | 会错误地排除发送方向的所有可能性 |
| R-9 | **RTL8821CU 经验外推** | 方法论风险 | Q54/Q27/Q39–Q41 全部是 8821C + 特定固件的行为 | 在 AX201 上照抄参数（`-s 2`、40 MHz、`-j 400`）会得到无关结论 |

---

## 14. 可复用模块清单（给主会话/后续实现的直接结论）

### 14.1 高价值、与网卡无关、建议直接复用

| 模块 | 文件 | 复用方式 | 注意 |
| --- | --- | --- | --- |
| **用户态 IPv6 数据面** | `src/awdl_netd/`（main/lwip_proxy/native_mdns/local_io） | 原样复用；只需 awdld 继续通过 49877 喂 IPv6 | 依赖 lwIP 2.2.1 + lwip-contrib win32 port，**未锁定** |
| **IPC 契约** | `patches/awdl-ipc-host.patch:383-572`（host_if_ipc）+ `src/awdl_netd/main.cpp:254-276` | 原样复用；新后端只要实现 20 B 握手 + 2 B 长度帧 | 非法帧长即断链（Q70 后的行为） |
| **radio_link v3 定义** | `src/radio_usb/radio_link.h` | 作为"后端必须实现的最小 API"直接沿用 | MIT，可自由复制 |
| **receiver 代理模式** | `patches/awdl-ipc-host.patch:201-208`（参数）、`:231-283`（ProxyAnnouncer）、`:293-340`（代理启动路径） | 原样复用（`--listen` + `--mdns-address-file` + `ProxyAnnouncer`） | 代理模式放弃接口过滤（安全边界变化） |
| **稳定实例 ID** | `patches/awdl-ipc-host.patch:117-152` | 原样复用 | 解决"每次启动多一个设备" |
| **mDNS 记录集与节奏** | `src/awdl_netd/native_mdns.cpp`（或上游 `mdns.py`） | Python 路径已验证可用，优先用它 | 原生 C++ 版**iPhone 不接受**（join 失败），别当现成方案 |
| **蓝牙唤醒 beacon** | `src/beacon/airdrop-beacon.ps1` | 原样复用（走主机蓝牙，与网卡无关） | 只有 Windows PowerShell 5.1 能用（`:12`）；对"非所有人"手机未单独验证 |
| **supervisor 编排/看门狗** | `src/supervisor/Program.cs` | 作为 harness 复用；新后端只要保住 ready 行/遥测行/静默检测 | 其中 radio 路径/环境名是 8821C 专用，需替换但接口形状可留 |

### 14.2 高价值、但必须取回 upstream 才能用

| 模块 | 位置 | 说明 |
| --- | --- | --- |
| **awdld（AWDL 控制面）** | `upstream/winawdl/awdl/` + `upstream/winawdl/upstream/owl` | 这是整个项目最有价值的资产：邻居发现、同步、选举、时隙调度全在这里。GPL-3.0，独立进程 |
| **三处行为补丁** | `patches/owl-airbridge.patch` | 选举 metric/counter 可配（决定谁是主控）、可选跟随主控序列、slot 8 = 社交信道。**这三条是本项目吞吐翻倍的全部秘诀** |
| **receiver.py 与 DVZip** | `upstream/winawdl/airdrop/`（MIT） | 640 行协议实现，含路径穿越/空间预算/断流恢复 |

### 14.3 不建议复用（对 AX201 无意义）

| 模块 | 原因 |
| --- | --- |
| `src/radio_usb/*`（除 `radio_link.h`） | 硬编码 RTL8821CU（`main.cpp:288-290`）、libusb + devourer 寄存器路径；AX201 是 CNVio2、走 Windows 内置驱动 |
| `patches/devourer-airbridge.patch` | 同上 |
| `packaging/driver/*`、`Bind-WinUSB.cmd`、Zadig | WinUSB 绑定只适用于可换驱动的 USB 设备；AX201 不能也不应换驱动（`AGENTS.md:11`） |
| `docs/ARCHITECTURE.md` 的 Dart 方案 | 已于 2026-10-28 废弃 |

### 14.4 作为"行为基线"复用（不给代码，给验收口径）

- `evidence/` 下的 awdld 日志：给出了**合法的日志形态**（`peers`、`rx action`、`sync master`、`channel sequence`）。AX201 后端只需让同样的日志出现，就能用现成的 `tools/analyze_session.py` 分析。
- `docs/STATUS.md:57-68` 的配置表：给出了"什么参数是实测过的"。
- `docs/FINAL_PLAN.md:19-26` 的验收指标：给出了"什么算通过"。

---

## 附录 A：主要文件/行号索引

| 主题 | 位置 |
| --- | --- |
| 上游缺位 | `AGENTS.md:12`、`README.md:158`、`docs/sources.lock.json:1-32` |
| 进程顺序/ready | `src/supervisor/Program.cs:958`、`:976-1038` |
| awdld 参数/环境 | `src/supervisor/Program.cs:374-376`、`:523-532`、`:921-948` |
| radio_link v3 | `src/radio_usb/radio_link.h:8-32` |
| radio 消息循环 | `src/radio_usb/main.cpp:623-709` |
| RX 过滤/radiotap | `src/radio_usb/main.cpp:188-232` |
| 硬编码 VID/PID | `src/radio_usb/main.cpp:288-297` |
| 全局 TX 模式 | `src/radio_usb/main.cpp:379-385` |
| IPC host 后端 | `patches/awdl-ipc-host.patch:383-572` |
| 选举/序列补丁 | `patches/owl-airbridge.patch:13-32`、`:64-80`、`:96-108` |
| 证书补丁 | `patches/airdrop-identity.patch:17-57` |
| netd 主流程 | `src/awdl_netd/main.cpp:292-375` |
| EUI-64 → MAC | `src/awdl_netd/main.cpp:142-160` |
| lwIP 配置 | `src/awdl_netd/lwipopts.h:7-76` |
| TCP/mDNS 代理 | `src/awdl_netd/lwip_proxy.cpp:46-121`、`:147-236`、`:400-469` |
| 原生 mDNS 记录 | `src/awdl_netd/native_mdns.cpp:2-10`、`:75-107` |
| 换台实测 | `evidence/awdl-sequence-and-fastretune.log:21-27` |
| 序列形状 | `evidence/awdld-149.log:10-20` |
| 主控选举 | `evidence/q15-master-mode.log:7-25` |
| 状态与限制 | `README.md:240-284`、`docs/STATUS.md:9-18`、`:108-119` |
| 许可证结论 | `docs/LICENSE_MATRIX.md:78-80` |
| 构建/版本 | `docs/BUILD_WINDOWS.md:124-136` |
| 发送方向记录 | `docs/SEND_PATH.md:11-19`、`:79-100` |

## 附录 B：本轮读过的证据日志

`evidence/awdld-first.log`、`evidence/awdld-149.log`、`evidence/awdld-admin-149.log`、`evidence/sockets-awdld.log`、`evidence/tuned-awdld.log`、`evidence/userspace{,2,3,4}-awdld.log`、`evidence/width40-awdld.log`、`evidence/width80{,b}-awdld.log`、`evidence/q15-master-mode.log`、`evidence/q15-follow-sequence.log`、`evidence/awdl-sequence-and-fastretune.log`、`evidence/transfer-970kbs.log`、`evidence/upstream-issues.json`、`evidence/bench-receiver.md`。

---

## 附：本轮刻意没有下的结论（避免被误用）

1. **没有**说"OWL 实现/未实现 availability window"——只看不到源码。
2. **没有**说"AX201 不能做 AWDL"——只说了 S1/S2 是生死门且目前无正面证据。
3. **没有**把"发送方向失败"当成协议不可能——那是证书信任问题。
4. **没有**把"Action Frame 已恢复"当成"raw TX 可用"——驱动仍构造 MAC 头、仍有客户端校验。
5. **没有**把 RTL8821CU 的任何参数（信道、带宽、`-s`、`-j`、合并开关）当作 AX201 的默认值。
6. **没有**把 `docs/` 里的历史结论当成已复现——全部标了【历史记录】。
