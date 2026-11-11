# OID 通道实测记录

2026-11-11。已安装 Npcap 1.90 并执行真实 OID 请求。所有测试可回滚，未修改驱动、未改安全启动。

## 1. 结论摘要

| 通道 | 结果 |
|---|---|
| Npcap `PacketRequest` + 标准 OID | **成功**（读回真实 MAC `04ECD8F48891`） |
| Npcap + Intel 私有 OID（`0xFF100015` 等） | 失败，`0xC00000BB`（`STATUS_NOT_SUPPORTED`） |
| Npcap + DOT11 私有 OID（`0x0D01011A/11B`、`0x0D01035C`） | 失败，`0xC0010017`（`NDIS_STATUS_INVALID_OID`） |
| `WlanIhvControl`（以 Network Service 身份） | 失败，`ERROR_ACCESS_DENIED` |

两条用户态路径都走不通，原因不同：Npcap 只转发标准 NDIS OID；`WlanIhvControl` 被 DACL 锁死。

## 2. Npcap 通道

安装：Npcap 1.90，签名有效（Nmap Software LLC，2027-06 到期），SHA256 `682B57E1…1199B6`。驱动 `npcap.sys` 已运行，`nmap_npcap` 与 `nmap_npcap_WIFI` 绑定均启用。

技术要点：

- `PacketOpenAdapter` 需要**设备名原样** `\Device\NPF_{GUID}`，传 `\\.\NPF_{GUID}` 会返回 `ERROR_INVALID_NAME`。
- `PacketRequest` 内部走 `DeviceIoControl`，IOCTL `0x216824`（查询）/ `0x21A820`（设置），设备类型 `0x21`（NDIS）。

实测矩阵：

| OID | 名称 | 状态 |
|---|---|---|
| `0x01010102` | `OID_802_3_PERMANENT_ADDRESS` | 成功，返回 `04ECD8F48891` |
| `0x0001010C` | `OID_GEN_VENDOR_DESCRIPTION` | 成功 |
| `0x00010103` | `OID_GEN_VENDOR_DRIVER_VERSION` | 成功 |
| `0xFF100015` | `OID_WIFI_FIRMWARE_VERSION` | `0xC00000BB` |
| `0xFF100014` | `OID_WIFI_DEVICE_INFORMATION` | `0xC00000BB` |
| `0xFF40003C` | `OID_SV_DRIVER_VERSION` | `0xC00000BB` |
| `0x0D01011A` | `OID_SV_EXECUTE_SNIFFER_CMD` | `0xC0010017` |
| `0x0D01011B` | `OID_DOT11_CURRENT_OPERATION_MODE` | `0xC0010017` |
| `0x0D01035C` | `OID_DOT11_NIC_SPECIFIC_EXTENSION` | `0xC0000184`（查询）/ `0xC0010017`（设置）|

注：状态值带 `0x20000000` customer 位，实际含义为去掉该位后的值。

**交叉验证**：Npcap 自带的 `WlanHelper` 能成功读 `mode`（managed）与 `channel`（1），但它走的是 WlanAPI 而不是 `PacketRequest`，因此不能证明私有 OID 可经 Npcap 下发。相反，我们对同一个 `0x0D01011B` 用 `PacketRequest` 发送就失败了。

**判定**：Npcap 的 `PacketRequest` 只支持标准 NDIS OID；Intel 私有 OID 无法通过它下发。

## 3. `WlanIhvControl` 通道

做法：编译一个最小 EXE，用 `sc create` 注册为以 `NT AUTHORITY\NetworkService` 运行的服务，执行后立即删除。

实测（`sc qc` 确认 `SERVICE_START_NAME : NT AUTHORITY\NetworkService`，EXE 内 `WindowsIdentity` 也确认 `NT AUTHORITY\NETWORK SERVICE`）：

| 调用 | 结果 |
|---|---|
| `WlanOpenHandle` | 成功 |
| type=1（driver），16 字节输入 | `ERROR_ACCESS_DENIED` |
| type=0（service），16 字节输入 | `ERROR_ACCESS_DENIED` |
| 输入长度为 0 | `ERROR_INVALID_PARAMETER`（先于 DACL 校验） |

**根因**：`wlan_secure_ihv_control` 的 DACL 末尾是 `(D;;FA;;;WD)` —— 对 Everyone 的拒绝 ACE。Windows 的 `AccessCheck` 先评估所有拒绝 ACE，因此该对象实际上对**所有人**（含管理员与 Network Service）关闭。

这也解释了为什么 `WlanGetSecuritySettings` 能读出 SDDL：读操作走的是另一条路径。

## 4. 由此确定的两个选项

1. **改 `wlan_secure_ihv_control` 的 DACL**：取得所有权后写入新 DACL，只放行 Administrators 与 SYSTEM，测试完恢复原串。可逆，但属于主动修改安全设置。
2. **自写内核组件**：绕过用户态 API，直接向 miniport 发 OID。需要测试签名，也就是关闭 Secure Boot 与 HVCI。

在此之前，还有一项事实尚未确认：即使打通通道，驱动是否接受我们构造的 IHV 请求体。若接受，方案 1 就足以验证；若不接受，则必须走方案 2。

## 4.1 打开 DACL 之后的实测（Wi-Fi 已连接）

临时把 `wlan_secure_ihv_control` 的 DACL 改为只放行 BA/SY/NO（去掉 Everyone 拒绝项），测完**已还原并核对一致**。

| 调用 | 结果 |
|---|---|
| `type=1`（driver），16 字节全零 | `0x1F` ERROR_GEN_FAILURE |
| `type=1`，8 / 64 字节全零 | `0x1F` |
| `type=1`，8 字节头 + 64 负载（type 1/2/4/5/6/7 各试） | `0x32` ERROR_NOT_SUPPORTED |
| `type=1`，12 字节头 + 64 负载（type 1/2） | `0x32` |
| `type=0`（service），任意非零长度 | `0x37` ERROR_DEV_NOT_EXIST |
| `type=0`，长度 0 | `0x57` ERROR_INVALID_PARAMETER |

关键点：**结果与内层格式无关，也与端口是否连接无关**。

判定：`WlanIhvControl` 是 Native 802.11 时代的接口。它的两条后端在这台机器上都不存在——`type=service` 找不到 IHV 服务上下文（`ERROR_DEV_NOT_EXIST`），`type=driver` 的 `OID_DOT11_NIC_SPECIFIC_EXTENSION` 对 WDI 小端口无意义（`ERROR_NOT_SUPPORTED`）。

因此 **Netwtw14 是 WDI 驱动，用户态没有任何路径能下发私有 OID**。DACL 只是第一道门，门后是空的。

## 4.2 结论

用户态路线（WlanIhvControl、Npcap PacketRequest、IHV DLL 客户端）全部实测排除。要下发私有命令，只能由**自写内核组件**直接向小端口发 OID。

## 5. 现有回滚点

- 驱动包已完整备份并逐一哈希校验：`C:\ProgramData\AX201work\rollback\driver-package\`
- 系统还原点 `AX201-pre-driver-mod` 已创建
- Npcap 可用官方卸载程序移除
- 服务 `Ax201IhvProbe` / `Ax201IhvProbe2` 均已删除
