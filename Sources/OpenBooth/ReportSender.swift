//
//  ReportSender.swift
//  OpenBooth
//
//  Schickt einen Diagnosebericht an den OpenBooth-Endpunkt. Nur auf Wunsch des Nutzers (Knopf) oder, wenn
//  eingeschaltet, bei Fehlern (hoechstens alle 10 Minuten). Der Token filtert nur Bots; das Repo ist oeffentlich.
//

import Foundation

enum ReportSender {
    static let endpoint = URL(string: "https://openbooth.reingrubers.de/report")!
    static let token = "et63HKQSOVVEHIfAWTzrVt0KkjckOUSl"

    /// Kamera-Seriennummer kuerzen, sonst geht der Bericht unveraendert.
    static func sanitize(_ text: String) -> String {
        var out = text
        if let r = out.range(of: #"Seriennummer (\S+)"#, options: .regularExpression) {
            let full = String(out[r]).replacingOccurrences(of: "Seriennummer ", with: "")
            out.replaceSubrange(r, with: "Seriennummer …\(full.suffix(4))")
        }
        return out
    }

    /// Liefert die Kennung des Servers oder wirft.
    static func send(fileURL: URL, appVersion: String) async throws -> String {
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        let body = Data(sanitize(raw).utf8)
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.setValue(token, forHTTPHeaderField: "X-OpenBooth-Token")
        r.setValue(appVersion, forHTTPHeaderField: "X-OpenBooth-Version")
        let (d, resp) = try await URLSession.shared.upload(for: r, from: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let id = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw NSError(domain: "Report", code: code, userInfo: [NSLocalizedDescriptionKey: "Server antwortet mit HTTP \(code)"])
        }
        return id
    }
}
