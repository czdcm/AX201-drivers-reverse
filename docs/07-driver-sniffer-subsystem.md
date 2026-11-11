# 驱动层可行性：AX201 已有 sniffer 子系统

2026-11-11。只读静态分析。未修改驱动、未加载驱动、未发任何 OID。

## 1. 结论

**不需要从零实现原始接收——驱动里已经有一整套 sniffer（嗅探）实现。**

这修正了此前「AX201 不支持 monitor」的判断边界：Intel 对外宣称不支持，但**这份驱动二进制里带着 sniffer VIF、radiotap 构造和专用固件命令组**。它被关掉了，不是不存在。

因此「改驱动接收 目标协议」的工程量，从「重写收包路径」降到「打开并接通已有路径」。

## 2. 证据

`Netwtw14.sys` 中的 sniffer 相关符号：

| 符号 | 含义 |
|---|---|
| `MAC_TYPE_SNIFFER` | MAC 类型枚举里的独立一项 |
| `SNIFFER_VIF` / `"SNIFFER VIF "` | 独立的 VIF 类型与名字前缀 |
| `snifferVifCreateAPI` | 创建 sniffer VIF 的 API |
| `SNIFFER_CMD_ARGUMENTS` | 参数结构体 |
| `pSnifferCmdArguments->snifferCmd` / `controlChannel` / `controlChannelLocation` / `channelWidth` / `band` | 命令、控制信道、信道位置、带宽、频段 |
| `OID_SV_EXECUTE_SNIFFER_CMD` | 执行 sniffer 命令的私有 OID |
| `GRP_DATAPATH_HE_AIR_SNIFFER_CONFIG_CMD` | 对应的固件命令组（HE = 802.11ax） |
| `snifferUpdateRadiotapMCS` / `...VhtBandwidth` / `...He` | **驱动自己拼 radiotap 头** |
| `DataPathMonitorEnabled` | 疑似注册表开关名 |

`snifferUpdateRadiotap*` 是最关键的一条：radiotap 是无线路由/监听工具的通用封装格式。驱动主动构造它，说明设计目的就是**把原始 802.11 帧交给某个外部消费者**。

## 3. MAC 类型枚举还原

字符串表按顺序给出七项：

| 索引 | 名称 |
|---|---|
| 0 | `MAC_TYPE_STA` |
| 1 | `MAC_TYPE_SOFT_AP` |
| 2 | `MAC_TYPE_WFD_DEVICE` |
| 3 | `MAC_TYPE_WFD_GO` |
| 4 | `MAC_TYPE_WFD_CLIENT` |
| **5** | **`MAC_TYPE_SNIFFER`** |
| 6 | `MAC_TYPE_UNIDENTIFIED` |

对照前一轮还原的 `utilOpModeToMacType`（`0x1400432a0`）：

| 输入 operation mode | 输出 MAC 类型 |
|---|---|
| 1 | 0（STA） |
| 8 | 2（WFD_DEVICE） |
| 0x10 | 4（WFD_CLIENT） |
| 0x20 | 3（WFD_GO） |
| 其它 | **6（UNIDENTIFIED）** |

**没有任何输入映射到 5（SNIFFER）。** 这是精确结论，不是「没找到」：该函数只有这四个 case，默认返回 6。

也就是说：WDI 操作模式这条路**结构上到不了 sniffer**；sniffer 必须从另一个入口创建（`snifferVifCreateAPI`），或由私有 OID 触发。

## 4. 三条可选路线（都在驱动层）

### S1：私有 OID 触发（最轻，优先验证）

`OID_SV_EXECUTE_SNIFFER_CMD` 属于 `OID_SV_*` 私有命名空间，同族还有 `OID_SV_DIRECT_ACCESS`、`OID_SV_INDIRECT_ACCESS`、`OID_SV_PCI_CFG`、`OID_SV_NVM_CACHE_READ`、`OID_SV_COMMAND`——这一看就是 Intel 内部诊断/产测用的接口面。

如果驱动接受这个 OID，就能直接下发 `SNIFFER_CMD_ARGUMENTS`（信道/带宽/频段）启动嗅探。**这是唯一可能完全不用改 Intel 二进制的方法。**

问题在于「谁能发这个 OID」：

- 用户态：`WlanIhvControl` 的 driver 类型，但被 `wlan_secure_ihv_control` 的 DACL 挡住（实测只有 Network Service 有写权）。
- **内核态：一个自写的 NDIS 轻量过滤器（LWF）可以直接向底层 miniport 发 OID 请求，完全绕开上述 DACL。**

后者是这条路线真正的价值：**不修改 Intel 驱动，只增加一个我们自己的小驱动。**

### S2：小补丁接通数据面

若 S1 能让固件进入嗅探模式，但帧没有送到任何可取的地方，就在驱动里把 sniffer 的接收回调接到一个新的设备接口（IOCTL / 命名设备），供用户态读取。

这一步需要实际修改 `Netwtw14.sys`。

### S3：完整收发补丁

只有在 S1、S2 都失败时才考虑：自己实现原始收发与信道调度。这是最初设想的重方案。

## 5. 仍然成立的硬约束

无论走哪条，有四件事没有变：

1. **驱动签名**：任何自写内核组件或修改后的 `Netwtw14.sys`，都要开测试签名；改 Intel 驱动还要**关闭 HVCI 与 Secure Boot**。这是整机安全等级的实质下降，必须单独授权。
2. **固件是否支持**：驱动里有 `GRP_DATAPATH_HE_AIR_SNIFFER_CONFIG_CMD`，但 AX201 量产固件是否响应这条命令，**静态无法确定**。这是整个方案最大的未知。
3. **发送仍未解决**：接收 目标协议 的前提是被发现，需要发 对等发现协议 同步帧。sniffer 只解决「收」。
4. **源地址**：对等发现协议 需要可控 MAC，目前由端口上下文决定。

## 6. 建议的下一步

先做**只读**的两件事，都还不涉及改驱动：

1. 追 `snifferVifCreateAPI` 的调用方与前置条件，确认它是被编译期宏关掉、被注册表关掉，还是只由私有 OID 触发。
2. 还原 `OID_SV_EXECUTE_SNIFFER_CMD` 的处理函数与 `SNIFFER_CMD_ARGUMENTS` 布局，判断它是否真的会驱动固件。

做完这两步，就能判断 S1 是否值得投入。若 S1 可行，整个方案的代价从「改 5.6 MB 闭源驱动」降到「写一个小型 NDIS 过滤器」，这是数量级的差别。

## 7. 边界声明

本文件结论全部来自静态符号与已还原函数，**没有任何硬件验证**。特别地：

- 「驱动里有 sniffer 代码」≠「AX201 固件允许嗅探」。
- 「有 `OID_SV_EXECUTE_SNIFFER_CMD` 名字」≠「该 OID 在当前固件/机型上有效」。
- 上述任何一步都没有被执行。
