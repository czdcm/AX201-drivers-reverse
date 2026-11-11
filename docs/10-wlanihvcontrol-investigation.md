# 路线 A 勘查：`WlanIhvControl` 是否能免改文件触达驱动

2026-11-11。只读：仅静态分析 DLL + 一次只读 DACL 查询。未调用 `WlanIhvControl`，未修改任何设置。

## 1. 结论

**Intel 那一侧确实不设防，但 Windows 那一侧设了防。**

- **[实测静态]** `IntelIHVRouter14.dll` 的 `Dot11ExtIhvControl` 处理器（`0x18005a370`）**没有任何客户端校验**：只检查句柄非空、加共享锁、按索引取插件模块的派发函数指针并调用。没有提权检查、没有签名校验、没有会话状态检查。
- **[实测]** 但 `WlanIhvControl` 在进入 DLL 之前要过一道 DACL。实测 `wlan_secure_ihv_control`（对象 7）对我们的令牌只授予 `0x20001`（只读），**写权限仅授予 Network Service**。
- **[实测静态]** 该 DLL 的 IHV 处理器数组里**没有「接收原始数据包」这一项**——只有 `Dot11ExtIhvReceiveIndication`（NDIS 状态）与 `Dot11ExtIhvSendPacketCompletion`（发送完成）。

因此路线 A **默认不通**，且即使打通也解决不了接收。

## 2. 处理器表还原

`Dot11ExtIhvInitService`（`0x180056c40`）把 19 个处理器指针写入输出结构。从紧随其后的日志字符串可直接读出槽位名称：

| 顺序 | 处理器 | 指针 |
|---|---|---|
| 1 | `Dot11ExtIhvInitAdapter` | `0x1800577f0` |
| 2 | `Dot11ExtIhvDeinitService` | `0x180057b50` |
| 3 | `Dot11ExtIhvDeinitAdapter` | `0x180057eb0` |
| 4 | `Dot11ExtIhvPerformPreAssociate` | `0x180058200` |
| 5 | `Dot11ExtIhvPerformPostAssociate` | `0x180058490` |
| 6 | `Dot11ExtIhvStopPostAssociate` | `0x1800586d0` |
| 7 | `Dot11ExtIhvPerformCapabilityMatch` | `0x180058930` |
| 8 | `Dot11ExtIhvValidateProfile` | `0x180058b80` |
| 9 | `Dot11ExtIhvCreateDiscoveryProfiles` | `0x180058de0` |
| 10 | `Dot11ExtIhvProcessSessionChange` | `0x180059050` |
| 11 | `Dot11ExtIhvIsUIRequestPending` | `0x1800592c0` |
| 12 | `Dot11ExtIhvReceiveIndication` | `0x1800594a0` |
| 13 | `Dot11ExtIhvProcessUIResponse` | `0x1800596d0` |
| 14 | `Dot11ExtIhvQueryUIRequest` | `0x180059910` |
| 15 | `Dot11ExtIhvSendPacketCompletion` | `0x180059af0` |
| 16 | `Dot11ExtIhvAdapterReset` | `0x180059ce0` |
| 17 | `Dot11ExtIhvOneXIndicateResult` | `0x180059ed0` |
| 18 | `Dot11ExtIhvControl` | **`0x18005a370`** |

关键：**没有原始收包处理器**。这条 IHV 通道在设计上就不提供「把空口帧交给扩展 DLL」的能力。

## 3. `Dot11ExtIhvControl` 的实现

```
if (hSvcHandle == NULL) return 0x0D;              // ERROR_INVALID_DATA
AcquireSRWLockShared(&lock);
idx = FUN_18005a9f0(&moduleList);
if (idx == 0xFF) return 0x37;                      // ERROR_INVALID_PARAMETER
rc = module[idx].dispatch(hSvcHandle->ctx,         // 注意：从 param_1+0x18 取
                          controlType, inBuf, outSize);
ReleaseSRWLockShared(&lock);
```

要点：

- 派发目标来自 `&DAT_180185d10 + idx*0x2b0`，即**运行时加载的插件模块**（`GetProcAddress(hModule,"Dot11ExtIhvInitService")` 那一批）。
- 它把 `hDot11SvcHandle` 内部的上下文（`+0x18`）传下去，两个缓冲区原样转交。
- **没有任何调用方身份判断。**

这与我们此前在 RPC 路径上看到的 `IsClientElevated` / `IsIntelOnlyApplication` / `ValidateClient` 是两套完全不同的入口。之前那条结论「第三方被设计性挡在外面」只适用于 RPC 会话路径，**不能推广到 IHV 控制路径**。

## 4. Windows 侧的闸门

`wlan_secure_ihv_control` 实测 DACL（对象索引 7）：

```
O:SYG:SYD:(A;;CCRC;;;BU)(A;;CCRC;;;NO)(A;;CCDCWPSDRCWD;;;NO)
        (A;;CCRC;;;BA)(A;;CCDCWPSDRCWD;;;BA)(D;;FA;;;WD)
```

- 调用方被授予的访问掩码实测为 **`0x20001`**（读）。
- 对比对象 3 / 5 / 8（`max_profile_period`、`set_non_broadcast`、`show_denied_ex`），它们授予 `0x70023`（含写）。
- 写权限 `CCDCWPSDRCWD` 只出现在 **`NO`（Network Service）** 和 **`BA`（Administrators）** 的 ACE 里——但对象 **7 的 `BA` ACE 只有 `CCRC`**。

也就是说：**默认配置下，连管理员都没有 `WlanIhvControl` 的写权限，只有 Network Service 有。**

这与微软文档一致：`WlanIhvControl` 调用时读取 `wlan_secure_ihv_control` 的 DACL，缺少 `WLAN_WRITE_ACCESS` 就返回 `ERROR_ACCESS_DENIED`。

## 5. 这对路线 A 意味着什么

| 环节 | 结论 |
|---|---|
| Intel DLL 校验客户端 | **不校验**（实测静态） |
| Windows API 闸门 | **只放行 Network Service**（实测） |
| 能否收发原始帧 | **不能**：IHV 处理器集里没有收包回调 |

所以要走到驱动，只有两条：

1. **以 Network Service 身份运行调用代码**。管理员可以创建以该账户运行的服务——这是合法的系统配置动作，不是漏洞利用，但仍然是「新增服务 + 以服务账户运行代码」。
2. **改 `wlan_secure_ihv_control` 的 DACL**。`WlanSetSecuritySettings` 本身要求对该对象的写权限，而我们没有；只能靠 GPO / 注册表 / 取得所有权。这属于**主动削弱系统安全设置**，我不建议，也不会未经授权去做。

两条都不是「零改动」，路线 A 的「免改任何文件」这个卖点不成立。

## 6. 顺带确认的负面结论

因为 IHV 处理器集里没有收包回调，**即使替换 IHV DLL（路线 B），也拿不到原始 802.11 帧**——`Dot11ExtIhvReceiveIndication` 只送 NDIS 状态，`Dot11ExtIhvSendPacketCompletion` 只送发送完成。

这条对路线 B 是实质性的坏消息：之前设想「换成自己的 DLL 就能收发 Action Frame」并不成立。IHV 扩展模型本身就不提供原始帧收发。

## 7. 建议

路线 A 到此可以判定为**默认不可用**。是否继续取决于你是否接受「新增一个以 Network Service 运行的服务」这一动作。

即便接受，也只能到「服务类型控制」或「驱动类型控制」这一层，接收问题依然无解。

下一步可选：

1. 就此收敛，把结论写进总报告，转向「不加硬件则无解」的正式结论。
2. 继续只读勘查 `wlan_ihv_control_type_driver` 到底会不会绕过 DLL 直达 miniport（若会，价值高于 service 类型），仍属静态分析。
3. 若你愿意接受新增服务，则设计一个最小、可回滚的 Network Service 探针，先只发零长度请求验证是否返回非 `ACCESS_DENIED`。

我倾向先做 2——它能把「这条路到底通向哪里」彻底问清，且不需要任何改动。
