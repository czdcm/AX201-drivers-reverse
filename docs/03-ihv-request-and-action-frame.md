# AX201 定向逆向：IHV 请求与 Action Frame

> **暂停交接**：用户随后要求切换模型，当前任务已暂停。新增两轮能力分析、最新证据、待办与恢复约束见[模型切换交接](./HANDOFF-MODEL-SWITCH.md)。本文件保留前一阶段结论，不含最新两轮的全部发现。

2026-11-11。用户已明确允许少量 Ghidra 分析辅助脚本。本轮只做离线静态分析；不调用 IHV 服务，不发送 OID，不打开设备，不修改/加载驱动，不初始化硬件，不发射测试帧，不启动子智能体。

## 1. 结论先行

1. 已经从“存在相关字符串”推进到具体函数、参数搬运、分派和部分帧构造逻辑，有可以复核的汇编与伪代码。
2. 找到的是 **WDI/IHV 控制路径和受驱动管理的 Action Frame 发送路径**，尚不是可供 DropBridge 使用的 raw-radio 后端。
3. Action Frame 路径会构造 24 B MAC 头，并走端口、状态、信道和驻留时间管理；不能把它当作整帧透明注入接口。
4. IHV DLL 中确有客户端验证、Intel 应用类别判断、会话状态检查。不能认为知道 RPC endpoint 或请求布局就能合法、直接取得所有无线能力，也不能认为管理员权限自动解决限制。
5. 仍未证明 AWDL 所需的 vendor-specific Action Frame、原始 Data Frame、RX 上报、地址/BSSID 控制与换台时序全部可用。**尚未完成完整驱动/固件逆向，不能进入“已经知道该怎么改”的阶段。**

## 2. 本轮方法与交付

只有一个自写辅助脚本：[Ax201ReadOnlyExport.java](./scripts/Ax201ReadOnlyExport.java)。它调用 Ghidra 自带反编译器，导出所选函数的伪代码、汇编、调用者/被调用者、函数入口引用、字符串引用及有限的静态数据表探针；不包含二进制写入、函数重命名、类型改写或项目保存操作。运行参数始终为 `-noanalysis -readOnly`。

脚本使用当前配置选择函数，最多 54 个/次；每函数反编译超时 25 秒、每次总预算 240 秒，汇编每函数最多 1200 条。第一次版本之后只增加了静态表探针，仍是同一只读导出脚本。

七次导出共产生 172 条函数导出记录，去重为驱动 86 个、IHV DLL 49 个；172 条均报告 decompileCompleted=true。**这是工具完成导出，不表示已人工理解全部 135 个函数。** 人工核查以本文列出的代码段为准。

[运行与证据清单](./TARGETED-EVIDENCE-MANIFEST.json) 记录每次输入哈希、数量、证据文件哈希和最终脚本哈希；[各轮 JSON 配置](./config/driver-r1.json) 可复用，其他配置位于同目录。没有依赖临时盘符。

驱动样本 SHA256 仍为 `87C083010DAD3FB6AC8CAC99DDB5E274DF300DA789CC8774B4A25DA137DA38B8`，DLL 仍为 `60B7F7BC371E711FDA6BD957A252F779B4D326F9637BFD4751D27D88826B9ACF`。与前轮留存值一致。

## 3. 驱动注册：由导入名推进到真实初始化

[0x14000d320](./decompile-driver-r1/14000d320.c#L140-L194) 实际检查 NDIS 版本、构造回调结构并调用 NdisMRegisterWdiMiniportDriver；[其上层 0x140120760](./decompile-driver-r1/140120760.c#L16-L41) 将注册失败与固件存储初始化失败分开处理。

原先从 entry 的调用关系推测的 `0x1405d3000`，实际是 [安全 cookie 检查/初始化辅助](./decompile-driver-r1/1405d3000.c#L10-L17)，不是业务 DriverEntry。该项已纠正，后续不沿错误命名展开。

注册结构的伪代码由于缺少准确类型，被拆成大量栈字节变量；这不是完整、已恢复的 WDI 回调结构定义。对应 [汇编](./decompile-driver-r1/14000d320.asm.txt) 保留作后续结构重建依据。

## 4. IHV 请求：已恢复的分层

### 4.1 前轮两个候选入口只是解析包装层

[0x14001ed80](./decompile-driver-r1/14001ed80.c#L3-L8) 仅从消息长度减去 0x10、从缓冲区跳过 0x10，然后调用 ParseWdiIhvRequest。

[0x140032cb0](./decompile-driver-r1/140032cb0.c#L3-L9) 对 Action Frame 请求做相同风格的参数转交。它们均不能单独代表真实执行路径。

通过字符串交叉引用与静态函数指针表，定位到了真正的 IHV execute：

[0x14001e830](./decompile-driver-r1/14001e830.c#L19-L85) 调用打包辅助与私有请求翻译；随后有特殊请求分支、两张分派表查找，以及未支持时返回 `0xc00000bb` 的分支。该状态常量也在 [汇编第 138 行](./decompile-driver-r1/14001e830.asm.txt#L138) 直接出现。

### 4.2 内部请求与封套，不是任意缓冲直接透传

[0x14001eda0](./decompile-driver-r1/14001eda0.c#L23-L108) 的可确认事实：

- 检查解析参数中的存在位；
- 按 0x18 B 描述项遍历分片，累计长度并检查溢出；
- 拼接分片，追加 0x10 B 尾部校验/哨兵数据；
- 构造内部请求，写入字面值 OID `0x0d01035c`。

[0x1400f6590](./decompile-driver-r2/1400f6590.c#L22-L75) 至少要求 8 B 内层头，取得请求编号、16 位操作类别与载荷指针，对类别 1/2/4/5/6/7 分别处理，随后调用额外解封装逻辑。

[0x1400f0d90](./decompile-driver-r3/1400f0d90.c#L10-L92) 只对特定编号族应用额外的 12 B Intel 封套检查；会检查长度和类别，不能将所有编号族统一视为相同请求格式。

这里尚未命名所有字段或生成可执行请求程序。OID `0x0d01035c` 的字面值来自样本；微软的 NIC-specific extension 文档用于解释类似 IHV 方法通道的设计，不在没有 SDK 常量核对时把数值映射当成另一条独立证据。

### 4.3 分派表的静态结果与局限

[第二轮数据探针](./decompile-driver-r2/evidence.json) 读取了两个查表位置。静态样本中，`0x1405ae000` 的首个编号为 0；`0x1405ae050` 包含编号 `0xff100123`，处理指针为 `0x14015d0c0`。

[查表函数 0x1400f0640](./decompile-driver-r2/1400f0640.c#L10-L23) 以 0x50 B 为步长，按首个 DWORD 编号匹配，以编号 0 结束。

[0x14015d0c0](./decompile-driver-r3/14015d0c0.c#L42-L77) 不等于原始 TX：它先尝试下层 OID 映射；未走该映射时还按操作类别转入其他处理分支。

**不能外推**：这里只说明这两张表和这个静态样本的读取结果；未证明它们覆盖所有控制接口、所有机型或运行时路径，也未证明内存中不会发生初始化变更。不会以“看到一个条目”宣布整个驱动只支持一个私有请求。

## 5. Action Frame：已经恢复的真实处理链

### 5.1 请求字段与内部状态

[0x1400329a0](./decompile-driver-r1/1400329a0.c#L15-L39) 的日志参数清楚对应 ChannelNumber、SendTimeout、PostACKDwellTime。

[0x140032bc0](./decompile-driver-r2/140032bc0.c#L29-L37) 将请求数据整理后交给 `0x140140e90`；[该函数](./decompile-driver-r3/140140e90.c#L3-L8) 再转入 [0x140142810](./decompile-driver-r4/140142810.c#L59-L71)。后者保存请求/响应标志、端口标识、目的地址、信道/频段及缓冲区相关字段，再进入状态处理。

[0x140141580](./decompile-driver-r2/140141580.c#L11-L80) 会查询端口上下文，按场景返回不同处理分支。它不是一个独立于 Windows WLAN 端口的 raw socket。

### 5.2 可复核的 MAC 头构造

[0x140141440](./decompile-driver-r2/140141440.c#L10-L28) 查找端口/VIF 上下文，清零输出帧，把请求体复制到偏移 0x18，再写入帧控制字段 `0x00d0`；目的地址、源地址与 BSSID 由参数和端口上下文构造。

关键区别是：**调用方提交的是这里接受的 Action Frame 数据，最终 MAC 头由驱动决定，不是把 DropBridge 的 radiotap + 完整 802.11 帧原样送出。**

这并不证明 AWDL Action Frame 一定不可用——AWDL 本来使用 Action Frame；但是否接受其类别/OUI、目标地址/BSSID、并发与时序，尚需继续查验证与调度路径。

### 5.3 DAF / DP 与下层消息

[0x140142110](./decompile-driver-r3/140142110.c#L16-L59) 按状态决定发起新 DAF、停止旧请求或清理；[DP 路径](./decompile-driver-r3/140142360.c#L53-L83) 依赖有效端口并建立受保护的发送时段。

[0x140142c60](./decompile-driver-r3/140142c60.c#L59-L168) 分配“请求体长度 + 0x18”的帧缓冲，调用 MAC 头构造；处理发送与驻留参数、裁剪部分计数，并带回调提交给 `0x1402cc2e0`。

[0x1402cc2e0](./decompile-driver-r4/1402cc2e0.c#L49-L77) 生成请求标识、设置字段并将编号 `0x1b9` 的内部消息交给下一层。**当前只确认它是该层的消息编号，尚不能称为已还原的固件 opcode。**

仍缺：DAF/DP 选择的完整条件、底层固件命令布局、各通知的时间语义与实际尾延迟。

## 6. Operation Mode：未找到“开个开关就能 monitor”的证据

[模式切换处理 0x140027440](./decompile-driver-r3/140027440.c#L10-L25) 会调用 [utilOpModeToMacType，0x1400432a0](./decompile-driver-r4/1400432a0.c#L6-L24)。在这个转换函数中，显式处理的输入值只有 `1、8、0x10、0x20`，其他值进入诊断分支并返回另一内部类型。

**这只是该转换路径的结果**：没有确认 monitor RX 模式，没有找到可直接使用的 monitor OID，也不能据此证明整个驱动或所有私有接口绝无其他模式。不能把诊断 monitor 字符串或这个默认返回值当作可用监听模式。

## 7. IHV DLL：请求格式和访问边界

### 7.1 已确认本地 RPC 服务，但 endpoint 不等于无线权限

[0x18003d4f0](./decompile-ihv-r1/18003d4f0.c#L25-L45) 使用 `ncalrpc` 和 `IntelIhvRpcEndpoint`。其 [汇编第 50–58 行](./decompile-ihv-r1/18003d4f0.asm.txt#L50-L58) 表明 RpcServerRegisterIf3 有 8 个参数；伪代码只显示 4 个，是不完整函数原型导致的反编译损失，不能忽略栈上的参数。

结合微软文档可以确认：本次该调用未传入显式接口安全描述符/安全回调，但这**不等于服务没有访问控制**，默认 RPC 安全语义和方法内部验证仍然存在。

### 7.2 会话验证与发 OID 的方法检查

[RemoteSessionOpen，0x18003eaa0](./decompile-ihv-r3/18003eaa0.c#L114-L132) 查询客户端信息、调用验证与应用类别判断；在 [第 291–297 行](./decompile-ihv-r3/18003eaa0.c#L291-L297) 将验证是否成功及提权相关结果传入会话构造器。构造器字段对应关系本轮未继续导出，因此不擅自给所有会话字节命名。

[ValidateClient，0x18000c540](./decompile-ihv-r2/18000c540.c) 会打开客户端进程、获取映像相关信息并验证签名；[证书辅助 0x18000bf50](./decompile-ihv-r2/18000bf50.c#L145-L159) 检查签名者名称 `Intel Corporation`。这个流程与应用类别检查有关，**不能概括成“所有 RPC 方法都必须 Intel 签名”**。

[IsClientElevated](./decompile-ihv-r2/18000bdd0.c#L23-L41) 使用系统封装；其 [底层实现](./decompile-ihv-r1/1800692d0.c#L37-L80) 查询进程令牌的 TokenElevation。

[RemoteDrvSendOid，0x18003ffc0](./decompile-ihv-r2/18003ffc0.c#L39-L120) 实际检查会话是否存在、类型字段是否为 2、以及会话偏移 0x31 的状态标志；不满足则返回错误。没有证明普通第三方应用可以获得满足条件的会话，也没有尝试绕过这些限制。

### 7.3 OidSender 的封套字节布局（仅静态观察）

[0x18006af00](./decompile-ihv-r1/18006af00.c#L26-L54) 分配 `payload_length + 0x1c`，清零并构造封套。可从代码直接复核的写入如下：

| 相对偏移 | 字面操作 |
| --- | --- |
| 0x00 | 写入请求编号参数 |
| 0x04 | 写入 16 位操作类别参数 |
| 0x08 | 写入 payload_length + 0x10 |
| 0x0c | 再次写入同一 16 位类别 |
| 0x0e | 写入另一个 16 位参数 |
| 0x10 | 写入 0 |
| 0x14 | 复制载荷 |

代码存在整数加法溢出边界检查。随后经对象虚函数 `+0x10` 发送，见 [汇编第 71–87 行](./decompile-ihv-r1/18006af00.asm.txt#L71-L87)。尚未把这个虚函数的所有具体实现与驱动端每一层封套做逐字段闭合；上表不是已经验证的公共 ABI，也未据此构造测试请求。

## 8. 对 AWDL 可行性的实际意义

当前最有希望继续研究的是驱动已经存在的 Action Frame + IHV 控制能力，而不是一开始就修改 SYS。

但要实现 DropBridge 后端，还必须分别证明：

- AWDL 所需 Action Frame 的类别/内容与地址组合能通过验证并实际发出；
- Data Frame 的发送与接收不被现有连接模式限制，且所需帧能上报用户态；
- 可以满足用户态调度要求地控制信道/驻留，测得尾延迟，而非只有功能名；
- ACK、重试、队列回压、取消与恢复语义可用；
- 有第三方应用可使用的合法调用路径，而非只存在于受限内部客户端。

现有静态证据只覆盖其中部分控制与 Action Frame 构造路径。不能把“Action Frame 发送”当成“原始 Data Frame 注入”，也不能把“有 RX indication”当成“全部 AWDL 帧可捕获”。

## 9. 下轮具体工作，不需要立刻安装新工具

1. 追 `0x140142a80` 的接收参数/状态验证与 Action Frame 过滤，继续判断 vendor-specific 类别的接受条件。
2. 将关键 CFG 间接调用还原到具体对象/虚函数，闭合 IHV DLL 到 NIC-specific extension 的转发链；恢复会话构造器字段。
3. 沿 `0x1402cc2e0` 的内部消息提交向下查命令描述、通知、ACK 与固件交互；不能把 0x1b9 提前命名为固件指令。
4. 单独审阅 Data Frame 的 TX/RX 路径及过滤，不再只追管理帧。
5. 静态证据足够后，先制定只读/最小化硬件验证和恢复计划，再单独取得授权。不在本轮开启测试签名、关闭安全机制或替换当前联网驱动。

## 10. 已知工具与证据限制

- 中文路径仍引起 Ghidra 日志配置告警，但已将每次控制台输出保存为本文同目录的 run.log。所有结论另外检查了 evidence.json、C 与汇编，不只看退出码。
- Ghidra 对 CFG 间接调用、自动类型、FID 同名函数和栈结构会丢失参数或产生误名；本文明确区分已核对的汇编与未闭合的推断。
- 伪代码里的 `__security_check_cookie replaced with injection` 是 Ghidra 分析期替代语义提示，不是本轮对驱动进行了代码注入或修改。
- 数据探针读取的是导入文件的静态映像，不是运行中内核内存。
- 固件容器、处理器架构、签名校验与完整固件 ABI 仍未还原；没有写专用固件解包器。

## 11. 核对过的微软文档

- [Dot11ExtNicSpecificExtension](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wlanihv/nc-wlanihv-dot11ext_nic_specific_extension)：IHV 自定义方法、数据由厂商定义，支持与否由驱动决定；Native 802.11 接口已弃用，不应当作 Win11 能力保证。
- [OID_DOT11_NIC_SPECIFIC_EXTENSION](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/oid-dot11-nic-specific-extension)：为 IHV DLL 保留的方法通道，不是任意应用通用 raw TX API。
- [OID_WDI_TASK_SEND_REQUEST_ACTION_FRAME](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/oid-wdi-task-send-request-action-frame)：Action Frame body、信道、ACK、重试及 Post-ACK dwell 的任务语义；不等于完整 802.11 帧透明注入。
- [RpcServerRegisterIf3](https://learn.microsoft.com/en-us/windows/win32/api/rpcdce/nf-rpcdce-rpcserverregisterif3)：8 个参数、默认安全描述符与回调语义，避免被不完整伪代码误导。
