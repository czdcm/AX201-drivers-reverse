# AX201 椹卞姩閫嗗悜璁板綍

Intel Wi-Fi 6 AX201锛圕NVio2锛夊湪 Windows 涓婄殑椹卞姩闈欐€侀€嗗悜涓庡彲琛屾€ч獙璇併€?
鏈粨搴撳彧鍖呭惈**鍒嗘瀽缁撴灉銆佷簨瀹炴暟鎹€佽剼鏈?*锛屼笉鍖呭惈浠讳綍 Intel 浜岃繘鍒舵枃浠讹紝涔熶笉鍖呭惈澶ц妯″弽缂栬瘧浜х墿銆?
---

## 缁撹

**鍦ㄣ€屼娇鐢ㄩ樁娈典繚鎸?Secure Boot 寮€鍚€佷笉鏂板纭欢銆嶇殑鍓嶆彁涓嬶紝鐩爣鏃犳硶杈炬垚銆?*

涓ら亾涓嶅彲缁曡繃鐨勯檺鍒跺彔鍔狅細

1. 鏈幏寰蒋绛惧悕鐨勫唴鏍哥粍浠舵棤娉曞湪 Secure Boot 寮€鍚姸鎬佷笅鍔犺浇锛?2. 淇敼杩囩殑 `Netwtw14.sys` 姘歌繙鏃犳硶鑾峰緱绛惧悕锛屼篃涓嶈兘鍚堟硶鍒嗗彂銆?
鎶€鏈矾寰勬湰韬槸閫氱殑锛堣 [`docs/05-wdi-ihv-transport.md`](docs/05-wdi-ihv-transport.md)锛夛紝浣嗚惤鍦伴渶瑕?EV 浠ｇ爜绛惧悕璇佷功 + 寰蒋 attestation 绛惧悕锛屽睘浜庨噰璐笌瀹℃牳娴佺▼銆?
---

## 鐩爣涓庣害鏉?
| 椤?| 鍐呭 |
|---|---|
| 鐩爣 | 鍦ㄦ湰鏈?AX201 涓婂疄鐜?AirDrop 鎺ユ敹 |
| 纭欢绾︽潫 | 涓嶆柊澧炰换浣曠‖浠?|
| 瀹夊叏绾︽潫 | 浣跨敤闃舵 Secure Boot 淇濇寔寮€鍚紙瀹夎鏃朵复鏃跺叧闂彲鎺ュ彈锛?|
| 宸茬‘璁ゅ墠鎻?| 鎺ユ敹绔笉闇€瑕?Apple 绛惧彂鐨勮韩浠借瘉涔?|

---

## 鐜涓庢牱鏈?
| 椤?| 鍊?|
|---|---|
| 涓绘満 | ASUS TUF Gaming F16 FX607JIR |
| 绯荤粺 | Windows 11 Pro x64 `10.0.26300` |
| 缃戝崱 | Intel Wi-Fi 6 AX201 160MHz |
| 纭欢 ID | `PCI\VEN_8086&DEV_7A70&SUBSYS_00748086&REV_11` |
| 鎬荤嚎 | CNVio2锛?*涓嶆槸** USB锛學inUSB/libusb 璺嚎涓嶅彲鐢級 |
| 椹卞姩鐗堟湰 | `24.50.0.4`锛宍oem73.inf` |
| 椹卞姩鍖?| `netwtw08.inf_amd64_7d404936069a9b78` |

鏍锋湰 SHA256锛?
| 鏂囦欢 | SHA256 |
|---|---|
| `Netwtw14.sys` | `87C083010DAD3FB6AC8CAC99DDB5E274DF300DA789CC8774B4A25DA137DA38B8` |
| `IntelIHVRouter14.dll` | `60B7F7BC371E711FDA6BD957A252F779B4D326F9637BFD4751D27D88826B9ACF` |
| `netwfw14.dat` | `23FC171B845E40613969FB8480FC5660D634E6050EB1EEFF010B35D1349DDB5A` |

---

## 鐩綍缁撴瀯

```
docs/                          鍒嗘瀽鎶ュ憡
  01-overview.md               鏈€鍒濊皟鏌ワ細纭欢銆侀┍鍔ㄥ寘銆佹ā鍧楁瀯鎴?  02-static-analysis.md        绗竴杞潤鎬佸熀绾?  03-ihv-request-and-action-frame.md  IHV 璇锋眰灏佸涓?Action Frame 鏋勯€?  04-oid-dispatch-table.md     OID 鍒嗘淳琛ㄨ繕鍘燂紙146 鏉★級
  05-wdi-ihv-transport.md      WDI IHV 璇锋眰鐨勭湡瀹炰紶杈撴柟寮?鈽?  06-sniffer-and-etw.md        鍡呮帰甯х粡 ETW 杈撳嚭 鈽?  07-driver-sniffer-subsystem.md 椹卞姩鍐呭梾鎺㈠瓙绯荤粺涓?MAC 绫诲瀷鏋氫妇
  08-firmware-command-layer.md 鍥轰欢鍛戒护灞傦紙MHIF锛夊嫎鏌?  09-user-mode-attempts.md     鐢ㄦ埛鎬佷笁鏉￠€氶亾鐨勫疄娴嬭褰?  10-wlanihvcontrol-investigation.md  WlanIhvControl 璺緞涓?DACL
  11-rx-tx-boundary.md         鏀跺彂杈圭晫涓庡钩鍙板眰闄愬埗
  12-receive-paths-retrospective.md  鎺ユ敹璺緞鍏ㄩ噺澶嶇洏
  13-deliverable-and-signing.md 浜や粯褰㈡€併€佺鍚嶄笌绀惧尯鐗堝畨瑁呰璁?  14-conclusion.md             闃舵鎬ц瀹?  15-handoff.md                浜ゆ帴璁板綍
  external/
    dropbridge-radio.md        DropBridge radio 鍚庣濂戠害
    dropbridge-awdl.md         DropBridge AWDL 涓婂眰澶嶇敤闈?
data/                          缁撴瀯鍖栨暟鎹?  oid-table.tsv                146 鏉?OID 鍒嗘淳琛紙鍚嶇О / 鏁板€?/ 澶勭悊鍑芥暟锛?  wlan-capabilities.txt        绯荤粺鎶ュ憡鐨勭綉鍗¤兘鍔?  manifests/                   璇佹嵁娓呭崟銆侀┍鍔ㄦ竻鍗曘€佷笅杞芥牎楠?  detection/                   DIE 鏍煎紡璇嗗埆缁撴灉

src/                           婧愮爜鏍圭洰褰?  tools/ghidra/
    Ax201ReadOnlyExport.java   鍙璇佹嵁瀵煎嚭鑴氭湰
    configs/                   鍚勮疆瀵煎嚭閰嶇疆
  driver/oidproxy/
    oidproxy.c                 鑷啓 NDIS 鍗忚椹卞姩锛堝彲缂栬瘧锛屾湭閮ㄧ讲锛?    build.cmd                  缂栬瘧鑴氭湰锛圫DK 26100 + WDK 22621 + MSVC锛?  probes/                      鎻愭潈鎺㈡祴鑴氭湰锛屾寜鎵ц椤哄簭缂栧彿

private/                       璇佹嵁瀛樻。锛堝凡 gitignore锛屼笉鍙戝竷锛?  evidence/                    鍚勮疆鍙嶇紪璇戣緭鍑?  data/strings/                瀛楃涓茶浆鍌?  logs/                        Ghidra 杩愯鏃ュ織涓庡疄娴嬫棩蹇?```


---

## 鏍稿績鍙戠幇

### 1. OID 鍒嗘淳琛?
`.rdata` 涓竴寮犺捣濮嬩簬鏂囦欢鍋忕Щ `0x52FC60` 鐨勮繛缁〃锛屽叡 **146 鏉?*锛屾瘡鏉?`0x50` 瀛楄妭锛?
| 鍋忕Щ | 瀹藉害 | 鍚箟 |
|---|---|---|
| 0x00 | 0x40 | OID 鍚嶇О |
| 0x40 | u32 | OID 鏁板€?|
| 0x44 | u32 | 淇濈暀 |
| 0x48 | u64 | 澶勭悊鍑芥暟 |

浜ゅ弶楠岃瘉锛歚OID_802_11_BSSID_LIST_SCAN` 瀵瑰簲 `0xFF800000`锛屼笌 Windows 鏍囧噯瀹氫箟涓€鑷淬€?
瀹屾暣鏁版嵁锛歔`data/oid-table.tsv`](data/oid-table.tsv)

### 2. WDI IHV 璇锋眰鐨勭湡瀹炰紶杈撴柟寮?
`dot11wdi.h` 涓細

```c
#define WDI_OID_PREFIX   0x0e4400000U
#define WDI_IHV_REQUEST  93
```

寰?**`OID_WDI_IHV_REQUEST = 0xE440005D`**銆?
Intel 绉佹湁鍛戒护涓嶈蛋瑁?OID锛?
```
鎿嶄綔绯荤粺 鈹€鈹€OID_WDI_IHV_REQUEST + WDI TLV鈹€鈹€鈻?椹卞姩
                                            鈹?ParseWdiIhvRequest
                                            鈻?                          prepareNicSpecificOidFromWdiIhvRequest
                                            鈻?                              绉佹湁 NIC-specific OID (0x0D01035C)
```

杩欐槸鏍囧噯 WDI OID锛岀悊璁轰笂鏅€?NDIS 鍗忚椹卞姩涔熻兘鍙戦€併€?
### 3. 鍡呮帰妯″紡涓?ETW

`0x1400450e0` 鏄帴鏀跺垎鍙戝叆鍙ｏ紝鎸夋ā寮忔爣蹇楀垎鍙夛細

```c
if (*(int*)(*(adapter + 0xcf68) + 0x28) == 0)
    鈫?姝ｅ父涓婃姤鎿嶄綔绯荤粺
else
    鈫?鏋勯€?radiotap 鈫?EtwWriteTransfer 鈫?涓㈠純璇ュ抚
```

`0x1401a6e80` 璐熻矗鎷?radiotap锛圱SFT / flags / rate / channel / MCS / VHT / HE锛夈€?
鍗筹細鍡呮帰妯″紡涓嬪抚璧?ETW锛岀敤鎴锋€佸彲璁㈤槄锛涗絾鍚敤鍡呮帰闇€瑕佺鏈夊懡浠ゃ€?
### 4. 椹卞姩鍐呭彲鏀圭偣

| # | 浣嶇疆 | 鐜扮姸 | 闅惧害 |
|---|---|---|---|
| 1 | `utilOpModeToMacType` `0x1400432a0` | 姘镐笉杩斿洖 SNIFFER(5) | 浣?|
| 2 | `prvHmfmHandleActionFrame` `0x1402d70f0` | 绫诲埆 `0x7f` 钀?break | 浣?|
| 3 | OID 鍒嗘淳琛?| 绉佹湁 OID 鐢ㄦ埛鎬佷笉鍙揪 | 涓?|
| 4 | `mhiffSendP2pActionFrameCmdVer2` `0x1403455c0` | 鍙敹甯т綋锛屽ご閮ㄧ敱椹卞姩鐢熸垚 | 涓?|
| 5 | `rxPacketProcessValidMpduFrame` `0x1400456e0` | 闇€鍔犳梺璺嚭鍙?| 楂?|
| 6 | 鍡呮帰瀛愮郴缁?| 浠ｇ爜鍦紝鏃犺皟鐢ㄨ€?| 楂?|
| 7 | 鎹㈠彴鍛戒护鏃?| 闇€鏆撮湶 | 涓?|

---

## 瀹炴祴鎺掗櫎鐨勮矾寰?
| 璺緞 | 缁撴灉 |
|---|---|
| `WlanIhvControl`锛坰ervice锛?| `ERROR_DEV_NOT_EXIST` |
| `WlanIhvControl`锛坉river锛?| `ERROR_NOT_SUPPORTED` |
| 鏀惧紑 `wlan_secure_ihv_control` DACL 鍚庨噸璇?| 浠嶅け璐ワ紝闄愬埗涓嶅湪 ACL |
| Npcap `PacketRequest` + 鏍囧噯 OID | 鎴愬姛锛堣鍥炵湡瀹?MAC锛?|
| Npcap + 绉佹湁 OID `0xFF100015` | `0xC00000BB` NOT_SUPPORTED |
| Npcap + 绉佹湁 OID `0x0D01011A` | `0xC0010017` INVALID_OID |
| Npcap 鑷甫 `WlanHelper` | 鍙 mode/channel锛屼絾璧?WlanAPI 鑰岄潪 OID |

鐢ㄦ埛鎬佹病鏈変换浣曡矾寰勮兘鎶婄鏈夊懡浠ら€佽繘 AX201 椹卞姩銆?
---

## 澶嶇幇

闈欐€佸垎鏋愶細Ghidra 12.2 + JDK 25锛屽叏绋嬪彧璇汇€?
```
analyzeHeadless.bat <project> <name> \
  -process Netwtw14.sys -noanalysis -readOnly \
  -scriptPath src/tools/ghidra \
  -postScript Ax201ReadOnlyExport.java <config.json>
```

鑴氭湰涓嶄慨鏀圭▼搴忓瓧鑺傘€佷笉鍐欓」鐩姸鎬併€傞厤缃 `src/tools/ghidra/configs/`銆?
椹卞姩缂栬瘧锛歐indows SDK 10.0.26100 + WDK 10.0.22621 + MSVC 14.51锛岃 `src/driver/oidproxy/build.cmd`銆?
---

## 杩樼己浠€涔?
| 缂哄彛 | 鎬ц川 |
|---|---|
| 寰蒋 attestation 绛惧悕 | 閲囪喘娴佺▼锛圗V 璇佷功 + Partner Center锛?|
| WDI TLV 灏佽鏍煎紡 | 鍙粠 SDK 澶存枃浠朵笌鏂囨。杩樺師 |
| Intel 鍐呭眰杞借嵎鏍煎紡 | 闇€缁х画闈欐€佽繕鍘?|
| 鍥轰欢鏄惁鍝嶅簲鍡呮帰鍛戒护 | 鍙兘瀹炴祴 |

绛惧悕鏄繀瑕佹潯浠讹紝涓嶆槸鍏呭垎鏉′欢銆?
---

## 闄愬埗

- 闄ゆ爣娉ㄣ€屽疄娴嬨€嶇殑椤圭洰澶栵紝缁撹鍧囨潵鑷潤鎬佸垎鏋愶紝鏈湪纭欢涓婇獙璇併€?- `netwfw14.dat` 鏈В鍖咃紝鍥轰欢渚ц兘鍔涙湭鐭ャ€?- 鍡呮帰妯″紡鑳藉惁琚浐浠舵帴鍙楋紝闈欐€佹棤娉曞垽瀹氥€?- Ghidra 瀵?CFG 闂存帴璋冪敤涓庤嚜鍔ㄧ被鍨嬫帹鏂瓨鍦ㄥ凡鐭ュけ鐪燂紝鐩稿叧缁撹宸插湪鍚勬枃妗ｆ爣娉ㄣ€?
---

## 鐗堟潈涓庡厤璐?
瑙?[NOTICE.md](NOTICE.md)銆?
