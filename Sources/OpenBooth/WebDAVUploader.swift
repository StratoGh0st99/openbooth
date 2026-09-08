//
//  WebDAVUploader.swift
//  OpenBooth
//
//  Uploads photos via WebDAV (PUT) into a folder, e.g. Nextcloud, Synology, Hetzner Storage Box.
//  Queue on disk, retries on errors. Password in the keychain.
//

import Foundation

@MainActor
final class WebDAVUploader: ObservableObject {
    struct Item: Codable, Equatable {
        let path: String          // relative to the Documents folder
        /// Immutable destination captured when queued. Optional for queues written by older builds.
        var baseURL: String? = nil
        var user: String? = nil
        var attempts: Int = 0
    }

    @Published private(set) var pending: [Item] = []
    @Published private(set) var uploaded = 0
    @Published private(set) var lastMessage = String(localized: "off")
    @Published private(set) var connectionVerified = false

    var enabled = false
    var baseURL = ""        // base URL plus event folder, e.g. https://cloud.example.de/remote.php/dav/files/paul/Hochzeit
    var user = ""
    var log: ((String) -> Void)?

    private var checkedFolders: Set<String> = []
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var queueURL: URL { docs.appendingPathComponent("webdav-queue.json") }

    init() {
        if let d = try? Data(contentsOf: queueURL), let items = try? JSONDecoder().decode([Item].self, from: d) { pending = items }
    }

    private func saveQueue() {
        if let d = try? JSONEncoder().encode(pending) { try? d.write(to: queueURL, options: .atomic) }
    }

    func configure(enabled: Bool, url: String, user: String, folder: String) {
        self.enabled = enabled
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        if !u.isEmpty { u += "/" + (folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folder) }
        if u != baseURL || self.user != user.trimmingCharacters(in: .whitespaces) { connectionVerified = false }
        baseURL = u
        self.user = user.trimmingCharacters(in: .whitespaces)
        lastMessage = enabled ? (pending.isEmpty ? String(localized: "ready") : String(localized: "\(pending.count) pending")) : String(localized: "off")
        if enabled { kick() }
    }

    func enqueue(_ fileURL: URL) {
        guard enabled else { return }
        pending.append(Item(path: fileURL.path.replacingOccurrences(of: docs.path + "/", with: ""), baseURL: baseURL, user: user))
        saveQueue()
        lastMessage = String(localized: "\(pending.count) pending")
        kick()
    }

    /// Retry now: cancel the running worker (which may be sleeping in the backoff) and restart
    func retryNow() {
        worker?.cancel(); worker = nil; workerID = nil
        for i in pending.indices { pending[i].attempts = 0 }
        kick()
    }
    /// Drop the queue (files stay until the cleanup removes them)
    func clearQueue() {
        worker?.cancel(); worker = nil; workerID = nil
        pending = []; saveQueue()
        lastMessage = enabled ? String(localized: "ready") : String(localized: "off")
        log?("WebDAV: queue cleared")
    }

    /// Drop only files belonging to one event. Other events keep their pending uploads.
    func clearQueue(relativeDirectory: String) {
        worker?.cancel(); worker = nil; workerID = nil
        let prefix = relativeDirectory.hasSuffix("/") ? relativeDirectory : relativeDirectory + "/"
        let before = pending.count
        pending.removeAll { $0.path.hasPrefix(prefix) }
        saveQueue()
        lastMessage = enabled ? (pending.isEmpty ? String(localized: "ready") : String(localized: "\(pending.count) pending")) : String(localized: "off")
        log?("WebDAV: dropped \(before - pending.count) queued file(s) for \(relativeDirectory)")
        kick()
    }

    private func kick() {
        guard worker == nil, enabled, !pending.isEmpty else { return }
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in
            await self?.drain()
            await MainActor.run {
                guard self?.workerID == id else { return }
                self?.worker = nil
                self?.workerID = nil
            }
        }
    }

    private func drain() async {
        var backoff: UInt64 = 2
        // The queue can change under us while awaiting (clearQueue, retryNow cancels this worker): always re-check
        // the head by path instead of trusting indices, and stop as soon as the task is cancelled.
        while enabled, !Task.isCancelled, let item = pending.first {
            do {
                try await upload(item)
                if Task.isCancelled { return }
                removeHead(item)
                uploaded += 1
                saveQueue()
                lastMessage = pending.isEmpty ? String(localized: "all uploaded (\(uploaded))") : String(localized: "\(pending.count) pending")
                backoff = 2
            } catch {
                if Task.isCancelled { return }
                if (error as NSError).domain == "WebDAV", (error as NSError).code == 4 {
                    log?("WebDAV: \(error.localizedDescription), entry dropped"); removeHead(item); saveQueue(); continue
                }
                guard pending.first?.path == item.path else { continue }
                pending[0].attempts += 1
                saveQueue()
                lastMessage = String(localized: "Error: \(error.localizedDescription)")
                log?("WebDAV: \(error.localizedDescription) (attempt \(pending[0].attempts), waiting \(backoff) s)")
                if pending[0].attempts >= 8 {
                    // Move the file to the end so others get through
                    var it = pending.removeFirst(); it.attempts = 0; pending.append(it); saveQueue()
                }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 120)
            }
        }
    }
    private func removeHead(_ item: Item) {
        if pending.first?.path == item.path { pending.removeFirst() }
    }

    // MARK: HTTP

    private func request(_ path: String, method: String, base: String? = nil, user targetUser: String? = nil) throws -> URLRequest {
        let targetBase = base ?? baseURL
        let targetUser = targetUser ?? user
        guard !targetBase.isEmpty, let url = URL(string: targetBase + path) else {
            throw NSError(domain: "WebDAV", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Folder URL missing or invalid")])
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 60
        if !targetUser.isEmpty {
            let pw = Keychain.get("webdavPassword") ?? ""
            let token = Data("\(targetUser):\(pw)".utf8).base64EncodedString()
            r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func status(_ resp: URLResponse) -> Int { (resp as? HTTPURLResponse)?.statusCode ?? 0 }

    /// Create the folder if missing (MKCOL; 405 = already exists).
    private func ensureFolder(base: String? = nil, user: String? = nil) async throws {
        let targetBase = base ?? baseURL
        if checkedFolders.contains(targetBase) { return }
        var probe = try request("/", method: "PROPFIND", base: targetBase, user: user)
        probe.setValue("0", forHTTPHeaderField: "Depth")
        probe.timeoutInterval = 15
        let (_, pr) = try await URLSession.shared.data(for: probe)
        switch status(pr) {
        case 200...299: checkedFolders.insert(targetBase); return
        case 401, 403: throw NSError(domain: "WebDAV", code: 401, userInfo: [NSLocalizedDescriptionKey: "Access denied (HTTP \(status(pr))): check user or password"])
        case 404: break
        default: throw NSError(domain: "WebDAV", code: status(pr), userInfo: [NSLocalizedDescriptionKey: "Server answered HTTP \(status(pr))"])
        }
        let (_, mr) = try await URLSession.shared.data(for: try request("", method: "MKCOL", base: targetBase, user: user))
        guard (200...299).contains(status(mr)) || status(mr) == 405 else {
            throw NSError(domain: "WebDAV", code: status(mr), userInfo: [NSLocalizedDescriptionKey: String(localized: "Folder could not be created (HTTP \(status(mr)))")])
        }
        checkedFolders.insert(targetBase)
        log?("WebDAV: folder created")
    }

    /// Connection test: folder reachable or creatable.
    func test() async -> String {
        do {
            checkedFolders.remove(baseURL)
            try await ensureFolder()
            connectionVerified = true
            return String(localized: "OK, folder reachable")
        } catch {
            connectionVerified = false
            return String(localized: "Error: \(error.localizedDescription)")
        }
    }

    private func upload(_ item: Item) async throws {
        let fileURL = docs.appendingPathComponent(item.path)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw NSError(domain: "WebDAV", code: 4, userInfo: [NSLocalizedDescriptionKey: "File missing: \(item.path)"])
        }
        let targetBase = item.baseURL ?? baseURL
        let targetUser = item.user ?? user
        try await ensureFolder(base: targetBase, user: targetUser)
        let name = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileURL.lastPathComponent
        var r = try request("/" + name, method: "PUT", base: targetBase, user: targetUser)
        r.timeoutInterval = 300
        r.setValue(name.lowercased().hasSuffix(".arw") ? "image/x-sony-arw" : "image/jpeg", forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await URLSession.shared.upload(for: r, from: data)
        let code = status(resp)
        guard (200...299).contains(code) else {
            let txt = String(data: d.prefix(120), encoding: .utf8) ?? ""
            throw NSError(domain: "WebDAV", code: code, userInfo: [NSLocalizedDescriptionKey: "Upload HTTP \(code) \(txt)"])
        }
        if targetBase == baseURL && targetUser == user { connectionVerified = true }
        log?("WebDAV: \(fileURL.lastPathComponent) uploaded (\(data.count / 1_000_000) MB)")
    }
}
