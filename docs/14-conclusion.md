# 结论：AX201 用户态 AWDL 可行性裁定

2026-11-11。三条独立证据线（驱动静态逆向、DropBridge radio 契约、AWDL 上层）分别完成后合并。

证据等级：**[实测静态]** 反汇编/伪代码直读；**[源码事实]** 仓库原文；**[文档]** 微软/Intel 公开文档；**[推断]** 由前述推出。

---

## 1. 裁定

**[推断] 在这台机器（Windows 11 + Intel AX201，CNVio2）上，纯用户态实现 AWDL 不可行。**

不是因为「还没找到 API」，而是三层限制彼此独立、同时成立：

<div id="vcp-root">
<style>
#vcp-root{background:#12171c;color:#d8dde2;font-family:system-ui;padding:16px;border-radius:10px}
#vcp-root .row{border-left:3px solid #efa45c;padding:8px 12px;margin:8px 0;font-size:14px;background:#182027}
#vcp-root .k{color:#efa45c;font-weight:600}
#vcp-root .d{color:#9fb0bd;font-size:13px;margin-top:4px}
#vcp-root .v{color:#68c9c4;font-weight:600;margin-top:10px;font-size:14px}
</style>
<div class="row"><span class="k">① 硬件厂商层</span><div class="d">Intel 明确不支持 monitor / 注入 / 混杂模式；Npcap WlanHelper 在 AX201 上返回错误 50</div></div>
<div class="row"><span class="k">② 操作系统层</span><div class="d">WDI 只把 Action Frame 的「帧体」上报给 OS WLAN 栈，不向普通用户态进程交付完整 802.11 帧</div></div>
<div class="row"><span class="k">③ 驱动访问控制层</span><div class="d">唯一能下发私有无线命令的通道，被 Intel 签名校验 + 提权检查 + 应用白名单把守</div></div>
<div class="v">三层缺一即可绕，但三层同时成立 → 用户态无解</div>
</div>

要突破必须动内核驱动或固件，属于全新授权级别，且不保证成功。

---

## 2. 三条证据线各自证明了什么

### 2.1 驱动侧（[RX-TX-BOUNDARY.md](./RX-TX-BOUNDARY.md)）

- **[实测静态]** 管理帧总入口 `0x1402d0ad0`（`hmfmEvRxMgmtFrame`）按帧控制字节分派，0xD0（Action）分支落在 `0x1402d27ed`，其中 `0x1402d280c` 调用 `prvHmfmHandleActionFrame`。
- **[实测静态]** 但类别 **0x7f（厂商自定义）** 在该函数里只落 `break`，不做处理。
- **[实测静态]** 面向 OS 的上报走另一条路：`0x140035660` 组装 indication `0x40050067`，负载是 BSSID + 信道 + 帧体。
- **[文档]** 该 indication 就是 `NDIS_STATUS_WDI_INDICATION_ACTION_FRAME_RECEIVED`，负载确实只有 `WDI_TLV_ACTION_FRAME_BODY` 等，**没有完整 MAC 头**。
- **[实测静态]** 发送侧内部确实构造原生 802.11 头（`0x140171560`），但入口是 NDIS 发送路径，且有 peer/队列/加密门控。
- **[实测静态]** IHV 私有通道（OID `0x0d01035c`）前置 `IsClientElevated`、`IsIntelOnlyApplication`、`ValidateClient`（校验签名者 `Intel Corporation`）。

### 2.2 radio 契约侧（[dropbridge-radio/REPORT.md](./dropbridge-radio/REPORT.md)）

AX201 若想当 DropBridge 的后端，必须同时提供五条：

1. **整帧透明注入** —— 上层已构造好 802.11 头，后端不得重写；
2. **自有 MAC 可设**（`SET_ADDRESS`）；
3. **逐时隙换台可确认**；
4. **RX 整帧带 radiotap + RSSI 上报**；
5. **硬件 ACK**（µs 级，软件不参与）。

**[源码事实]** 仓库里 devourer 的 14 个调用面中，只有 `send_packet` / `StartRxLoop` / `Stop` 三个与硬件无关；其余是固件、EFUSE、H2C 0x1D/C2H 0x10、FastRetune、功率、coex、USB claim。

也就是说：**协议层可复用，硬件层完全不可复用**，且 AX201 连第 1、2、3 条都提供不了。

### 2.3 AWDL 上层侧（[dropbridge-awdl/REPORT.md](./dropbridge-awdl/REPORT.md)）

- **[源码事实]** **AWDL 协议本体不在快照里**：邻居发现、同步、选举、时隙调度都在 `upstream/winawdl/awdl`，而 `upstream/` 被 gitignore 排除。全仓 `availability window` 零命中。
- **[源码事实]** 可复用的是 `src/awdl_netd`（lwIP IPv6/NDP + mDNS + TCP 代理）、host_if IPC 契约、`radio_link` v3 定义、supervisor 编排、蓝牙 beacon。
- **[源码事实]** 两个契约缺口：awdld 每次启动随机 MAC（与第 2 条冲突）；TX 速率只在 bring-up 设一次。

这一侧还给出了一个很重要的判断：**生死门是 S1（第三方能否发出指定类别/OUI/源地址的管理帧）和 S2（用户态能否看到 0x7f 帧）**，二者任一失败，后面的时隙、IPv6、TLS 全部无意义。

---

## 3. 三条线的交叉验证

值得记录的是，三条独立分析在关键点上互相印证：

| 判断 | 驱动侧 | 上层侧 |
|---|---|---|
| 源 MAC 由驱动/端口决定 | `0x140141440` 由端口上下文构造地址 | awdld 期望随机 MAC，与 WDI 冲突 |
| 0x7f 不进用户态 | dispatcher 只 `break` | S2 判定「很可能失败」 |
| 需要整帧透明注入 | 内部虽有原生头，但无用户态入口 | 契约第 1 条硬性要求 |

---

## 4. 如果仍要继续，代价排序

1. **换硬件**（最现实）：用支持 monitor + 注入的外置网卡，走 Npcap 原始收发。radio_link 之上全部可复用，只需重写后端。代价：偏离「用本机 AX201」。
2. **内核驱动改造**（最贵）：在 Netwtw14 上加受控原始收发接口。要处理驱动签名、HVCI、CNVio2 初始化、固件命令构造，且**固件是否允许任意帧发送仍是未知数**。
3. **继续静态逆向**（最便宜，但边际收益递减）：把 `0x140049690` 剩余 887 行读完、还原 `0x120000`/`0x10000`/`0x20000` 过滤位、确认 IHV 通道是否存在发送 Action Frame 的 opcode。

第 3 条能提高「如果改驱动，需要改哪里」的确定性，但**不会改变第 1 节的裁定**。

---

## 5. 建议

若目标是「尽快让 iPhone 认出这台机器」，应走第 1 条，并接受不再使用 AX201。

若目标是「证明 AX201 在原理上可行」，则下一步应先做**只读的固件侧勘查**：确认固件命令表里是否存在任意帧发送原语。这是唯一还能改变结论的方向，且不需要改驱动、不需要发射。

不建议在没有固件侧证据前投入驱动改造。

---

## 6. 交付物索引

| 文件 | 内容 |
|---|---|
| [RX-TX-BOUNDARY.md](./RX-TX-BOUNDARY.md) | 驱动收发边界、分派表、上报路径、平台证据 |
| [dropbridge-radio/REPORT.md](./dropbridge-radio/REPORT.md) | radio_link v3 逐字段契约、生命周期、可复用分层 |
| [dropbridge-awdl/REPORT.md](./dropbridge-awdl/REPORT.md) | AWDL 上层可复用面、契约缺口、S0–S7 验收顺序 |
| [TARGETED-REVERSE.md](./TARGETED-REVERSE.md) | 前序：IHV 请求封套、Action Frame 构造、分派表静态结果 |
| [HANDOFF-MODEL-SWITCH.md](./HANDOFF-MODEL-SWITCH.md) | 模型切换时的状态交接 |

本轮未修改驱动、未操作无线硬件、未执行仓库脚本、未下载依赖。
