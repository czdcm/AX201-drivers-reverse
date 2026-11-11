# AX201 / DropBridge 前置调查

> 阶段更新：用户提供工具后，已完成第一轮 Ghidra 自动分析、函数清单与静态调用图导出；最新结果与限制见[离线静态分析报告](./analysis/STATIC-ANALYSIS.md)。下文保留工具到位前的调查记录，不能把其中“尚无工具”的阶段状态当作最新状态。

日期：2026-11-11。范围：本机只读识别、官方下载、已有 7-Zip 静态检查、仓库源码审阅。未安装/替换/加载驱动、未运行仓库脚本、未初始化无线硬件、未主动发送测试无线帧、未编写专用逆向工具。两个子智能体已由用户停止，本文结论由主会话核对。

## 1. 当前结论

- 已获取 Intel 官方同包版本安装程序，签名有效。
- 已获取 DropBridge 官方 main 源码快照；两次 Git 克隆失败，因此落地目录不是 Git 工作树，无提交历史和上游子模块。
- 已定位本机 AX201 的安装规则、内核驱动、配套数据文件和 IHV DLL，并保存只读副本与哈希。
- **未完成软件结构逆向**：尚无反汇编、函数调用图、导入函数明细、IOCTL/OID 分派、固件容器解析或驱动—固件协议分析。
- 适配的合理接缝是 DropBridge 的 radio_link v3；目前没有证据证明 AX201 Windows 驱动向用户态开放了足够的原始收发和信道控制能力，不能承诺改 INF 或增加 NDIS 过滤驱动即可实现。

## 2. 本机身份

- 电脑：ASUS TUF Gaming F16 FX607JIR_FX607JIR。
- 系统：Windows 11 Pro，10.0.26300，64 位。
- 无线网卡：Intel(R) Wi-Fi 6 AX201 160MHz，WLAN，调查时 Up。
- 硬件 ID：`PCI\VEN_8086&DEV_7A70&SUBSYS_00748086&REV_11`。
- PnP / netsh / 安装 INF 报告驱动版本：24.50.0.4，2026-05-20。
- 已安装发布名：oem73.inf；原始 INF：Netwtw08.INF。
- 运行中服务：Netwtw14；服务路径：`C:\Windows\System32\drivers\Netwtw14.sys`。
- Intel 产品规格标注 AX201 接口为 M.2: CNVio2；Windows PCI 枚举身份不应被误读为与任意 PCIe/USB 网卡驱动可互换。

本地证据：[系统驱动信息](./installed-driver.json)、[netsh 能力输出](./wlan-capabilities.txt)、[INF UTF-8 阅读副本](./installed-oem73.inf.txt)。netsh 输出不证明 monitor RX、原始 TX 或精确换台能力。

## 3. 下载包与样本

### 官方安装包

[WiFi-24.50.0-Driver64-Win10-Win11.exe](./WiFi-24.50.0-Driver64-Win10-Win11.exe)

- 来源：https://downloadmirror.intel.com/922739/WiFi-24.50.0-Driver64-Win10-Win11.exe
- 大小：47,333,432 字节。
- SHA256：`17EFCFEDB6075FDDB731022D67263888A9AFF04C9134CC0F1A198F8751CE1761`。
- Authenticode：Valid，Intel Corporation。
- 下载前 1 MiB 范围测速：HTTP 206，约 495 KB/s；完整下载约 34.17 秒，约 1.39 MB/s。
- 未运行该程序。7-Zip 识别为 x64 PE 自解压容器，版本资源含 24.50.0.4 与包装器 1.0.0.1；不能拿包装器版本代替驱动版本。
- 7-Zip 可提取外层 PE 节与 `[0]` 载荷，但无法将该载荷识别为压缩档案。到此停止，没有猜测载荷格式、写解包器或启动安装程序。
- [外层清单](./package-listing.txt)。下载版本与已安装包版本一致，**但未证明其内部所有文件与本机逐字节相同**。

### 本机只读组件样本

来源目录：`C:\Windows\System32\DriverStore\FileRepository\netwtw08.inf_amd64_7d404936069a9b78`。

[样本哈希与签名清单](./installed-package-manifest.json) 包含：

- [Netwtw08.INF](./installed-package/Netwtw08.INF)：859,690 B，设备匹配及安装指令。
- [Netwtw08.cat](./installed-package/Netwtw08.cat)：118,761 B，签名目录文件。
- [Netwtw14.sys](./installed-package/Netwtw14.sys)：5,646,928 B，内核驱动。
- [netwfw14.dat](./installed-package/netwfw14.dat)：16,824,292 B，配套数据/固件候选；**尚未解析其内部内容**。
- [IntelIHVRouter14.dll](./installed-package/IntelIHVRouter14.dll)：1,646,672 B，IHV 扩展 DLL。

上述副本合计 25,096,343 B。Get-AuthenticodeSignature 在本机对各样本报告 Valid，签名者 Microsoft Windows Hardware Compatibility Publisher；对于目录签名文件，此结果不能表述成它们全部都有嵌入式签名。未单独执行离线 CAT 成员验证。

本机 oem73.inf 与该 DriverStore 的 Netwtw08.INF SHA256 完全一致。系统目录 SYS 与该 DriverStore SYS SHA256 也完全一致：`87C083010DAD3FB6AC8CAC99DDB5E274DF300DA789CC8774B4A25DA137DA38B8`。

**版本口径差异**：安装包/PnP/INF 为 24.50.0.4，SYS 文件版本资源为 23.50.21.2，IHV DLL 为 24.12050.0.3。这是本次实测，不据此判断损坏、篡改或加载错误；后续分析必须以具体文件哈希为准。

## 4. 已确认的驱动安装边界

[INF 阅读副本第 92 行](./installed-oem73.inf.txt#L92) 精确匹配本机 `DEV_7A70&SUBSYS_00748086`，选中 `Install_GEN_SLR_HrP2_201_AX_2x2_WinT_non_6e`。

[第 1384–1408 行](./installed-oem73.inf.txt#L1384-L1408) 给出安装段与服务关联；[第 1664–1681 行](./installed-oem73.inf.txt#L1664-L1681) 明确内核服务、NDIS 加载组、SYS/DAT 复制和 IHV DLL。

[SYS 的 7-Zip PE 清单](./driver-pe-listing.txt) 确认 x64 Native 子系统、NDIS650_MINIPORT 版本注释、导入目录及多组 PAGE 节存在。这只能作为后续逆向的定位线索：不能从节名推导函数语义或宣布已找到帧注入接口。

Get-WindowsDriver -Online 查询因缺少管理员权限失败，未提权重试；改用普通文件只读和哈希比较定位样本。没有改变系统驱动配置。

## 5. DropBridge 获取情况

- 仓库：https://github.com/ndpyzwy-0w0/DropBridge
- [本地源码入口](<C:/Github/DropBridge/repo/README.md>)。
- [官方 ZIP 快照](./dropbridge-source.zip)：6,138,105 B；ZIP 注释 commit `68519f5f4d703965e2db33674cdb4ba10eb33908`。
- SHA256：`97D663C0E79BE319D834D4A1883E40648D06773AC541D7CD984DBB54BF958C66`。
- 归档来源：https://codeload.github.com/ndpyzwy-0w0/DropBridge/zip/refs/heads/main
- 解压 343 个文件，共 11,202,572 B。源码复制到约定目录；临时解压副本仍保留在 `C:\Github\DropBridge\snapshot-stage`，便于追溯。
- Git 默认克隆报连接重置；HTTP/1.1 重试报 443 连接失败。没有使用不明镜像，也没有将快照伪装成 Git 仓库。
- [sources.lock.json](<C:/Github/DropBridge/repo/docs/sources.lock.json>) 中的五个上游没有恢复。本次静态审阅范围是主仓库及提交的补丁，不包含完整上游驱动实现。

## 6. 面向 AX201 的源码发现

### 可以保留的接缝

[radio_link.h](<C:/Github/DropBridge/repo/src/radio_usb/radio_link.h#L8-L35>) 定义 v3、小端 8 B 消息头、最大载荷 16,384 B，消息包括 HELLO、RX、TX、SET_CHANNEL、SET_BSSID_FILTER、SET_ADDRESS。

[radio 主程序第 637–718 行](<C:/Github/DropBridge/repo/src/radio_usb/main.cpp#L637-L718>) 实际把 TX 交给 send_packet，把换信道交给 FastRetune，并调用 SetStationIdentity。后续若能实现 AX201 的等价后端，可优先保持该线协议，减少对 AWDL 上层的改动。这是设计建议，不是已完成适配。

[IPC 补丁](<C:/Github/DropBridge/repo/patches/awdl-ipc-host.patch#L359-L407>) 提供 AWDL_HOST_IPC，选择用户态 host_if_ipc，经 127.0.0.1:49877 交换原始 IPv6；这使网络协议栈不必绑定系统虚拟网卡，但**不消除无线硬件访问的驱动依赖**。

### 不能照搬的部分

[radio 主程序第 281–366 行](<C:/Github/DropBridge/repo/src/radio_usb/main.cpp#L281-L366>) 明确通过 libusb 打开 0bda:c820、claim/reset USB 接口、创建 devourer radio、调用 InitWrite。它不是通用 Windows WLAN 后端。

AX201 是 CNVio2，而 WinUSB 文档限定 USB function driver。因而修改 USB INF 的 VID/PID、替换芯片名字或复用 Realtek 固件不是 AX201 适配方案。

### 需要先证明的能力

1. 接收所需原始 802.11 管理帧/数据帧，且元数据足以转换成上层要求的 radiotap 格式。
2. 发送自行构造的所需管理帧/数据帧，区分软件提交成功、空口发出、对端确认。
3. 信道和带宽控制，尤其跨频段调度的尾延迟与完成确认。
4. 地址、BSSID 接收过滤，以及硬件 ACK/重试行为是否可配置且正确。
5. RX/TX 队列并发、超时、取消、设备恢复和睡眠恢复。

目前这些能力对本机 AX201 **均未验证**。Wi-Fi 6、Wi-Fi Direct、无线显示或普通抓包能力不能单独充当上述五项的证据。原始收包能力也不能替代原始发包能力。

### 不应从仓库外推的结论

[README 验证层级](<C:/Github/DropBridge/repo/README.md#L242-L253>) 与 [工作队列 Q68–Q70](<C:/Github/DropBridge/repo/docs/WORK_QUEUE.md#L96-L98>) 明确当前源码的若干修复未经 Windows 编译/测试；历史约 1.1 MB/s 是作者 RTL8821CU 环境记录，不是本机 AX201 测试，也不能保证当前 HEAD。

[Q48](<C:/Github/DropBridge/repo/docs/WORK_QUEUE.md#L75-L76>) 记录发送方向因证书互操作失败而在该项目终止。它不证明 AWDL 本身无法双向通信，也不是所有实现永远不能发送的证明。

## 7. 后续建议与停止边界

当前最有价值的下一步不是直接打补丁，而是给 AX201 的硬件能力逐项建立证据。建议先请求用户允许安装成熟工具，再开展：

1. **离线静态逆向工具**：优先 Ghidra（另需受支持 JDK）或用户已有合法 IDA；配合现成 PE 查看工具/dumpbin/LLVM。分析具体哈希的 SYS、IHV DLL，定位导入、设备接口、控制请求分派、收发队列和与 DAT 的关联。工具尚未下载或安装。
2. **固件侧调查**：先确认 DAT 的实际格式与驱动装载关系，再决定是否能由成熟工具处理；不编写专用解包器绕过本次约束。
3. **抓包/能力验证**：现成 Npcap/Wireshark 可作为候选，但不得预设 AX201 支持监控或注入。安装抓包驱动需要单独授权，不能为验证而直接改当前联网网卡。
4. **驱动开发调试**：只有前面证明需要且可行时再准备 WDK/WinDbg。内核调试、测试签名、安全启动变更、驱动替换均不在本次范围。不要为加载修改版而默认关闭系统安全机制。
5. **实现策略决策**：已有合法接口足够才做用户态后端；接口不足则评估最小内核桥接与固件能力，不能假定 LWF 自动获得底层未暴露的帧注入能力；硬件/固件不可用时记录 No-Go 条件，不承诺继续改驱动就能解决。

即使 AWDL 算法跑在用户态，CNVio2 硬件的访问仍可能需要内核驱动支持。这与用户态实现 AWDL 的目标并不矛盾，但与“零内核组件”不是同一个要求。

## 8. 外部来源与限制

- [Intel AX201 产品规格](https://www.intel.com/content/www/us/en/products/sku/130293/intel-wifi-6-ax201-gig/specifications.html)：Package Specifications 的 System Interface Type=CNVio2。
- [Microsoft WinUSB 安装说明](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/winusb-installation)：Writing a custom INF 一节将 WinUSB 定义为 USB function driver。
- [Intel Wi-Fi 下载页](https://www.intel.com/content/www/us/en/download/19351/intel-wireless-wi-fi-drivers-for-windows-10-and-windows-11.html)：当前页面已是 24.80.0，不能作为旧包内容逐字节证明。
- [Intel IT 管理员包说明](https://www.intel.com/content/www/us/en/download/18231/intel-proset-wireless-software-and-wi-fi-drivers-for-it-administrators.html)：提供纯驱动 ZIP 的说明；本次没有额外下载最新版或运行安装包来解出旧版。
- [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/Search.aspx?q=intel%20wireless%206%20ax201)：可查到 24.50.0.4，旁证版本存在；不能据此判所有条目适配本机。
- [旧版发布线索](https://www.station-drivers.com/index.php/en-nz/forum/intel-wireless-bluetooth-drivers/897-intel-r-wireless-wifi-drivers-version-24-xxx-whql?start=15)：只用来寻找 Intel 官方直链，下载包真实性另由本机签名与哈希留证；该贴的 ZIP 链接实际含 24.20.2，不采用它冒充 24.50.0。

网络工具的云端网页提取可用；本机直接 Intel 页面访问曾被拒绝。没有据抓取失败断言资源不存在。源码行为来自静态检查，硬件可用性未实测。
