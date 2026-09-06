//
//  LocalWebServer.swift
//  OpenBooth
//
//  Kleine Statusseite im lokalen WLAN (Stufe 1, nur lesend): Verbindung, Bildrate, Fotos, Warteschlangen,
//  letzte Protokollzeilen, Diagnose senden. Eigener HTTP-Server auf Network.framework, kein Fremdcode.
//  Geschuetzt mit der Admin-PIN (Login setzt ein Sitzungs-Cookie), Sperre nach Fehlversuchen.
//

import Foundation
import Network

struct WebStatus: Encodable {
    var event: String
    var camera: String          // Modell oder "keine"
    var state: String
    var status: String
    var fps: Int
    var idle: Bool
    var photos: Int
    var lastPhoto: String?      // Uhrzeit des letzten Fotos
    var immich: String?         // Statusmeldung oder nil, wenn aus
    var webdav: String?
    var brightness: Int         // Prozent
    var log: [String]
    var uptime: String
}

final class LocalWebServer: @unchecked Sendable {
    static let port: UInt16 = 8787
    private let queue = DispatchQueue(label: "openbooth.web")
    private var listener: NWListener?
    private var sessions: Set<String> = []
    private var failedAttempts: [String: (count: Int, until: Date)] = [:]
    private let started = Date()

    /// Datenlieferanten, gesetzt vom CameraManager (laufen auf dem MainActor)
    var statusProvider: (@MainActor () -> WebStatus)?
    var pinProvider: (@MainActor () -> String)?
    var diagnoseAction: (@MainActor () async -> String?)?
    var log: ((String) -> Void)?

    private(set) var running = false

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.service = NWListener.Service(name: "OpenBooth", type: "_http._tcp")
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready: self?.running = true; self?.log?("Fernzugriff: Statusseite auf Port \(Self.port) bereit")
                case .failed(let e): self?.running = false; self?.log?("Fernzugriff: Fehler \(e.localizedDescription)"); self?.stop()
                case .cancelled: self?.running = false
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            log?("Fernzugriff: konnte nicht starten (\(error.localizedDescription))")
        }
    }

    func stop() {
        listener?.cancel(); listener = nil; running = false
    }

    /// mDNS-Name des iPads (z. B. Pauls-iPad.local), funktioniert von Apple-Geraeten und den meisten Browsern im selben WLAN
    static func localHostname() -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return nil }
        var name = String(cString: buf)
        guard !name.isEmpty, name != "localhost" else { return nil }
        if !name.hasSuffix(".local") { name += ".local" }
        return name
    }

    /// IPv4-Adressen des iPads (WLAN), fuer die Anzeige der URL im Admin
    static func localAddresses() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }

    // MARK: Verbindung

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if err != nil || buf.count > 1_000_000 { c.cancel(); return }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                let bodyStart = range.upperBound
                let lines = head.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
                let need = Int(headers["content-length"] ?? "0") ?? 0
                if buf.count - bodyStart < need && !done { self.receive(c, buffer: buf); return }
                let body = buf.subdata(in: bodyStart..<min(buf.count, bodyStart + need))
                let parts = lines.first?.split(separator: " ") ?? []
                let method = parts.count > 0 ? String(parts[0]) : "GET"
                let path = parts.count > 1 ? String(parts[1]) : "/"
                let ip = self.remoteIP(c)
                Task { [weak self] in
                    guard let self else { return }
                    let resp = await self.route(method: method, path: path, headers: headers, body: body, ip: ip)
                    c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
                }
            } else if done { c.cancel() } else { self.receive(c, buffer: buf) }
        }
    }

    private func remoteIP(_ c: NWConnection) -> String {
        if case .hostPort(let host, _) = c.endpoint { return "\(host)" }
        return "?"
    }

    // MARK: Routen

    private func route(method: String, path: String, headers: [String: String], body: Data, ip: String) async -> Data {
        let p = path.split(separator: "?").first.map(String.init) ?? "/"
        let cookie = headers["cookie"] ?? ""
        let token = cookie.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("ob=") }?.dropFirst(3).description
        let authed = token.map { sessions.contains($0) } ?? false

        switch (method, p) {
        case ("POST", "/login"):
            if let block = failedAttempts[ip], block.until > Date() {
                return http(429, html(loginPage(error: "Zu viele Versuche, bitte eine Minute warten.")))
            }
            let form = String(decoding: body, as: UTF8.self)
            let pin = form.components(separatedBy: "&").compactMap { kv -> String? in
                let a = kv.components(separatedBy: "="); return a.first == "pin" ? a.dropFirst().joined(separator: "=").removingPercentEncoding : nil
            }.first ?? ""
            let expected = await MainActor.run { pinProvider?() ?? "" }
            if !expected.isEmpty, pin == expected {
                let t = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                sessions.insert(t); failedAttempts[ip] = nil
                log?("Fernzugriff: Anmeldung von \(ip)")
                return http(303, Data(), extra: ["Location": "/", "Set-Cookie": "ob=\(t); Path=/; HttpOnly; SameSite=Strict"])
            }
            let n = (failedAttempts[ip]?.count ?? 0) + 1
            failedAttempts[ip] = (n, n >= 5 ? Date().addingTimeInterval(60) : Date())
            log?("Fernzugriff: falsche PIN von \(ip) (\(n))")
            return http(200, html(loginPage(error: "PIN falsch.")))
        case ("GET", "/logout"):
            if let token { sessions.remove(token) }
            return http(303, Data(), extra: ["Location": "/", "Set-Cookie": "ob=; Path=/; Max-Age=0"])
        case ("GET", "/"):
            return http(200, html(authed ? statusPage : loginPage(error: nil)))
        case ("GET", "/api/status"):
            guard authed else { return http(401, Data("unauthorized".utf8), type: "text/plain") }
            let st = await MainActor.run { statusProvider?() }
            guard let st, let json = try? JSONEncoder().encode(st) else { return http(500, Data(), type: "text/plain") }
            return http(200, json, type: "application/json; charset=utf-8")
        case ("POST", "/api/diagnose"):
            guard authed else { return http(401, Data("unauthorized".utf8), type: "text/plain") }
            let action = diagnoseAction
            let id: String? = if let action { await action() } else { nil }
            return http(200, Data((id.map { "Gesendet, Kennung \($0)" } ?? "Senden fehlgeschlagen").utf8), type: "text/plain; charset=utf-8")
        default:
            return http(404, Data("nicht gefunden".utf8), type: "text/plain; charset=utf-8")
        }
    }

    private func http(_ code: Int, _ body: Data, type: String = "text/html; charset=utf-8", extra: [String: String] = [:]) -> Data {
        let reason = [200: "OK", 303: "See Other", 401: "Unauthorized", 404: "Not Found", 429: "Too Many Requests", 500: "Error"][code] ?? "OK"
        var h = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (k, v) in extra { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        var d = Data(h.utf8); d.append(body); return d
    }

    private func html(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Seiten

    private let style = """
    <meta name=viewport content="width=device-width,initial-scale=1"><meta charset=utf-8>
    <style>body{font:16px -apple-system,system-ui,sans-serif;background:#111;color:#eee;margin:0;padding:20px;max-width:720px;margin:auto}
    h1{font-size:22px;margin:0 0 16px;display:flex;align-items:center;gap:10px}h1 small{color:#888;font-weight:400;font-size:14px}
    .card{background:#1c1c1e;border-radius:12px;padding:14px 16px;margin-bottom:12px}.row{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #2a2a2c}
    .row:last-child{border:0}.k{color:#999}.dot{display:inline-block;width:10px;height:10px;border-radius:5px;margin-right:6px}
    pre{font:12px ui-monospace,Menlo,monospace;white-space:pre-wrap;background:#000;padding:10px;border-radius:8px;max-height:320px;overflow:auto;margin:0}
    button,input{font:inherit;padding:10px 14px;border-radius:8px;border:1px solid #333;background:#2c2c2e;color:#fff}button{cursor:pointer}
    input[type=password]{letter-spacing:.3em;width:8em;text-align:center}form{display:flex;gap:10px;align-items:center}.err{color:#ff6b6b}</style>
    """

    private func loginPage(error: String?) -> String {
        """
        <!doctype html><title>OpenBooth</title>\(style)<h1>OpenBooth <small>Fernzugriff</small></h1>
        <div class=card><form method=post action=/login><input type=password name=pin inputmode=numeric autocomplete=off placeholder="PIN" autofocus>
        <button>Anmelden</button></form>\(error.map { "<p class=err>\($0)</p>" } ?? "")<p class=k>Admin-PIN der Fotobox. Nur im lokalen WLAN erreichbar.</p></div>
        """
    }

    private var statusPage: String {
        """
        <!doctype html><title>OpenBooth</title>\(style)<h1>OpenBooth <small id=ev></small></h1>
        <div class=card id=cam></div>
        <div class=card id=targets></div>
        <div class=card><div class=row><span class=k>Protokoll</span><span><button onclick=diag()>Diagnose senden</button> <span id=dres class=k></span></span></div><pre id=log>…</pre></div>
        <p class=k style="text-align:center"><a href=/logout style="color:#888">Abmelden</a></p>
        <script>
        const $=id=>document.getElementById(id);
        function row(k,v){return `<div class=row><span class=k>${k}</span><span>${v}</span></div>`}
        async function tick(){try{const r=await fetch('/api/status');if(r.status==401){location.reload();return}const s=await r.json();
        $('ev').textContent=s.event;const col=s.state=='connected'?(s.fps>0?'#34c759':'#ffd60a'):'#ff453a';
        $('cam').innerHTML=row('Kamera',`<span class=dot style="background:${col}"></span>${s.camera}`)+row('Status',s.status)+row('Liveview',s.fps+' Bilder/s')+row('Modus',s.idle?'Leerlauf (Collage)':'bereit')+row('Fotos heute',s.photos+(s.lastPhoto?' · zuletzt '+s.lastPhoto:''))+row('Display',s.brightness+' %')+row('Läuft seit',s.uptime);
        $('targets').innerHTML=row('Immich',s.immich??'aus')+row('WebDAV',s.webdav??'aus');
        $('log').textContent=s.log.join('\\n');}catch(e){}}
        async function diag(){$('dres').textContent='sende …';const r=await fetch('/api/diagnose',{method:'POST'});$('dres').textContent=await r.text()}
        tick();setInterval(tick,3000);
        </script>
        """
    }
}
