import SwiftUI
import UniformTypeIdentifiers

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var m: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            FirmwareView()
                .tabItem { Label("固件", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(0)
            DeviceView()
                .tabItem { Label("设备", systemImage: "wifi") }
                .tag(1)
            PacksView()
                .tabItem { Label("资源包", systemImage: "sdcard") }
                .tag(2)
            AboutView()
                .tabItem { Label("说明", systemImage: "info.circle") }
                .tag(3)
        }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let v = Int(args[i + 1]) {
                tab = max(0, min(3, v))
            }
        }
        .tint(Theme.gold)
        .alert("提示", isPresented: Binding(
            get: { m.alert != nil },
            set: { if !$0 { m.alert = nil } }
        )) {
            Button("好", role: .cancel) { m.alert = nil }
        } message: {
            Text(m.alert ?? "")
        }
    }
}

// MARK: - 固件

struct FirmwareView: View {
    @EnvironmentObject var m: AppModel
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Banner()

                    if let err = m.catalogError {
                        Card {
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(Theme.warn)
                        }
                    }

                    SectionTitle(text: "云端固件")
                    if m.entries.isEmpty {
                        Card {
                            HStack(spacing: 10) {
                                ProgressView().tint(Theme.gold)
                                Text(m.catalogBusy ? "正在读取固件目录…" : "下拉刷新重新获取目录")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.sub)
                            }
                        }
                    }
                    ForEach(m.entries) { e in
                        FirmwareCard(entry: e)
                    }

                    SectionTitle(text: "已下载（\(m.locals.count)）")
                    if m.locals.isEmpty {
                        Card {
                            Text("还没有本地固件。点右上角按钮可以导入 .bin。")
                                .font(.footnote)
                                .foregroundStyle(Theme.sub)
                        }
                    }
                    ForEach(m.locals) { f in
                        LocalCard(file: f)
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle("BlackRadar Studio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            showImporter = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Button {
                            Task { await m.refreshCatalog() }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .tint(Theme.gold)
                }
            }
            .refreshable { await m.refreshCatalog() }
            .task {
                if m.entries.isEmpty { await m.refreshCatalog() }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let u = urls.first { m.importBin(u) }
                case .failure(let e):
                    m.alert = "导入失败：\(e.localizedDescription)"
                }
            }
        }
    }
}

struct Banner: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        Card {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.14)).frame(width: 46, height: 46)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.gold)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cardputer ADV · ESP32-S3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(m.deviceOnline ? "设备已连接 \(m.host)" : "iOS 版 · 无线 / SD 卡刷机")
                        .font(.system(size: 12))
                        .foregroundStyle(m.deviceOnline ? Theme.ok : Theme.sub)
                }
                Spacer()
            }
        }
    }
}

struct FirmwareCard: View {
    @EnvironmentObject var m: AppModel
    let entry: FirmwareEntry

    private var isDownloading: Bool { m.progress[entry.id] != nil }

    private func versionText(_ v: String) -> String {
        if let c = v.first, c == "v" || c == "V" || c.isLetter { return v }
        return "v" + v
    }
    private var local: LocalFile? { m.localFile(for: entry.id) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Pill(text: versionText(entry.version), color: Theme.gold)
                    if let board = entry.board {
                        Pill(text: board)
                    }
                    Spacer()
                }
                Text(entry.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)

                if let hl = entry.highlights, !hl.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(hl, id: \.self) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text("·").foregroundStyle(Theme.gold)
                                Text(line)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.text.opacity(0.85))
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Pill(text: AppModel.sizeText(entry.size))
                    Pill(text: entry.format ?? "merged")
                    Pill(text: String(entry.sha256.prefix(10)) + "…")
                    Spacer()
                }

                if isDownloading {
                    VStack(alignment: .leading, spacing: 5) {
                        Bar(value: m.progress[entry.id] ?? 0)
                        Text("下载中 \(Int((m.progress[entry.id] ?? 0) * 100))%")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.sub)
                    }
                } else if local != nil {
                    HStack(spacing: 10) {
                        Label("已下载", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.ok)
                        Spacer()
                        Button {
                            m.verify(entry)
                        } label: {
                            Text("校验").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)

                        Button {
                            m.upload(entry)
                        } label: {
                            Text("无线刷入").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)

                        Menu {
                            if let l = local {
                                ShareLink(item: l.url) {
                                    Label("导出到「文件」/ SD 卡", systemImage: "square.and.arrow.up")
                                }
                            }
                            Button(role: .destructive) {
                                m.deleteLocal(entry)
                            } label: {
                                Label("删除本地文件", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    .tint(Theme.gold)
                } else {
                    HStack {
                        Spacer()
                        Button {
                            m.download(entry)
                        } label: {
                            Label("下载固件", systemImage: "arrow.down.circle")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .tint(Theme.gold)
                }
            }
        }
    }
}

struct LocalCard: View {
    @EnvironmentObject var m: AppModel
    let file: LocalFile

    var body: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.gearshape")
                    .foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(AppModel.sizeText(file.size) + (file.verified ? " · 校验通过" : " · 未校验"))
                        .font(.system(size: 11))
                        .foregroundStyle(file.verified ? Theme.ok : Theme.sub)
                }
                Spacer()
                ShareLink(item: file.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .tint(Theme.gold)
            }
        }
    }
}

// MARK: - 设备

struct DeviceView: View {
    @EnvironmentObject var m: AppModel

    private var subnetHint: String {
        guard let ip = m.wifiIP else {
            return "手机现在没有 Wi-Fi 地址：先在「设置 → 无线局域网」连上设备热点。"
        }
        if ip.hasPrefix("169.254.") {
            return "拿到的是 169.254.x.x，热点没发地址（DHCP 失败）。在设置里「忘记此网络」再连一次。"
        }
        if ip.hasPrefix("192.168.4.") {
            return "在 192.168.4.x 网段，和设备同网段，网关就是 192.168.4.1。"
        }
        if ip.hasPrefix("172.20.10.") {
            return "在 iPhone 个人热点网段：设备连上热点后一般是 172.20.10.2–6，点「自动扫描」。"
        }
        return "当前是 \(ip)：连着普通 Wi-Fi。想让设备也连这个 Wi-Fi 就点「扫描 → 同一个 Wi-Fi 的本网段」；想用设备热点就手动切过去。"
    }

    private var subnetHintColor: Color {
        guard let ip = m.wifiIP else { return Theme.warn }
        if ip.hasPrefix("192.168.4.") { return Theme.ok }
        return Theme.warn
    }

    private var localEntries: [FirmwareEntry] {
        m.entries.filter { m.localFile(for: $0.id) != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(text: "0 · 本机网络")
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Wi-Fi 地址")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.sub)
                                Spacer()
                                Text(m.wifiIP ?? "没有")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(m.wifiIP == nil ? Theme.warn : Theme.text)
                                Button {
                                    m.refreshNet()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .tint(Theme.gold)
                            }
                            Text(subnetHint)
                                .font(.system(size: 12))
                                .foregroundStyle(subnetHintColor)
                        }
                    }

                    SectionTitle(text: "1 · 连到设备热点")
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("在「设置 → 无线局域网」里连接设备开的热点，名字以 BlackRadar 开头，默认地址 192.168.4.1。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.sub)
                            HStack(spacing: 8) {
                                Button {
                                    if let u = URL(string: "App-Prefs:root=WIFI") {
                                        UIApplication.shared.open(u)
                                    }
                                } label: {
                                    Label("打开 Wi-Fi 设置", systemImage: "wifi")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                            }
                            .tint(Theme.gold)
                        }
                    }

                    SectionTitle(text: "2 · 探测设备")
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                TextField("192.168.4.1", text: $m.host)
                                    .textFieldStyle(.plain)
                                    .keyboardType(.URL)
                                    .autocorrectionDisabled()
                                    .font(.system(size: 14, design: .monospaced))
                                    .padding(10)
                                    .background(Theme.bg)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                Button {
                                    Task { await m.probeDevice() }
                                } label: {
                                    Text(m.deviceProbing ? "探测中…" : "探测")
                                        .font(.system(size: 13, weight: .semibold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(m.deviceProbing || m.scanning)
                            }
                            .tint(Theme.gold)

                            HStack(spacing: 8) {
                                Circle()
                                    .fill(m.deviceOnline ? Theme.ok : Theme.sub)
                                    .frame(width: 7, height: 7)
                                Text(m.deviceOnline ? (m.deviceTitle.isEmpty ? "设备在线" : m.deviceTitle) : "未连接")
                                    .font(.system(size: 12))
                                    .foregroundStyle(m.deviceOnline ? Theme.ok : Theme.sub)
                                Spacer()
                                Menu {
                                    Button {
                                        Task { await m.scanDevices() }
                                    } label: {
                                        Label("设备热点 / iPhone 个人热点", systemImage: "wifi")
                                    }
                                    Button {
                                        Task { await m.scanLAN() }
                                    } label: {
                                        Label("同一个 Wi-Fi 的本网段", systemImage: "network")
                                    }
                                } label: {
                                    Text((m.scanning || m.lanScanning) ? "扫描中…" : "扫描")
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Theme.gold.opacity(0.16))
                                        .clipShape(Capsule())
                                }
                                .foregroundStyle(Theme.gold)
                                .disabled(m.scanning || m.lanScanning || m.deviceProbing)
                            }
                            if !m.scanFound.isEmpty {
                                Text("热点网段扫到：" + m.scanFound.joined(separator: " / "))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.ok)
                            }
                            if !m.lanFound.isEmpty {
                                Text("本网段扫到：" + m.lanFound.joined(separator: " / "))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.ok)
                            }
                        }
                    }

                    SectionTitle(text: "3 · 目标目录")
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("固件要放进设备的 /update 目录，文件名 firmware.bin，然后在 Cardputer 上按 ENTER 写入。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.sub)
                            TextField("/update", text: $m.targetDir)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                .font(.system(size: 13, design: .monospaced))
                                .padding(10)
                                .background(Theme.bg)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            if !m.deviceDirs.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(m.deviceDirs, id: \.self) { d in
                                            Button {
                                                m.targetDir = d
                                            } label: {
                                                Text(d)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 5)
                                                    .background(m.targetDir == d ? Theme.gold.opacity(0.25) : Theme.bg)
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(m.targetDir == d ? Theme.gold : Theme.sub)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    SectionTitle(text: "4 · 上传并刷入")
                    if localEntries.isEmpty {
                        Card {
                            Text("先在「固件」页下载一份固件。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.sub)
                        }
                    }
                    ForEach(localEntries) { e in
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("\(e.name) · v\(e.version)")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    Spacer()
                                    Button {
                                        m.upload(e)
                                    } label: {
                                        Text("上传")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Theme.gold)
                                    .disabled(!m.deviceOnline || m.uploadProgress != nil)
                                }
                                if m.uploadEntryID == e.id {
                                    Bar(value: m.uploadProgress ?? 0)
                                    Text("上传中 \(Int((m.uploadProgress ?? 0) * 100))% · 别锁屏")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.sub)
                                }
                            }
                        }
                    }

                    SectionTitle(text: "开不了热点也能刷：SD 卡")
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("这条路完全不碰 Wi-Fi：把固件拷到 SD 卡，让设备自己刷。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text.opacity(0.9))
                            Text("1. SD 卡用 FAT32，根目录建 update 文件夹")
                            Text("2. 把固件另存为 update/firmware.bin")
                            Text("3. 插卡，设备进 SD 刷机界面，按 ENTER")
                            Text("4. 写完自动重启")
                                .padding(.bottom, 2)
                            Text("下面的按钮把选中的固件交给系统「存储到文件」，选到读卡器里的 SD 卡即可。")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.sub)
                            if let first = localEntries.first, let f = m.localFile(for: first.id) {
                                ShareLink(item: f.url) {
                                    Label("导出 \(first.id).bin 到「文件」", systemImage: "square.and.arrow.up")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(Theme.gold)
                            } else {
                                Text("先在「固件」页下载一份固件")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.warn)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text.opacity(0.9))
                    }

                    SectionTitle(text: "打不开 192.168.4.1 时按顺序查")
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Wi-Fi 是否连的是 BlackRadar-XXXX，上面「Wi-Fi 地址」要是 192.168.4.x")
                            Text("2. 设备上要停在 Wi-Fi / 网页传输那一屏，Web 服务只在那屏跑")
                            Text("3. 关掉 VPN、加速器、代理软件（Clash/Shadowrocket 等）")
                            Text("4. 关掉 iCloud 私密代理：设置 → 你的名字 → iCloud → 私密代理")
                            Text("5. 关掉「无线局域网助理」，避免蜂窝和 Wi-Fi 来回切")
                            Text("6. 在 设置 → 无线局域网 →（i）里看「路由器」那一行，那才是真实网关")
                            Text("7. 用 http:// 不要用 https://，也不要加端口以外的路径")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sub)
                    }

                    if let up = m.uploadProgress, let id = m.uploadEntryID, m.localFile(for: id) != nil {
                        Button(role: .destructive) {
                            m.cancelUpload()
                        } label: {
                            Text("取消上传（\(Int(up * 100))%）")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle("设备")
            .scrollDismissesKeyboard(.interactively)
            .task { m.refreshNet() }
        }
    }
}

// MARK: - 资源包

struct PacksView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        Text("这些是塞进设备 SD 卡的资源：密码字典、NFC 卡库、抬杆码库、红外码库、蓝牙设备表。下载后导出到「文件」，再拷到 SD 卡根目录。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.sub)
                    }
                    ForEach(m.packs) { p in
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(p.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    Spacer()
                                    Pill(text: AppModel.sizeText(p.size))
                                    if let n = p.files {
                                        Pill(text: "\(n) 个文件")
                                    }
                                }
                                Text(p.tagline)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.sub)
                                if let prog = m.progress[p.id] {
                                    Bar(value: prog)
                                    Text("下载中 \(Int(prog * 100))%")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.sub)
                                } else {
                                    HStack {
                                        Spacer()
                                        Button {
                                            m.download(pack: p)
                                        } label: {
                                            Label("下载", systemImage: "arrow.down.circle")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    .tint(Theme.gold)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle("资源包")
        }
    }
}

// MARK: - 说明

struct AboutView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("黑雷达 Studio · iOS")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("0.1.0 (1) · iOS 17+ · 原生 SwiftUI")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.sub)
                        }
                    }

                    SectionTitle(text: "这个版本怎么刷机")
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. 手机连设备热点（BlackRadar-XXXX）")
                            Text("2. 「设备」页探测 192.168.4.1")
                            Text("3. 上传固件到 /update/firmware.bin")
                            Text("4. Cardputer 上进 SD 刷机界面按 ENTER")
                            Text("5. 等待写入完成，设备自动重启")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text.opacity(0.9))
                    }

                    SectionTitle(text: "为什么不是 USB 直刷")
                    Card {
                        Text("Android 版靠 USB OTG 直接跑 ESP32-S3 的 ROM 下载协议（SLIP 同步、128KB 分块写 flash）。iOS 没有对第三方 App 开放 USB 主机串口：CDC-ACM 设备只能被 Apple 自带的驱动认，App 读不到端点，也没有 MFi 授权。所以 iOS 版走设备自带的 WiFi 服务 + SD 刷机路径，实际写入由设备自己完成，成功率比线刷还稳。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.sub)
                    }

                    SectionTitle(text: "数据来源")
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("固件目录：madsdai.com/blackradar/studio/studio.json")
                            Text("固件包：studio/fw-*.bin（写入前做 SHA-256 校验）")
                            Text("本地文件：App 的 Documents，可在「文件」里看到")
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.sub)
                    }

                    SectionTitle(text: "日志")
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            if m.logLines.isEmpty {
                                Text("暂无").font(.system(size: 11)).foregroundStyle(Theme.sub)
                            }
                            ForEach(Array(m.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.sub)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle("说明")
        }
    }
}
