# AX201 固件命令表只读勘查

2026-11-11。范围：`Netwtw14.sys` 的 MHIF（host↔firmware 命令翻译）层，以及 `netwfw14.dat` 容器形态。全部只读：未加载驱动、未发命令、未操作硬件。

## 0. 先说结论

**固件命令层不缺「发帧」能力，缺的是把帧喂进去的合法入口。**

- 数据面已有 `mhiffBuildTxCommandVer10`，其上游就是「主机构造好 802.11 头 → 传给固件」的路径（前一轮已验证 `0x140171560` 会复制并改写 MAC 头）。
- 管理面另有专门的 `mhiffSendP2pActionFrameCmdVer1/2`，带独立通道、速率、重试与驻留参数。
- 换台有 `mhiffBuildChannelSwitchStartNotifVer3` + 取消 + **错误通知**，说明换台是固件执行且可能失败。

也就是说：把「固件不支持任意帧」当作否决理由并不成立；真正的封锁点在 NDIS/WDI 及其之上的访问控制。

## 1. 固件容器本身

`netwfw14.dat`（16,824,292 B，SHA256 `23FC171B…9DDB5A`）：

- DIE 判定为 `Binary / Unknown`，无已知文件头。
- 没有可识别的压缩/归档签名。
- 现有字符串与结构线索全部来自驱动侧，**没有从容器中解出可读命令表**。

**[推断]** 该容器是高熵/加密或私有分段格式，没有专用解包器无法推进。本轮**没有**为此编写工具（越权范围）。

因此本轮「固件命令表」的实际对象是**主机侧的 MHIF 命令定义**——这也是唯一具备可读结构的一侧。

## 2. MHIF 层结构

从字符串可确认三类命名：

| 前缀 | 作用 | 例 |
|---|---|---|
| `mibMhiffTbl*` | 命令表本体（构造/初始化/查表/设置） | `mibMhiffTblConstruct`、`mibMhiffTblGetEntry`、`mibMhiffTblInitialize` |
| `mhiffBuild*` / `mhiffTranslate*` | 逐命令的报文构造/解析，带版本号 | `mhiffBuildTxCommandVer10`、`mhiffTranslateAliveNotifVer6` |
| `prvMhiffTranslateCheckAndSend` | 统一出口：校验后下发 | `0x14016529c` 附近 |

命令用「名字 + 版本」区分，例如 `Ver1/Ver2` 并存说明存在向下兼容分支（`mhiffUpdateMhiffTblCommandVersion` 负责版本更新）。

## 3. 数据面发送命令（关键）

`mhiffBuildTxCommandVer10` → `FUN_140343380(src, ?, desc, len, out)`

- 要求输入长度 **≥ 0x1C**，否则返回 `0xc0000001`。
- 写入：
  - `out[0] = desc[0]`（u16 标志）
  - 从 `desc+0x24` 读 u32，**掩码 `0xFFFFE0FF`**（保留 bit 8–12），除非 bit30 已置位
  - `out+4 = 该 u32`
  - `out+8..0xF` 清零
  - 由 `desc+4` 的 bit2/bit4 置 `out` 标志位 2/4

**[推断]** 这是「TFD 式」命令：命令体只描述元数据，真正的帧字节通过描述符里的缓冲指针另行引用。因此该函数本身不限制帧内容，帧头由主机侧构造。

这与上一轮 `0x140171560`（复制/改写 802.11 MAC 头）互相印证：**主机能把带完整 802.11 头的帧交给固件。**

## 4. Action Frame 发送命令（关键）

`mhiffSendP2pActionFrameCmdVer2` → `FUN_1403455c0(src, srcLen, desc, bodyLen, out)`

约束：

- `srcLen >= 0x50`（源描述符至少 80 B），否则 `0xc0000001`
- `bodyLen <= 0x21B`（**539 B**），否则 `0xc0000001`
- 帧体拷贝上限 `0x200`（512 B）

输出布局（`out`）：

| 偏移 | 宽度 | 来源 | 说明 |
|---|---|---|---|
| 0x00 | u8 | src+0x10 | 帧类型/类别字段 |
| 0x01 | u8 | `FUN_1400ae300(*(u32*)(src+0x0C))` | 经转换的速率/信道相关值 |
| 0x02 | u8 | src+0x31 | 未命名 |
| 0x03 | u8 | src+0x44 | 未命名 |
| 0x04 | u8 | src+0x32 | 未命名 |
| 0x05 | u8 | src+0x34 | 未命名 |
| 0x06 | u16 | src+0x3C | 未命名 |
| 0x08 | u32 | src+0x40 | 未命名 |
| 0x0C | u32 | `(u32)*(u8*)(src+0x30)` | 未命名 |
| 0x10 | u32 | src+0x38 | 未命名 |
| 0x14 | u32 | src+0x08 | 同时作为拷贝长度 |
| 0x18 | 缓冲 | `*src` 指向的数据 | **帧体**，cap 0x200 |
| 0x218 | u32 | src+0x48 | 尾部字段 |

**[实测静态]** 因此这条命令**只接受帧体**，MAC 头由驱动侧补。对 AWDL 而言这是决定性的：AWDL 需要在 Action Frame 里指定自己的地址组合，而这里没有头字段可填。

## 5. 信道与时序相关命令

存在且带版本：

- `mhiffBuildChannelSwitchStartNotifVer3`
- `mhiffBuildMacCancelChSwitchVer1`
- `mhiffBuildLinkCancelChSwitchVer2`
- `mhiffTranslateChSwitchErrorNtfVer1/Ver2`

**[推断]** 换台是固件异步执行的操作，并有明确的**失败上报**路径。这对 AWDL 的逐时隙换台是必要条件，但也意味着「换台一定成功」不成立，必须处理失败与重试。

注意：这解决的是「能不能换台」，不解决「能不能在毫秒级精确换台」。后者的实测数据（0.22–0.28 ms）来自 Realtek 固件的快切路径，**不能外推到 AX201**。

## 6. 其它与 AWDL 相关的命令

| 命令 | 潜在用途 |
|---|---|
| `mhiffBuildAddStaCommandVer1` | 建立 peer/station 上下文 |
| `mhiffTranslateScdQueueCfgCmdVer3` | 发送队列配置 |
| `mhiffBuildRxMpduCommandVer5` | 接收 MPDU 相关 |
| `mhiffBuildSessionProtectionCommandVer1/2` | 会话保护（加密） |
| `mhiffBuildTimingMsmtRequestVer1` / `ConfirmVer1` / `NotifVer1` | 802.11mc 时序测量 |

## 7. 对「能否接收 AirDrop」的直接影响

接收 AirDrop 的前提是**先被对方发现**，而发现依赖 AWDL 的同步帧与 PSF，即**必须先发**。所以「只接收」并不能绕开发送能力。

三个必要条件，逐条对现状：

| 条件 | 现状 |
|---|---|
| 发出 AWDL 同步/发现帧（类别 0x7f） | Action Frame 命令只能填帧体，头由驱动定；类别 0x7f 在驱动内部 dispatcher 里未被处理 |
| 源地址可控（AWDL 需要自己的 MAC） | 由端口上下文决定，用户态不可设 |
| 毫秒级逐时隙换台 | 命令存在，但无 AX201 实测数据；且有失败路径 |

结论不变：**AX201 单独无法接收 AirDrop**，因为「接收」在协议上依赖「发送」。

## 8. 本轮产出与未完成

已确认：

- 固件容器不可读，命令表只能在主机侧还原；
- 数据面与 Action Frame 两条 TX 命令均存在并已还原字段布局；
- 换台命令族存在且带错误通知。

未完成：

- `mibMhiffTblConstruct`（`0x1400e6e10`，3530 单元）未展开——其中应是命令 ID ↔ 构造器 ↔ 版本 的映射表，是「完整命令表」的正主。
- `prvMhiffTranslateCheckAndSend`（`0x14016529c` 附近）未展开——统一校验出口，决定哪些命令在下发前被拒。
- 固件容器未解包，固件侧是否另有帧合法性校验未知。

## 9. 下一步建议

若继续，优先展开 `mibMhiffTblConstruct`，得到完整命令 ID 表；这是判断「是否存在一条未被访问控制覆盖的命令路径」的唯一途径。

但要提前说明：即便找到这样的路径，它仍在已签名的 `Netwtw14.sys` 里，任何利用都需要改驱动，属于新的授权级别。
