import Foundation
import Combine
import CryptoKit
import Darwin

// MARK: - 数据模型（对应 studio.json）

struct FirmwareEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let version: String
    let board: String?
    let chip: String?
    let format: String?
    let offset: Int?
    let url: String
    let sha256: String
    let size: Int64
    let highlights: [String]?
}

struct SDPack: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let url: String
    let sha256: String
    let size: Int64
    let files: Int?
}

struct Catalog: Codable {
    let firmware: [FirmwareEntry]
    let sd_packs: [SDPack]
}

// MARK: - 本地文件

struct LocalFile: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let size: Int64
    let verified: Bool
}

// MARK: - 应用状态

@MainActor
final class AppModel: ObservableObject {
    static let catalogURL = "https://madsdai.com/blackradar/studio/studio.json"
    static let userAgent = "BlackRadarStudio-iOS/1"

    @Published var entries: [FirmwareEntry] = []
    @Published var packs: [SDPack] = []
    @Published var locals: [LocalFile] = []
    @Published var catalogBusy = false
    @Published var catalogError: String?

    @Published var progress: [String: Double] = [:]
    @Published var alert: String?
    @Published var logLines: [String] = []

    // 设备侧
    @Published var host = "192.168.4.1"
    @Published var deviceOnline = false
    @Published var deviceProbing = false
    @Published var deviceDirs: [String] = []
    @Published var deviceTitle = ""
    @Published var targetDir = "/update"
    @Published var uploadProgress: Double?
    @Published var uploadEntryID: String?
    @Published var wifiIP: String?
    @Published var scanning = false
    @Published var scanFound: [String] = []
    @Published var lanScanning = false
    @Published var lanFound: [String] = []

    private var downloaders: [String: Downloader] = [:]
    private var uploader: Uploader?

    // MARK: 目录

    nonisolated static var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    nonisolated static var fwDir: URL {
        docs.appendingPathComponent("Firmware", isDirectory: true)
    }

    nonisolated static var packDir: URL {
        docs.appendingPathComponent("Packs", isDirectory: true)
    }

    nonisolated static var tempDir: URL {
        FileManager.default.temporaryDirectory
    }

    // MARK: 本机网络（iPhone 的 Wi-Fi 地址，不需要任何权限）

    nonisolated static func wifiIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        var fallback: String?
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next
            guard let addr = ifa.ifa_addr else { continue }
            if addr.pointee.sa_family != UInt8(AF_INET) { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: 64)
            let len = socklen_t(addr.pointee.sa_len)
            guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("127.") { continue }
            if name == "en0" { return ip }
            if name.hasPrefix("en") || name.hasPrefix("bridge") { fallback = ip }
        }
        return fallback
    }

    /// 常见设备地址：设备自开热点默认 192.168.4.1；iPhone 个人热点给客户端分 172.20.10.2 起
    nonisolated static var candidates: [String] {
        var list = ["192.168.4.1"]
        for i in 2...6 { list.append("172.20.10.\(i)") }
        return list
    }

    nonisolated static func reachable(_ host: String) async -> String? {
        guard let url = URL(string: "http://\(host)/") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { return host }
            return nil
        } catch {
            return nil
        }
    }

    func scanDevices() async {
        scanning = true
        scanFound = []
        defer { scanning = false }
        var found: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for c in Self.candidates {
                group.addTask { await Self.reachable(c) }
            }
            for await r in group {
                if let r, !found.contains(r) { found.append(r) }
            }
        }
        scanFound = found.sorted()
        if let first = scanFound.first {
            host = first
            log("扫描到设备 \(first)")
            await probeDevice()
        } else {
            log("扫描没找到设备（试过 \(Self.candidates.count) 个地址）")
            alert = "没扫到设备。\n\n确认：\n1. 手机连了设备热点（BlackRadar-XXXX），或设备已连上你的热点\n2. 设备停在 Wi-Fi/网页那一屏（退出就关无线）\n3. 关掉 VPN、代理、私密代理"
        }
    }

    nonisolated static func pageTitle(_ host: String) async -> String? {
        guard let url = URL(string: "http://\(host)/") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let html = String(data: data, encoding: .utf8) ?? ""
            return Self.firstMatch(html, pattern: "<title>(.*?)</title>") ?? ""
        } catch {
            return nil
        }
    }

    /// 手机和设备连同一个 Wi-Fi 时，扫本机 /24 网段找设备
    func scanLAN() async {
        guard let ip = Self.wifiIPv4() ?? wifiIP else {
            alert = "手机没有 Wi-Fi 地址，先连上和设备同一个 Wi-Fi"
            return
        }
        wifiIP = ip
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        lanScanning = true
        lanFound = []
        defer { lanScanning = false }

        var hosts: [String] = []
        for i in 1...254 { hosts.append(prefix + "\(i)") }
        var hits: [String] = []
        await withTaskGroup(of: (String, String?)?.self) { group in
            for h in hosts {
                group.addTask {
                    let title = await Self.pageTitle(h)
                    return title == nil ? nil : (h, title)
                }
            }
            for await r in group {
                guard let r = r else { continue }
                if let t = r.1, t.lowercased().contains("blackradar") {
                    hits.append(r.0)
                }
            }
        }
        lanFound = hits.sorted()
        if let first = lanFound.first {
            host = first
            log("同网段找到设备 \(first)")
            await probeDevice()
        } else {
            log("本网段扫描无结果 \(prefix)0/24")
            alert = "没在 \(prefix)0/24 扫到 BlackRadar 设备。\n\n可能：\n1. 设备没连上这个 Wi-Fi（2.4G、WPA2）\n2. 路由器开了 AP 隔离\n3. 设备在别的网段（如访客网络）"
        }
    }

    func refreshNet() {
        wifiIP = Self.wifiIPv4()
        if let ip = wifiIP {
            log("本机 Wi-Fi 地址 \(ip)")
        } else {
            log("没有 Wi-Fi 地址")
        }
    }

    init() {
        for d in [Self.fwDir, Self.packDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        scanLocal()
        loadCache()
        wifiIP = Self.wifiIPv4()
    }

    // MARK: 日志

    func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logLines.insert("[\(f.string(from: Date()))] \(s)", at: 0)
        if logLines.count > 60 { logLines.removeLast() }
    }

    // MARK: 云端目录

    private func loadCache() {
        let url = Self.docs.appendingPathComponent("catalog-cache.json")
        guard let data = try? Data(contentsOf: url) else { return }
        if let c = try? JSONDecoder().decode(Catalog.self, from: data) {
            entries = c.firmware
            packs = c.sd_packs
            log("离线缓存：\(c.firmware.count) 个固件")
        }
    }

    func refreshCatalog() async {
        catalogBusy = true
        catalogError = nil
        defer { catalogBusy = false }
        guard let url = URL(string: Self.catalogURL) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(domain: "BlackRadar", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let cat = try JSONDecoder().decode(Catalog.self, from: data)
            entries = cat.firmware
            packs = cat.sd_packs
            try? data.write(to: Self.docs.appendingPathComponent("catalog-cache.json"))
            log("固件目录已更新：\(cat.firmware.count) 个固件 / \(cat.sd_packs.count) 个资源包")
            scanLocal()
        } catch {
            catalogError = "目录获取失败：\(error.localizedDescription)"
            log(catalogError ?? "")
        }
    }

    func absoluteURL(_ s: String) -> URL? {
        if s.hasPrefix("http") { return URL(string: s) }
        return URL(string: "https://madsdai.com/blackradar/" + s)
    }

    // MARK: 本地扫描

    func scanLocal() {
        var list: [LocalFile] = []
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: Self.fwDir.path) {
            for n in names where n.hasSuffix(".bin") {
                let u = Self.fwDir.appendingPathComponent(n)
                let attrs = try? fm.attributesOfItem(atPath: u.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let id = String(n.dropLast(4))
                let verified = entries.first(where: { $0.id == id }).map { e in
                    sha256Of(u)?.caseInsensitiveCompare(e.sha256) == .orderedSame
                } ?? false
                list.append(LocalFile(id: id, name: n, url: u, size: size, verified: verified))
            }
        }
        list.sort { $0.name < $1.name }
        locals = list
    }

    func localFile(for id: String) -> LocalFile? {
        locals.first(where: { $0.id == id })
    }

    func sha256Of(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func verify(_ entry: FirmwareEntry) {
        guard let local = localFile(for: entry.id) else {
            alert = "还没有下载这个固件"
            return
        }
        guard let hex = sha256Of(local.url) else {
            alert = "读取文件失败"
            return
        }
        if hex.caseInsensitiveCompare(entry.sha256) == .orderedSame {
            alert = "SHA-256 校验通过\n\(hex)"
        } else {
            alert = "SHA-256 不匹配！\n本地：\(hex)\n期望：\(entry.sha256)"
        }
        scanLocal()
    }

    func importBin(_ url: URL) {
        let fm = FileManager.default
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let dest = Self.fwDir.appendingPathComponent(base + ".bin")
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            log("已导入 \(dest.lastPathComponent)")
            scanLocal()
        } catch {
            alert = "导入失败：\(error.localizedDescription)"
        }
    }

    func deleteLocal(_ entry: FirmwareEntry) {
        if let local = localFile(for: entry.id) {
            try? FileManager.default.removeItem(at: local.url)
            log("已删除 \(local.name)")
            scanLocal()
        }
    }

    // MARK: 下载

    func download(_ entry: FirmwareEntry) {
        guard let url = absoluteURL(entry.url) else {
            alert = "固件地址无效"
            return
        }
        if progress[entry.id] != nil { return }
        let dest = Self.fwDir.appendingPathComponent("\(entry.id).bin")
        progress[entry.id] = 0
        let d = Downloader(url: url, destination: dest)
        d.onProgress = { [weak self] p in
            DispatchQueue.main.async {
                self?.progress[entry.id] = p
            }
        }
        d.onDone = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress[entry.id] = nil
                self.downloaders[entry.id] = nil
                switch result {
                case .success(let u):
                    let ok = (self.sha256Of(u) ?? "").caseInsensitiveCompare(entry.sha256) == .orderedSame
                    self.log("已下载 \(u.lastPathComponent)（\(ok ? "校验通过" : "校验不符")）")
                    if !ok { self.alert = "下载完成，但 SHA-256 与目录不一致，请重试" }
                    self.scanLocal()
                case .failure(let e):
                    self.alert = "下载失败：\(e.localizedDescription)"
                    self.log("下载失败：\(e.localizedDescription)")
                }
            }
        }
        downloaders[entry.id] = d
        d.start()
        log("开始下载 \(entry.name) \(entry.version)")
    }

    func download(pack: SDPack) {
        guard let url = absoluteURL(pack.url) else { return }
        if progress[pack.id] != nil { return }
        let dest = Self.packDir.appendingPathComponent("\(pack.id).zip")
        progress[pack.id] = 0
        let d = Downloader(url: url, destination: dest)
        d.onProgress = { [weak self] p in
            DispatchQueue.main.async { self?.progress[pack.id] = p }
        }
        d.onDone = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress[pack.id] = nil
                self.downloaders[pack.id] = nil
                switch result {
                case .success(let u):
                    let ok = (self.sha256Of(u) ?? "").caseInsensitiveCompare(pack.sha256) == .orderedSame
                    self.log("资源包 \(u.lastPathComponent) \(ok ? "校验通过" : "校验不符")")
                    if !ok { self.alert = "资源包校验不符，请重试" }
                case .failure(let e):
                    self.alert = "下载失败：\(e.localizedDescription)"
                }
            }
        }
        downloaders[pack.id] = d
        d.start()
        log("开始下载资源包 \(pack.name)")
    }

    // MARK: 设备

    func probeDevice() async {
        deviceProbing = true
        deviceOnline = false
        deviceDirs = []
        deviceTitle = ""
        defer { deviceProbing = false }

        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard var comps = URLComponents(string: "http://\(trimmed)/") else {
            alert = "地址无效"
            return
        }
        comps.path = "/"
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let html = String(data: data, encoding: .utf8) ?? ""
            deviceOnline = code == 200
            let title = Self.firstMatch(html, pattern: "<title>(.*?)</title>") ?? ""
            deviceTitle = title
            deviceDirs = Self.allMatches(html, pattern: "<option value=\"([^\"]*)\"")
            if !deviceDirs.isEmpty && !deviceDirs.contains(targetDir) {
                if let idx = deviceDirs.firstIndex(where: { $0.lowercased().contains("update") }) {
                    targetDir = deviceDirs[idx]
                }
            }
            log("设备在线：\(trimmed) \(title) 目录 \(deviceDirs.count) 个")
        } catch {
            deviceOnline = false
            alert = "连不上 \(trimmed)\n\n1. 手机 Wi-Fi 是否连在设备热点（BlackRadar-XXXX）？本机地址：\(wifiIP ?? "无 Wi-Fi")\n2. 设备上是否已打开 Wi-Fi / 网页传输页面？Web 服务只在那一页跑。\n3. 关掉 VPN、代理、iCloud 私密代理再试。\n\n\(error.localizedDescription)"
            log("探测失败：\(error.localizedDescription)")
        }
    }

    func upload(_ entry: FirmwareEntry) {
        guard let local = localFile(for: entry.id) else {
            alert = "先下载固件"
            return
        }
        let dir = targetDir.trimmingCharacters(in: .whitespaces)
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host.trimmingCharacters(in: .whitespaces)
        comps.path = "/upload"
        comps.queryItems = [URLQueryItem(name: "dir", value: dir.isEmpty ? "/update" : dir)]
        guard let url = comps.url else {
            alert = "地址无效"
            return
        }
        let boundary = "----BlackRadarBoundary\(Int(Date().timeIntervalSince1970))"
        let bodyFile: URL
        do {
            bodyFile = try Multipart.build(source: local.url, field: "f", filename: "firmware.bin",
                                           boundary: boundary, tempDir: Self.tempDir)
        } catch {
            alert = "打包上传数据失败：\(error.localizedDescription)"
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        uploadProgress = 0
        uploadEntryID = entry.id
        let u = Uploader(request: req, file: bodyFile)
        u.onProgress = { [weak self] p in
            DispatchQueue.main.async { self?.uploadProgress = p }
        }
        u.onDone = { [weak self] code, text in
            DispatchQueue.main.async {
                guard let self else { return }
                self.uploadProgress = nil
                self.uploadEntryID = nil
                self.uploader = nil
                try? FileManager.default.removeItem(at: bodyFile)
                self.log("上传完成 HTTP \(code)")
                if code == 200 || code == 201 || code == 204 {
                    self.alert = "已上传到设备 \(dir)\n文件名 firmware.bin\n\n现在在 Cardputer 上进入 SD 刷机界面，按 ENTER 开始写入。"
                } else {
                    let head = String(text.prefix(200))
                    self.alert = "设备返回 HTTP \(code)\n\(head)"
                }
            }
        }
        u.onError = { [weak self] e in
            DispatchQueue.main.async {
                guard let self else { return }
                self.uploadProgress = nil
                self.uploadEntryID = nil
                self.uploader = nil
                try? FileManager.default.removeItem(at: bodyFile)
                self.alert = "上传失败：\(e.localizedDescription)"
                self.log("上传失败：\(e.localizedDescription)")
            }
        }
        uploader = u
        u.start()
        log("开始上传 \(entry.name) 到 \(url.absoluteString)")
    }

    func cancelUpload() {
        uploader?.cancel()
        uploader = nil
        uploadProgress = nil
        uploadEntryID = nil
    }

    // MARK: 小工具

    nonisolated static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    nonisolated static func allMatches(_ text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            if m.numberOfRanges > 1 {
                let v = ns.substring(with: m.range(at: 1))
                if !out.contains(v) { out.append(v) }
            }
        }
        return out
    }

    nonisolated static func sizeText(_ bytes: Int64) -> String {
        if bytes <= 0 { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
