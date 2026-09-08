//
//  ImmichUploader.swift
//  OpenBooth
//
//  Uploads photos to an Immich album automatically. Queue on disk, retries on errors.
//  API: POST /api/assets (multipart), GET/POST /api/albums, PUT /api/albums/{id}/assets, Header x-api-key.
//

import Foundation
import Security
import UIKit

/// API key in the keychain, not in UserDefaults.
enum Keychain {
    private static let service = "de.reingruber.openbooth"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

@MainActor
final class ImmichUploader: ObservableObject {
    struct Item: Codable, Equatable {
        let path: String          // relative to the Documents folder
        let createdAt: Date
        /// Immutable destination captured when the photo is queued. Optional for queues written by older builds.
        var server: String? = nil
        var album: String? = nil
        var attempts: Int = 0
    }

    @Published private(set) var pending: [Item] = []
    @Published private(set) var uploaded = 0
    @Published private(set) var lastMessage = String(localized: "off")
    @Published private(set) var busy = false
    @Published private(set) var connectionVerified = false

    @Published private(set) var shareURL: String?   // public share link of the album (for the QR code)

    var enabled = false
    var serverURL = ""      // e.g. https://immich.example.de
    var albumName = ""
    var log: ((String) -> Void)?

    private var albumIDs: [String: String] = [:]
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private let deviceID = "openbooth-" + (UIDevice.current.identifierForVendor?.uuidString ?? "ipad")
    private var queueURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("immich-queue.json") }
    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    init() {
        if let d = try? Data(contentsOf: queueURL), let items = try? JSONDecoder().decode([Item].self, from: d) { pending = items }
    }

    private func saveQueue() {
        if let d = try? JSONEncoder().encode(pending) { try? d.write(to: queueURL, options: .atomic) }
    }

    func configure(enabled: Bool, server: String, album: String) {
        self.enabled = enabled
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s != serverURL || album != albumName { connectionVerified = false; shareURL = nil }
        serverURL = s
        albumName = album.trimmingCharacters(in: .whitespaces)
        lastMessage = enabled ? (pending.isEmpty ? String(localized: "ready") : String(localized: "\(pending.count) pending")) : String(localized: "off")
        if enabled { kick() }
    }

    /// Enqueue a file (processed immediately when possible).
    func enqueue(_ fileURL: URL) {
        guard enabled else { return }
        let rel = fileURL.path.replacingOccurrences(of: docs.path + "/", with: "")
        pending.append(Item(path: rel, createdAt: Date(), server: serverURL, album: albumName))
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
        log?("Immich: queue cleared")
    }

    /// Drop only files belonging to one event. Other events keep their pending uploads.
    func clearQueue(relativeDirectory: String) {
        worker?.cancel(); worker = nil; workerID = nil
        let prefix = relativeDirectory.hasSuffix("/") ? relativeDirectory : relativeDirectory + "/"
        let before = pending.count
        pending.removeAll { $0.path.hasPrefix(prefix) }
        saveQueue()
        lastMessage = enabled ? (pending.isEmpty ? String(localized: "ready") : String(localized: "\(pending.count) pending")) : String(localized: "off")
        log?("Immich: dropped \(before - pending.count) queued file(s) for \(relativeDirectory)")
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
        busy = true
        defer { busy = false }
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
                if (error as NSError).domain == "Immich", (error as NSError).code == 4 {
                    log?("Immich: \(error.localizedDescription), entry dropped"); removeHead(item); saveQueue(); continue
                }
                guard pending.first?.path == item.path else { continue }
                pending[0].attempts += 1
                saveQueue()
                lastMessage = String(localized: "Error: \(error.localizedDescription)")
                log?("Immich: \(error.localizedDescription) (attempt \(pending[0].attempts), waiting \(backoff) s)")
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

    // MARK: API

    private func request(_ path: String, method: String = "GET", server: String? = nil) throws -> URLRequest {
        let base = server ?? serverURL
        guard let url = URL(string: base + path), let key = Keychain.get("immichAPIKey"), !key.isEmpty else {
            throw NSError(domain: "Immich", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Server or API key missing")])
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 60
        return r
    }

    /// Connection test: server response and user.
    func test(createShareLink: Bool) async -> String {
        do {
            var r = try request("/api/users/me")
            r.timeoutInterval = 10
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return "HTTP \(code): check API key or address" }
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            let who = (j?["email"] as? String) ?? (j?["name"] as? String) ?? "?"
            let id = try await ensureAlbum()
            connectionVerified = true
            if createShareLink {
                let link = try await ensureShareLink()
                return "OK as \(who), album “\(albumName)” (\(id.prefix(8))…), share \(link)"
            }
            return "OK as \(who), album “\(albumName)” (\(id.prefix(8))…)"
        } catch {
            connectionVerified = false
            return String(localized: "Error: \(error.localizedDescription)")
        }
    }

    private func ensureAlbum(server: String? = nil, name: String? = nil) async throws -> String {
        let base = server ?? serverURL
        let targetAlbum = name ?? albumName
        let cacheKey = base + "\n" + targetAlbum
        if let id = albumIDs[cacheKey] { return id }
        guard !targetAlbum.isEmpty else { throw NSError(domain: "Immich", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "No album name")]) }
        let (d, _) = try await URLSession.shared.data(for: try request("/api/albums", server: base))
        if let list = try JSONSerialization.jsonObject(with: d) as? [[String: Any]],
           let hit = list.first(where: { ($0["albumName"] as? String) == targetAlbum }), let id = hit["id"] as? String {
            albumIDs[cacheKey] = id
            return id
        }
        var r = try request("/api/albums", method: "POST", server: base)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["albumName": targetAlbum])
        let (cd, cresp) = try await URLSession.shared.data(for: r)
        guard let code = (cresp as? HTTPURLResponse)?.statusCode, (200...201).contains(code),
              let j = try JSONSerialization.jsonObject(with: cd) as? [String: Any], let id = j["id"] as? String else {
            throw NSError(domain: "Immich", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Album could not be created")])
        }
        albumIDs[cacheKey] = id
        log?("Immich: album “\(targetAlbum)” created")
        return id
    }

    /// Fetch or create the public share link of the album (for the guests' QR code).
    @discardableResult
    func ensureShareLink() async throws -> String {
        if let shareURL { return shareURL }
        let album = try await ensureAlbum()
        let base = serverURL
        let (d, _) = try await URLSession.shared.data(for: try request("/api/shared-links"))
        if let list = try JSONSerialization.jsonObject(with: d) as? [[String: Any]],
           let hit = list.first(where: { ($0["type"] as? String) == "ALBUM" && (($0["album"] as? [String: Any])?["id"] as? String) == album }),
           let key = hit["key"] as? String {
            shareURL = base + "/share/" + key
            return shareURL!
        }
        var r = try request("/api/shared-links", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["type": "ALBUM", "albumId": album, "allowDownload": true,
                                                                 "allowUpload": false, "showMetadata": true,
                                                                 "description": "OpenBooth \(albumName)"])
        let (cd, cresp) = try await URLSession.shared.data(for: r)
        guard let code = (cresp as? HTTPURLResponse)?.statusCode, (200...201).contains(code),
              let j = try JSONSerialization.jsonObject(with: cd) as? [String: Any], let key = j["key"] as? String else {
            throw NSError(domain: "Immich", code: 5, userInfo: [NSLocalizedDescriptionKey: String(localized: "Share link could not be created")])
        }
        shareURL = base + "/share/" + key
        log?("Immich: share link for “\(albumName)” created")
        return shareURL!
    }

    private func upload(_ item: Item) async throws {
        let fileURL = docs.appendingPathComponent(item.path)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw NSError(domain: "Immich", code: 4, userInfo: [NSLocalizedDescriptionKey: "File missing: \(item.path)"])
        }
        let targetServer = item.server ?? serverURL
        let targetAlbum = item.album ?? Self.eventName(from: item.path) ?? albumName
        let album = try await ensureAlbum(server: targetServer, name: targetAlbum)

        let boundary = "openbooth-\(UUID().uuidString)"
        var r = try request("/api/assets", method: "POST", server: targetServer)
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 300
        let iso = ISO8601DateFormatter()
        let name = fileURL.lastPathComponent
        let mime = name.lowercased().hasSuffix(".arw") ? "image/x-sony-arw" : "image/jpeg"
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        field("deviceAssetId", "\(deviceID)-\(name)")
        field("deviceId", deviceID)
        field("fileCreatedAt", iso.string(from: item.createdAt))
        field("fileModifiedAt", iso.string(from: item.createdAt))
        field("isFavorite", "false")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let (d, resp) = try await URLSession.shared.upload(for: r, from: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...201).contains(code), let j = try JSONSerialization.jsonObject(with: d) as? [String: Any], let assetID = j["id"] as? String else {
            let txt = String(data: d.prefix(200), encoding: .utf8) ?? ""
            throw NSError(domain: "Immich", code: code, userInfo: [NSLocalizedDescriptionKey: "Upload HTTP \(code) \(txt)"])
        }

        var a = try request("/api/albums/\(album)/assets", method: "PUT", server: targetServer)
        a.setValue("application/json", forHTTPHeaderField: "Content-Type")
        a.httpBody = try JSONSerialization.data(withJSONObject: ["ids": [assetID]])
        let (_, aresp) = try await URLSession.shared.data(for: a)
        let acode = (aresp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...201).contains(acode) else {
            throw NSError(domain: "Immich", code: acode, userInfo: [NSLocalizedDescriptionKey: "Album assignment HTTP \(acode)"])
        }
        if targetServer == serverURL && targetAlbum == albumName { connectionVerified = true }
        log?("Immich: \(name) uploaded (\(data.count / 1_000_000) MB)\(j["status"] as? String == "duplicate" ? ", already there" : "")")
    }

    /// Old queue files did not contain an album; recover it from Documents/Fotos/<event>/… where possible.
    private static func eventName(from path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "Fotos" else { return nil }
        return String(parts[1])
    }
}
