# 黑雷达 Studio · iOS 版（BlackRadar Studio for iOS 17）

把 `BlackRadarStudio-Android-0.1.0-test.apk` 重写成能在 iPhone / iPad（iOS 17+）上安装运行的原生 App。
SwiftUI + URLSession，没有第三方依赖，编译产物是**未签名 IPA**，你自己用 Sideloadly / eSign / AltStore / 自签证书装。

---

## 一、先说清楚：iOS 版为什么不用 USB 线刷

把 APK 拆开看，它做的事很明确：

| 位置 | 内容 |
| --- | --- |
| `cn.blackradar.studio.usb.RomWriter` | ESP32-S3 **ROM 下载协议**：SLIP 组帧、`SYNC` 同步、`FLASH_BEGIN / FLASH_DATA / FLASH_END`、128 KB 分块、寄存器读回校验、MD5 收尾 |
| `cn.blackradar.studio.usb.AdvFlasher` | 走 `UsbDeviceConnection.bulkTransfer()` 直接把整个 merged image 写进 `0x0` |
| `cn.blackradar.studio.catalog.FirmwareCatalog` | 从 `https://madsdai.com/blackradar/studio/studio.json` 拉目录、下载、SHA-256 校验、`format=merged / offset=0` |
| `cn.blackradar.studio.FlashService` | 前台服务 + WakeLock + 通知，刷机时不让系统杀掉 |
| 界面 | `BlackRadar Studio` / `Cardputer ADV` / `USB OTG` 状态 + 固件列表 |

也就是说，Android 版是**用手机当 USB 烧录器**，直接跟 ESP32-S3 的 ROM bootloader 说话。

**iOS 没有这条路。** 不是权限没申请，是系统层面不存在：

* 第三方 App 拿不到 USB 主机接口。`UsbDeviceConnection` / `bulkTransfer` 这套 API 在 iOS 上没有对等物，`IOUSBHostFamily` 只给系统自带驱动用。
* CDC-ACM（ESP32-S3 的 USB-Serial/JTAG）不是 MFi 配件类，没有 `ExternalAccessory` 协议字符串可用，插上只会被系统当串口吃掉，App 看不见端点。
* 越狱环境（palera1n / Dopamine 之类）理论上能通过内核扩展拿到串口，但那是另一套东西，普通签名安装的 IPA 做不到。

所以 iOS 版换了条**同样能刷成、而且更稳**的路：**让设备自己刷**。

固件 2.9.1 内部自带 Web 服务（`192.168.4.1`，热点名 `BlackRadar-XXXX`，SD 根目录 `/dolphindeck/`，上传接口 `POST /upload?dir=...`），以及一个「SD 刷机」界面，读 `/update/` 下的 `firmware.bin` / `bootloader.bin` / `partitions.bin` 写 flash。

于是 iOS 版的刷机流程是：

1. 手机连设备热点（`BlackRadar-XXXX`）
2. App 探测 `192.168.4.1`，读出设备页面上的目录列表
3. App 把固件 multipart 上传到 `/upload?dir=/update`，文件名 `firmware.bin`（3.8 MB，带进度）
4. 在 Cardputer 上进 SD 刷机界面按 `ENTER`
5. 设备自己写 flash 并重启

不依赖电脑、不依赖 OTG 线，写入由设备端的 ESP-IDF `Update`/分区写完成。**这也是唯一的正路**：任何声称在未越狱 iOS 上能 USB 线刷 ESP32 的方案都是假的。

---

## 二、这个 App 有什么

四个 Tab，跟 Android 版对应，配色沿用设备的深色 + 金色：

**固件**
- 实时拉 `studio.json`：名称、版本、tagline、亮点、board/chip、大小、SHA-256
- 下载带进度条，落盘 `Documents/Firmware/<id>.bin`，下完自动比 SHA-256
- 「校验」单独再算一次（CryptoKit）
- 「无线刷入」直接跳到设备上传
- 「导出到文件 / SD 卡」：走系统分享，可以存进「文件」App，也可以存到读卡器里的 SD 卡
- 右上角可导入本地 `.bin`（自己编译的固件也行），也支持下拉刷新
- 目录会缓存一份，断网也能看到列表

**设备**
- 地址框（默认 `192.168.4.1`）+ 探测，显示设备页面标题、在线状态
- 自动解析设备页面上的目录下拉框，点一下就切换目标目录（默认 `/update`）
- 上传带进度，可取消；上传完直接告诉你下一步在设备上按 `ENTER`
- 「打开 Wi-Fi 设置」一键跳到系统无线局域网

**资源包**
- `sd_packs`：密码字典、NFC 卡库、抬杆码库、红外码库（1233 个品牌型号）、蓝牙设备表
- 下载 + SHA-256 校验，存 `Documents/Packs/`，分享出去拷进 SD 卡

**说明**
- iOS 版刷机步骤、USB 不可用的技术原因、数据来源、实时日志

其它细节：

- Info.plist 开了 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`，所以 **「文件」App → 我的 iPhone → 黑雷达 Studio** 里能直接看到下载的 `.bin`，拷进 SD 卡很顺手
- `NSAllowsLocalNetworking` + `NSLocalNetworkUsageDescription`：http 打 `192.168.4.1` 不会被 ATS 拦，首次访问会弹本地网络授权
- 图标是脚本画的（`mkicon.py`，纯标准库写 PNG），深色圆角底 + 金色雷达

---

## 三、编译 / 拿 IPA

产物是 `build/BlackRadarStudio-0.1.0-unsigned.ipa`（`Payload/BlackRadarStudio.app`，arm64，iOS 17.0+，未签名）。
仓库的 GitHub Actions 每次 push 都会跑一遍 `build.sh` 并把 IPA 作为 artifact 上传。

### 自己编（macOS + Xcode 15 以上）

```bash
chmod +x build.sh
./build.sh
# 产物 build/BlackRadarStudio-0.1.0-unsigned.ipa
```

`build.sh` 干的事：

```bash
swiftc -sdk $(xcrun --sdk iphoneos --show-sdk-path) \
       -target arm64-apple-ios17.0 -swift-version 5 -O -parse-as-library \
       -module-name BlackRadarStudio -o Payload/BlackRadarStudio.app/BlackRadarStudio Sources/*.swift
cp Info.plist Payload/BlackRadarStudio.app/
python3 mkicon.py Payload/BlackRadarStudio.app
zip -r BlackRadarStudio-0.1.0-unsigned.ipa Payload
```

顺手会编一份模拟器版、装进 iPhone 模拟器跑一遍并截图，确认不闪退（`SIM=0` 关掉）。

### 签名安装

IPA 拖进 **Sideloadly / eSign / AltStore / TrollStore**，用你自己的证书与描述文件签。

- Bundle ID 默认 `com.akwkw1.blackradarstudio`，签名工具里可以改，改成你证书能用的即可
- 免费开发者账号 7 天有效期，付费账号 1 年
- 装不上一般是 Bundle ID 冲突、描述文件没带这台设备的 UDID，或者没给「本地网络」权限

---

## 四、改点东西

| 想改 | 位置 |
| --- | --- |
| 显示名 | `Info.plist` 的 `CFBundleDisplayName` |
| Bundle ID | `Info.plist` 的 `CFBundleIdentifier` |
| 默认设备地址 | `Sources/Model.swift` 里 `host` 初始值 |
| 默认目标目录 | `Sources/Model.swift` 里 `targetDir` |
| 固件目录 URL | `Sources/Model.swift` 里 `catalogURL` |
| 配色 | `Sources/Theme.swift` |
| 图标 | `mkicon.py` 里的颜色/图形常量，重跑 `build.sh` |

---

## 五、文件结构

```
.
├── build.sh                 # 一条命令出未签名 IPA（含模拟器冒烟测试）
├── Info.plist               # Bundle 配置、ATS 本地网络、文件共享
├── mkicon.py                # 纯标准库画图标
└── Sources
    ├── App.swift            # @main
    ├── Theme.swift          # 配色与卡片组件
    ├── Net.swift            # 下载器 / multipart 上传器（带进度）
    ├── Model.swift          # studio.json 模型、目录、下载校验、设备探测与上传
    └── Views.swift          # 四个页面
```

代码量约 1200 行，纯系统框架：SwiftUI、Foundation、CryptoKit、UniformTypeIdentifiers。

上传接口那部分有坑，别照 ESP-IDF 的 `file_serving` 例子写：那个例子是 `POST /upload/<文件名>` + 裸 body，黑雷达固件是 **Arduino WebServer 的 multipart**（字段 `f`、目录 `?dir=`）。对照与出处都在 [REFERENCE.md](REFERENCE.md)。
