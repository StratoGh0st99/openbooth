//
//  WebDAVUploader.swift
//  OpenBooth
//
//  Laedt Fotos per WebDAV (PUT) in einen Ordner, z. B. Nextcloud, Synology, Hetzner Storage Box.
//  Warteschlange auf Platte, Wiederholung bei Fehlern. Passwort im Schluesselbund.
//

import Foundation

@MainActor
final class WebDAVUploader: ObservableObject {
    struct Item: Codable, Equatable {
        let path: String          // relativ zum Documents-Ordner
        var attempts: Int = 0
    }

    @Published private(set) var pending: [Item] = []
    @Published private(set) var uploaded = 0
    @Published private(set) var lastMessage = "aus"

    var enabled = false
    var baseURL = ""        // Basis-URL plus Eventordner, z. B. https://cloud.example.de/remote.php/dav/files/paul/Hochzeit
    var user = ""
    var log: ((String) -> Void)?

    private var folderChecked = false
    private var worker: Task<Void, Never>?
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
        if u != baseURL { folderChecked = false }
        baseURL = u
        self.user = user.trimmingCharacters(in: .whitespaces)
        lastMessage = enabled ? (pending.isEmpty ? "bereit" : "\(pending.count) ausstehend") : "aus"
        if enabled { kick() }
    }

    func enqueue(_ fileURL: URL) {
        guard enabled else { return }
        pending.append(Item(path: fileURL.path.replacingOccurrences(of: docs.path + "/", with: "")))
        saveQueue()
        lastMessage = "\(pending.count) ausstehend"
        kick()
    }

    private func kick() {
        guard worker == nil, enabled, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drain()
            await MainActor.run { self?.worker = nil }
        }
    }

    private func drain() async {
        var backoff: UInt64 = 2
        while enabled, let item = pending.first {
            do {
                try await upload(item)
                pending.removeFirst()
                uploaded += 1
                saveQueue()
                lastMessage = pending.isEmpty ? "alles hochgeladen (\(uploaded))" : "\(pending.count) ausstehend"
                backoff = 2
            } catch {
                if (error as NSError).domain == "WebDAV", (error as NSError).code == 4 {
                    log?("WebDAV: \(error.localizedDescription), Eintrag verworfen"); pending.removeFirst(); saveQueue(); continue
                }
                pending[0].attempts += 1
                saveQueue()
                lastMessage = "Fehler: \(error.localizedDescription)"
                log?("WebDAV: \(error.localizedDescription) (Versuch \(pending[0].attempts), warte \(backoff) s)")
                if pending[0].attempts >= 8 {
                    let it = pending.removeFirst(); pending.append(Item(path: it.path)); saveQueue()
                }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 120)
            }
        }
    }

    // MARK: HTTP

    private func request(_ path: String, method: String) throws -> URLRequest {
        guard !baseURL.isEmpty, let url = URL(string: baseURL + path) else {
            throw NSError(domain: "WebDAV", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ordner-URL fehlt oder ist ungültig"])
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 60
        if !user.isEmpty {
            let pw = Keychain.get("webdavPassword") ?? ""
            let token = Data("\(user):\(pw)".utf8).base64EncodedString()
            r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func status(_ resp: URLResponse) -> Int { (resp as? HTTPURLResponse)?.statusCode ?? 0 }

    /// Ordner anlegen, falls er fehlt (MKCOL; 405 = existiert schon).
    private func ensureFolder() async throws {
        if folderChecked { return }
        var probe = try request("/", method: "PROPFIND")
        probe.setValue("0", forHTTPHeaderField: "Depth")
        probe.timeoutInterval = 15
        let (_, pr) = try await URLSession.shared.data(for: probe)
        switch status(pr) {
        case 200...299: folderChecked = true; return
        case 401, 403: throw NSError(domain: "WebDAV", code: 401, userInfo: [NSLocalizedDescriptionKey: "Zugang verweigert (HTTP \(status(pr))): Benutzer oder Passwort prüfen"])
        case 404: break
        default: throw NSError(domain: "WebDAV", code: status(pr), userInfo: [NSLocalizedDescriptionKey: "Server antwortet mit HTTP \(status(pr))"])
        }
        let (_, mr) = try await URLSession.shared.data(for: try request("", method: "MKCOL"))
        guard (200...299).contains(status(mr)) || status(mr) == 405 else {
            throw NSError(domain: "WebDAV", code: status(mr), userInfo: [NSLocalizedDescriptionKey: "Ordner konnte nicht angelegt werden (HTTP \(status(mr)))"])
        }
        folderChecked = true
        log?("WebDAV: Ordner angelegt")
    }

    /// Verbindungstest: Ordner erreichbar oder anlegbar.
    func test() async -> String {
        do {
            folderChecked = false
            try await ensureFolder()
            return "OK, Ordner erreichbar"
        } catch {
            return "Fehler: \(error.localizedDescription)"
        }
    }

    private func upload(_ item: Item) async throws {
        let fileURL = docs.appendingPathComponent(item.path)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw NSError(domain: "WebDAV", code: 4, userInfo: [NSLocalizedDescriptionKey: "Datei fehlt: \(item.path)"])
        }
        try await ensureFolder()
        let name = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileURL.lastPathComponent
        var r = try request("/" + name, method: "PUT")
        r.timeoutInterval = 300
        r.setValue(name.lowercased().hasSuffix(".arw") ? "image/x-sony-arw" : "image/jpeg", forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await URLSession.shared.upload(for: r, from: data)
        let code = status(resp)
        guard (200...299).contains(code) else {
            let txt = String(data: d.prefix(120), encoding: .utf8) ?? ""
            throw NSError(domain: "WebDAV", code: code, userInfo: [NSLocalizedDescriptionKey: "Upload HTTP \(code) \(txt)"])
        }
        log?("WebDAV: \(fileURL.lastPathComponent) hochgeladen (\(data.count / 1_000_000) MB)")
    }
}
