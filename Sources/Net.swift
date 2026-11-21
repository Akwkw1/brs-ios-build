import Foundation

/// 下载器：带进度回调，完成后把文件落在 destination。
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private var session: URLSession!
    private var task: URLSessionDownloadTask!
    private var finishedURL: URL?
    private var failure: Error?

    var onProgress: ((Double) -> Void)?
    var onDone: ((Result<URL, Error>) -> Void)?

    init(url: URL, destination: URL) {
        self.destination = destination
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 900
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        req.setValue("BlackRadarStudio-iOS/1", forHTTPHeaderField: "User-Agent")
        task = session.downloadTask(with: req)
    }

    func start() {
        task.resume()
    }

    func cancel() {
        task.cancel()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(p)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = NSError(domain: "BlackRadar", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
            finishedURL = destination
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let e = error {
            onDone?(.failure(e))
            return
        }
        if let f = failure {
            onDone?(.failure(f))
            return
        }
        if let u = finishedURL {
            onDone?(.success(u))
        } else {
            onDone?(.failure(NSError(domain: "BlackRadar", code: -1,
                                     userInfo: [NSLocalizedDescriptionKey: "下载未完成"])))
        }
    }
}

/// 上传器：multipart 文件上传到设备 HTTP 服务，带进度回调。
final class Uploader: NSObject, URLSessionDataDelegate {
    private var session: URLSession!
    private var task: URLSessionUploadTask!
    private var body = Data()

    var onProgress: ((Double) -> Void)?
    var onDone: ((Int, String) -> Void)?
    var onError: ((Error) -> Void)?

    init(request: URLRequest, file: URL) {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 1800
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        task = session.uploadTask(with: request, fromFile: file)
    }

    func start() {
        task.resume()
    }

    func cancel() {
        task.cancel()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if body.count < 200000 {
            body.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let e = error {
            onError?(e)
            return
        }
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: body, encoding: .utf8) ?? ""
        onDone?(code, text)
    }
}

enum Multipart {
    /// 把 header + 文件内容 + footer 写成一个大文件，交给 uploadTask(fromFile:)。
    static func build(source: URL, field: String, filename: String, boundary: String, tempDir: URL) throws -> URL {
        let fm = FileManager.default
        let out = tempDir.appendingPathComponent("brs-upload-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: out.path, contents: nil) else {
            throw NSError(domain: "BlackRadar", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建临时文件"])
        }
        let fh = try FileHandle(forWritingTo: out)
        let head = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"
        try fh.write(contentsOf: Data(head.utf8))

        let input = try FileHandle(forReadingFrom: source)
        while true {
            let chunk = try input.read(upToCount: 131072) ?? Data()
            if chunk.isEmpty { break }
            try fh.write(contentsOf: chunk)
        }
        try input.close()
        try fh.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try fh.close()
        return out
    }
}
