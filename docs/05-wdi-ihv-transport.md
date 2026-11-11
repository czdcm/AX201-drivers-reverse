# WDI IHV 请求的真实传输方式

2026-11-11。静态分析结论，修正了此前"私有 OID 不可达"的判断。

## 1. 关键发现

`C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\km\dot11wdi.h` 中：

```c
#define WDI_OID_PREFIX        0x0e4400000U
#define WDI_IHV_REQUEST       93
#define OID_WDI_IHV_REQUEST   WDI_DEFINE_OID(WDI_IHV_REQUEST)
```

计算得：**`OID_WDI_IHV_REQUEST = 0xE440005D`**

驱动侧对应证据：

| 符号 | 含义 |
|---|---|
| `PROP_IHV_REQUEST` | 这是 WDI **属性**请求 |
| `WDI_IHV_REQUEST_PARAMETERS` | TLV 参数结构 |
| `osal::CCmdPropIhvRequest::execute` | 属性命令执行体 |
| `osal::CCmdPropIhvRequest::prepareNicSpecificOidFromWdiIhvRequest` | 把 WDI 请求转成私有 NIC-specific OID |

## 2. 这改变了什么

之前 Npcap 发 `0x0D01011A` 得到 `INVALID_OID`，我们据此认为"私有 OID 不可达"。那个结论没错，但**我们把传输层找错了**。

Intel 的私有命令并不通过裸 OID 下发，而是：

```
操作系统 ──OID_WDI_IHV_REQUEST (0xE440005D) + WDI TLV──▶ 驱动
                                                          │
                            ParseWdiIhvRequest 解析 TLV   │
                                                          ▼
                              prepareNicSpecificOidFromWdiIhvRequest
                                                          │
                                                          ▼
                                       私有 NIC-specific OID (0x0D01035C)
```

`OID_WDI_IHV_REQUEST` 是**标准 WDI OID**，操作系统自己就用它向小端口发 IHV 请求。因此一个普通的 NDIS 协议驱动**也能发送它**——不需要替换 IHV DLL，也不需要 Native 802.11 模式。

## 3. 修正后的结论

| 判断 | 原结论 | 现结论 |
|---|---|---|
| 用户态能否下发私有命令 | 不能 | 仍然不能 |
| 内核驱动能否下发 | 存疑（可能同样被拒） | **可行，走 0xE440005D** |
| 是否需要替换 IHV DLL | 可能是唯一路径 | **不需要** |

## 4. 仍需解决的两件事

1. **WDI TLV 封装格式**：`WDI_IHV_REQUEST_PARAMETERS` 的具体布局，头文件与微软文档中有定义
2. **Intel 内层载荷**：TLV 里携带的私有请求内容，需继续从驱动侧还原

## 5. 对交付形态的影响

如果验证通过，架构变成：

```
[自写 NDIS 协议驱动]
   ├─ 发 OID_WDI_IHV_REQUEST 打开嗅探模式
   ├─ 需要时发动作帧命令
   └─ 暴露 IOCTL 给用户态
[用户态]
   ├─ 订阅 ETW 收原始帧（radiotap）
   └─ AWDL 协议栈 + UI
```

驱动仍然需要微软签名才能在使用阶段保持 Secure Boot 开启，但路径本身成立了。
