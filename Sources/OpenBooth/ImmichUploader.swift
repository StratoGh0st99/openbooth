//
//  ImmichUploader.swift
//  OpenBooth
//
//  Laedt Fotos automatisch in ein Immich-Album. Warteschlange auf Platte, Wiederholung bei Fehlern.
//  API: POST /api/assets (multipart), GET/POST /api/albums, PUT /api/albums/{id}/assets, Header x-api-key.
//

import Foundation
import Security
import UIKit

/// API-Key im Schluesselbund, nicht in UserDefaults.
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
        let path: String          // relativ zum Documents-Ordner
        let createdAt: Date
        var attempts: Int = 0
    }

    @Published private(set) var pending: [Item] = []
    @Published private(set) var uploaded = 0
    @Published private(set) var lastMessage = String(localized: "off")
    @Published private(set) var busy = false

    @Published private(set) var shareURL: String?   // oeffentlicher Freigabelink des Albums (fuer den QR-Code)

    var enabled = false
    var serverURL = ""      // z. B. https://immich.example.de
    var albumName = ""
    var log: ((String) -> Void)?

    private var albumID: String?
    private var worker: Task<Void, Never>?
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
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if s != serverURL || album != albumName { albumID = nil; shareURL = nil }
        serverURL = s.hasSuffix("/") ? String(s.dropLast()) : s
        albumName = album.trimmingCharacters(in: .whitespaces)
        lastMessage = enabled ? (pending.isEmpty ? String(localized: "ready") : String(localized: "\(pending.count) pending")) : String(localized: "off")
        if enabled { kick() }
    }

    /// Datei in die Warteschlange (wird sofort verarbeitet, wenn moeglich).
    func enqueue(_ fileURL: URL) {
        guard enabled else { return }
        let rel = fileURL.path.replacingOccurrences(of: docs.path + "/", with: "")
        pending.append(Item(path: rel, createdAt: Date()))
        saveQueue()
        lastMessage = String(localized: "\(pending.count) pending")
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
        busy = true
        defer { busy = false }
        var backoff: UInt64 = 2
        while enabled, let item = pending.first {
            do {
                try await upload(item)
                pending.removeFirst()
                uploaded += 1
                saveQueue()
                lastMessage = pending.isEmpty ? String(localized: "all uploaded (\(uploaded))") : String(localized: "\(pending.count) pending")
                backoff = 2
            } catch {
                if (error as NSError).domain == "Immich", (error as NSError).code == 4 {
                    log?("Immich: \(error.localizedDescription), entry dropped"); pending.removeFirst(); saveQueue(); continue
                }
                pending[0].attempts += 1
                saveQueue()
                lastMessage = String(localized: "Error: \(error.localizedDescription)")
                log?("Immich: \(error.localizedDescription) (attempt \(pending[0].attempts), waiting \(backoff) s)")
                if pending[0].attempts >= 8 {
                    // Datei ans Ende, damit andere durchkommen
                    let it = pending.removeFirst(); pending.append(Item(path: it.path, createdAt: it.createdAt, attempts: 0)); saveQueue()
                }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 120)
            }
        }
    }

    // MARK: API

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let url = URL(string: serverURL + path), let key = Keychain.get("immichAPIKey"), !key.isEmpty else {
            throw NSError(domain: "Immich", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Server or API key missing")])
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 60
        return r
    }

    /// Verbindungstest: Serverantwort und Benutzer.
    func test() async -> String {
        do {
            var r = try request("/api/users/me")
            r.timeoutInterval = 10
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return "HTTP \(code): check API key or address" }
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            let who = (j?["email"] as? String) ?? (j?["name"] as? String) ?? "?"
            let id = try await ensureAlbum()
            let link = try await ensureShareLink()
            return "OK as \(who), album “\(albumName)” (\(id.prefix(8))…), share \(link)"
        } catch {
            return String(localized: "Error: \(error.localizedDescription)")
        }
    }

    private func ensureAlbum() async throws -> String {
        if let albumID { return albumID }
        guard !albumName.isEmpty else { throw NSError(domain: "Immich", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "No album name")]) }
        let (d, _) = try await URLSession.shared.data(for: try request("/api/albums"))
        if let list = try JSONSerialization.jsonObject(with: d) as? [[String: Any]],
           let hit = list.first(where: { ($0["albumName"] as? String) == albumName }), let id = hit["id"] as? String {
            albumID = id
            return id
        }
        var r = try request("/api/albums", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["albumName": albumName])
        let (cd, cresp) = try await URLSession.shared.data(for: r)
        guard let code = (cresp as? HTTPURLResponse)?.statusCode, (200...201).contains(code),
              let j = try JSONSerialization.jsonObject(with: cd) as? [String: Any], let id = j["id"] as? String else {
            throw NSError(domain: "Immich", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Album could not be created")])
        }
        albumID = id
        log?("Immich: album “\(albumName)” created")
        return id
    }

    /// Oeffentlichen Freigabelink des Albums holen oder anlegen (fuer den QR-Code der Gaeste).
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
        let album = try await ensureAlbum()

        let boundary = "openbooth-\(UUID().uuidString)"
        var r = try request("/api/assets", method: "POST")
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

        var a = try request("/api/albums/\(album)/assets", method: "PUT")
        a.setValue("application/json", forHTTPHeaderField: "Content-Type")
        a.httpBody = try JSONSerialization.data(withJSONObject: ["ids": [assetID]])
        let (_, aresp) = try await URLSession.shared.data(for: a)
        let acode = (aresp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...201).contains(acode) else {
            throw NSError(domain: "Immich", code: acode, userInfo: [NSLocalizedDescriptionKey: "Album assignment HTTP \(acode)"])
        }
        log?("Immich: \(name) uploaded (\(data.count / 1_000_000) MB)\(j["status"] as? String == "duplicate" ? ", already there" : "")")
    }
}
