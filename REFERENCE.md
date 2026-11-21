# REFERENCE — 黑雷达 Studio iOS 版的上游调研

写这个 App 之前先把要实现的几块拆开查了上游实现，不凭记忆写协议。下面是问题、候选、基线、差异、验证。

---

## 1. 问题拆解

| 子问题 | 需要在 iOS 上做到 | 是否涉及二进制协议 |
| --- | --- | --- |
| A. 固件目录 | GET `https://madsdai.com/blackradar/studio/studio.json`，解 `firmware[] / sd_packs[]` | 否（JSON） |
| B. 固件下载 + 校验 | 3.8 MB 下载、SHA-256 比对 | 否 |
| C. 把固件写进 ESP32-S3 | 设备 flash 被改写，`0x0` 起 merged image | **是** |
| D. 进度/取消/后台 | URLSession 进度回调、临时文件 | 否 |

C 是唯一有协议风险的，先定它。

---

## 2. C 的两条候选路

### 候选 1：照搬 Android 的 USB ROM 下载协议

Android 版实现（`classes4.dex`：`cn.blackradar.studio.usb.RomWriter` / `AdvFlasher`）就是 esptool 那套：
SLIP 组帧 → `SYNC` → `FLASH_BEGIN / FLASH_DATA / FLASH_END` → 每帧 XOR checksum → `SPI_FLASH_MD5` 收尾。

上游权威实现：[espressif/esptool `esptool/loader.py`](https://github.com/espressif/esptool/blob/master/esptool/loader.py)

| 上游位置 | 内容 | 与本项目关系 |
| --- | --- | --- |
| `loader.py` `ESP_CMDS` 附近（`"SPI_FLASH_MD5": 0x13`） | 命令码表 | 与 Android 版一致 |
| `loader.py:708` `def sync(self)` | 0x07 SYNC + 0xC0 0x00 一帧 | 同上 |
| `loader.py:1166` `def flash_begin(...)` | 0x02 FLASH_BEGIN，擦除后回 ACK | 同上 |
| `loader.py:1201` `def flash_block(...)` | `struct.pack("<IIII", len(data), seq, 0, 0) + data`，XOR checksum，失败重试 | 同上 |
| `loader.py:1224` `def flash_finish(...)` | 0x04 FLASH_END，可 reboot | 同上 |
| `loader.py:1454` `def run_stub(...)` | 先下载 stub loader 提速 | Android 版未用 stub，直接用 ROM 命令 |

**结论：不能用。** iOS 没有 USB 主机接口，第三方 App 拿不到 `bulkTransfer` 对等的端点访问；ESP32-S3 的内建 USB-Serial/JTAG 也不是 MFi 配件，`ExternalAccessory` 没有可用协议串。这条路在未越狱 iOS 上不存在，协议写得再对也没有传输层。

### 候选 2：让设备自己刷（设备自带 Web 服务 + SD 分区刷写）

固件 2.9.1 里能直接读到证据（`fw-lite-291.bin` 字符串）：

```
<form id="uf" method="post" action="/upload" enctype="multipart/form-data"><label>
</label><input type="file" name="f" required><button type="submit">
<script>var f=document.getElementById('uf');f.addEventListener('submit',function(){var s=f.querySelector('select');f.action='/upload?dir='+encodeURIComponent(s.value);});</script>
bool WebServer::_collectHeader(const char*, const char*)
//Users/mads/.platformio/packages/framework-arduinoespressif32/libraries/WebServer/src/Parsing.cpp
192.168.4.1     blackradar1     BlackRadar-%02X%02X
 /update/   firmware.bin   bootloader   partitions
```

也就是：**Arduino-ESP32 `WebServer`**（不是 ESP-IDF 的 `httpd`），设备开 AP（`192.168.4.1`），页面上有 SD 文件上传表单，字段名 `f`、目标目录走查询参数 `dir`；另有 SD 刷机界面读 `/update/firmware.bin`。

上游对照：[esp-idf `examples/protocols/http_server/file_serving/main/file_server.c`](https://github.com/espressif/esp-idf/blob/master/examples/protocols/http_server/file_serving/main/file_server.c)

| 上游位置 | 行为 | 黑雷达固件 | 差异 |
| --- | --- | --- | --- |
| `file_server.c:293` `upload_post_handler` | 处理 `POST /upload/*` | `POST /upload?dir=...` | URI 形态不同 |
| `file_server.c:302` `req->uri + sizeof("/upload") - 1` | **文件名来自 URI 路径** | 文件名来自 multipart 的 `filename=` | **关键差异** |
| `file_server.c:357` `httpd_req_recv(...)` | 直接读裸 body 落盘 | 先解析 multipart 头再取 body | **关键差异** |
| `file_server.c:494` `uri = "/upload/*"` | 通配 URI 注册 | 单一路由 + 查询参数 | 差异 |

照抄 `file_serving` 例子会把 multipart 包膜（`--boundary`、`Content-Disposition`）一起写进 `firmware.bin`，刷进设备必炸。所以本项目按**固件自己的表单**来构造 multipart：字段名 `f`、文件名任意（我们用 `firmware.bin`）、目录用 `?dir=`。

设备侧写入语义：[arduino-esp32 `libraries/Update/src/Updater.cpp`](https://github.com/espressif/arduino-esp32/blob/master/libraries/Update/src/Updater.cpp)

| 上游位置 | 内容 |
| --- | --- |
| `Updater.cpp:203` `UpdateClass::begin(size, command, ...)` | 取下一个 OTA 分区、`esp_ota_begin` |
| `Updater.cpp:263` `if (command == U_FLASH)` | 写 app 分区（`U_FLASH`），另有 `U_SPIFFS` |
| `Updater.cpp:858` `UpdateClass::end(evenIfRemaining)` | 收尾、`_md5.calculate()`、校验镜像头 |

固件里同时出现 `esp_ota_get_next_update_partition`、`esp_image` 校验、`ESP_ERR_OTA_*` 等字符串，说明它还带了整套 IDF OTA。但注意：`studio.json` 里 `format=merged / offset=0` 是**整片镜像**（bootloader + 分区表 + app），只能整体写 `0x0`，不能走 OTA 分区接口。这正是设备提供 SD 刷机界面（`firmware.bin` + `bootloader` + `partitions`）而不是 `/ota` 的原因。

### 对比结论

| 维度 | USB ROM 协议 | 设备 Web + SD 刷机 |
| --- | --- | --- |
| iOS 可行性 | 0（无 USB 主机） | 可行（HTTP over Wi-Fi） |
| 整片镜像 | 支持 | 支持（设备端写 `0x0`） |
| 用户操作 | 插线 | 连热点、上传、设备按 ENTER |
| 中途断线 | 变砖风险 | 文件先落 SD，重按即可 |
| 协议风险 | 高（SLIP/命令码/checksum） | 中（multipart 字段名与目录参数） |

**选定基线：候选 2。** 传输用 `URLSession` multipart，字段/参数按固件表单的取值；设备端写入由 Arduino `Update`/分区写完成，App 不碰 flash 时序。

---

## 3. 与本地目标的差异（有意为之）

| 点 | Android 版 | iOS 版 | 原因 |
| --- | --- | --- | --- |
| 传输层 | USB OTG bulkTransfer | HTTP multipart over Wi-Fi | iOS 无 USB 主机 |
| 触发写入 | App 发 FLASH_BEGIN | 设备端按 ENTER | 设备才是写 flash 的一方 |
| 进度来源 | 每 128 KB 块 ACK | `didSendBodyData` | 语义等价 |
| 校验 | 读完寄存器/`SPI_FLASH_MD5` | 下载侧 SHA-256 比 studio.json | iOS 不需要跨链路校验 |
| 目录 | 顶部 tab | `TabView` + 深色金色主题 | 平台惯例 |

## 4. 验证方法

1. **编译 + 启动**：CI 里 `swiftc` 出设备版 IPA，同时编模拟器版、装进 iPhone 模拟器、四个 tab 各截一张图（截图为 run 日志里的 base64），确认不闪退、目录能拉到。
2. **目录/下载**：模拟器首屏实际渲染了 `studio.json` 的三条固件（`v2.9.1`、`ADV-V0.3`、`v2.9.1`），说明 HTTPS、JSON 解码、UI 绑定都通。
3. **multipart 正确性**：按固件表单的 `name="f"` + `?dir=` 构造；`Content-Disposition: form-data; name="f"; filename="firmware.bin"`，body 为原始 `.bin` 字节，尾部 `--boundary--`。真机验证需要设备在手：上传后到 SD 的 `/update/` 看文件大小是否等于 `studio.json` 的 `size`。
4. **SHA-256**：与 `studio.json` 的 `sha256` 比对；`fw-lite-291.bin` 实测 `3a95a7a8…6bbc9`，与目录一致。

## 5. 还没验证 / 已知不确定

- 固件上传后是否自动重启：未知，所以 UI 明确要求用户去设备上按 `ENTER`。
- 设备 HTTP 服务是否对上传体积有限制：`WebServer` 默认无上限，但 SD 写入速度决定耗时；App 侧超时设 120s/1800s。
- 设备 AP 密码：由设备端配置（NVS）并显示在设备 Wi-Fi 界面，App 不参与，用户手动在系统设置里输入。
