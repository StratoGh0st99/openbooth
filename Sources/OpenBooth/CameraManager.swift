//
//  CameraManager.swift
//  OpenBooth
//
//  Findet USB-Kameras ueber ImageCaptureCore, oeffnet die Session und haelt den Sony-Treiber.
//

import Foundation
import ImageCaptureCore
import UIKit
import Photos
import ImageIO

@MainActor
final class CameraManager: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, browsing, deviceFound, sessionOpen, probed, connected, error(String)
    }

    @Published var state: State = .idle
    @Published var devices: [ICCameraDevice] = []
    @Published var log: [String] = []
    @Published var deviceSummary = ""
    @Published var liveFrame: UIImage?
    @Published var liveRunning = false
    @Published var lastPhoto: UIImage?
    @Published var status = String(localized: "Connect a camera")
    @Published var authorization = "unbekannt"
    @Published var settings: [CameraSetting] = []
    @Published var settingsBusy = false
    var autoConnect: Bool { settingsRef?.autoConnect ?? true }
    weak var settingsRef: AppSettings? { didSet { syncUploaders() } }
    /// Nach Aenderung von Eventname oder Zielen: Fotoordner wechseln und alle Upload-Ziele neu konfigurieren.
    func syncUploaders() {
        if let s = settingsRef { switchEvent(to: Self.safeName(s.eventName)) }
        syncImmich(); syncWebDAV(); syncWeb(); syncFallback()
    }

    // MARK: Ersatz: iPad-Kamera, wenn keine Kamera per USB da ist

    private(set) var ipadCam: IPadCamera?
    @Published private(set) var usingIPadCamera = false
    private var fallbackTimer: Task<Void, Never>?

    /// Nach 4 s ohne USB-Kamera die iPad-Kamera starten (wenn eingeschaltet); bei USB-Kamera sofort stoppen.
    private func scheduleFallback() {
        fallbackTimer?.cancel()
        guard settingsRef?.ipadFallback ?? true, sony == nil, device == nil, devices.isEmpty else { return }
        fallbackTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.sony == nil, self.device == nil, self.devices.isEmpty else { return }
            await self.startIPadCamera()
        }
    }
    private func startIPadCamera() async {
        guard ipadCam == nil, settingsRef?.ipadFallback ?? true else { return }
        guard await IPadCamera.authorized() else { appendLog("iPad camera: no access (Settings › OpenBooth › Camera)"); return }
        let cam = IPadCamera()
        do {
            try cam.start(front: settingsRef?.ipadFrontCamera ?? true) { [weak self] img in
                Task { @MainActor in self?.ingestFallbackFrame(img) }
            }
        } catch { appendLog("iPad camera: \(error.localizedDescription)"); return }
        ipadCam = cam
        usingIPadCamera = true
        state = .connected
        status = String(localized: "iPad camera (fallback)")
        liveRunning = true
        lastFrame = Date()
        banner = nil
        appendLog("iPad camera started as fallback (\(settingsRef?.ipadFrontCamera ?? true ? "front" : "rear") camera)")
    }
    func stopIPadCamera(reason: String) {
        fallbackTimer?.cancel(); fallbackTimer = nil
        guard let cam = ipadCam else { return }
        cam.stop(); ipadCam = nil
        usingIPadCamera = false
        liveRunning = false
        liveFrame = nil
        liveHistogram = nil
        if sony == nil { state = .browsing; status = String(localized: "Looking for a camera…") }
        appendLog("iPad camera stopped (\(reason))")
    }
    /// Einstellungen geaendert: Ersatzkamera an/aus oder Front/Rueck wechseln
    func syncFallback() {
        guard let s = settingsRef else { return }
        if !s.ipadFallback { stopIPadCamera(reason: "disabled"); return }
        if let cam = ipadCam, cam.position == (s.ipadFrontCamera ? .front : .back) { return }
        if ipadCam != nil { stopIPadCamera(reason: "camera switched") }
        scheduleFallback()
    }
    private var fallbackMotion = MotionDetector()
    private var fallbackFrames = 0
    private func ingestFallbackFrame(_ img: UIImage) {
        guard ipadCam != nil else { return }
        liveFrame = img; lastFrame = Date(); frameCount += 1
        fallbackFrames += 1
        if motionArmed {
            let hit = fallbackMotion.feed(img, threshold: motionThreshold)
            motionResult(level: fallbackMotion.level, hit: hit, noise: fallbackMotion.noiseLevel, global: fallbackMotion.globalLevel)
        } else { fallbackMotion.reset() }
        if wantHistogram, fallbackFrames % 3 == 0 { liveHistogram = Histogram.compute(img) } else if !wantHistogram, liveHistogram != nil { liveHistogram = nil }
    }

    // MARK: Fernzugriff (Statusseite im WLAN)

    let web = LocalWebServer()
    private var lastFPS = 0
    func syncWeb() {
        guard let s = settingsRef else { return }
        web.log = { [weak self] m in Task { @MainActor in self?.appendLog(m) } }
        web.pinProvider = { [weak self] in self?.settingsRef?.pin ?? "" }
        web.diagnoseAction = { [weak self] in await self?.sendDiagnostics(reason: "Remote access") }
        web.statusProvider = { [weak self] in self?.webStatus() ?? WebStatus(event: "", camera: "none", state: "", status: "", fps: 0, idle: false, photos: 0, lastPhoto: nil, immich: nil, webdav: nil, brightness: 0, log: [], uptime: "", ipadBattery: "", cameraBattery: nil, motionThreshold: 6, motionLevel: 0) }
        web.settingsAction = { [weak self] key, value in
            guard let s = self?.settingsRef else { return false }
            switch key {
            case "motionThreshold": guard (2...40).contains(value) else { return false }; s.motionThreshold = value
            default: return false
            }
            self?.appendLog("Remote: \(key) = \(value)")
            return true
        }
        if s.webEnabled { web.start() } else { web.stop() }
    }
    private let startedAt = Date()
    private func webStatus() -> WebStatus {
        let s = settingsRef
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        let up = Int(Date().timeIntervalSince(startedAt))
        let stateName: String = { switch state { case .connected: return "connected"; case .error: return "error"; default: return "\(state)" } }()
        return WebStatus(event: s?.eventName ?? "",
                         camera: sony?.deviceInfo.model.isEmpty == false ? sony!.deviceInfo.model : (ipadCam != nil ? String(localized: "iPad camera (fallback)") : (devices.first?.name ?? "none")),
                         state: stateName, status: status, fps: lastFPS, idle: idle, photos: sessionPhotos.count,
                         lastPhoto: sessionPhotos.first.flatMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.map { f.string(from: $0) },
                         immich: s?.immichEnabled == true ? immich.lastMessage : nil,
                         webdav: s?.webdavEnabled == true ? webdav.lastMessage : nil,
                         brightness: Int(UIScreen.main.brightness * 100),
                         log: Array(log.suffix(50)), uptime: String(format: "%dh %02dmin", up / 3600, (up % 3600) / 60),
                         ipadBattery: batteryText(iPadBattery()), cameraBattery: cameraBattery(),
                         motionThreshold: s?.motionThreshold ?? 6, motionLevel: motionLevel)
    }

    /// Fotos liegen je Veranstaltung unter Documents/Fotos/<Name>/ (RAW in raw/ darunter).
    private static var currentEvent = String(localized: "Photo Booth")
    private func switchEvent(to name: String) {
        Self.migrateFlatPhotos(into: name)
        guard name != Self.currentEvent || sessionPhotos.isEmpty else { return }
        Self.currentEvent = name
        dismissResult()
        sessionPhotos = Self.loadSessionPhotos()
        lastPhoto = nil
        appendLog("Event “\(name)”: \(sessionPhotos.count) photos")
    }
    /// Einmalig: Fotos aus der alten flachen Struktur Documents/Fotos/*.jpg in den Ordner der Veranstaltung schieben.
    private static func migrateFlatPhotos(into name: String) {
        let fm = FileManager.default
        let root = photosRoot
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let flat = items.filter { $0.pathExtension.lowercased() == "jpg" }
        let oldRaw = root.appendingPathComponent("raw", isDirectory: true)
        guard !flat.isEmpty || fm.fileExists(atPath: oldRaw.path) else { return }
        let target = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: target.appendingPathComponent("raw"), withIntermediateDirectories: true)
        for f in flat { try? fm.moveItem(at: f, to: target.appendingPathComponent(f.lastPathComponent)) }
        if let raws = try? fm.contentsOfDirectory(at: oldRaw, includingPropertiesForKeys: nil) {
            for r in raws { try? fm.moveItem(at: r, to: target.appendingPathComponent("raw/" + r.lastPathComponent)) }
            try? fm.removeItem(at: oldRaw)
        }
    }
    let immich = ImmichUploader()
    let webdav = WebDAVUploader()
    func syncWebDAV() {
        guard let s = settingsRef else { return }
        webdav.log = { [weak self] m in Task { @MainActor in self?.appendLog(m) } }
        webdav.configure(enabled: s.webdavEnabled, url: s.webdavURL, user: s.webdavUser, folder: Self.safeName(s.eventName))
    }
    /// Eventname als Album- und Ordnername: ohne Pfadzeichen, nie leer.
    static func safeName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        return t.isEmpty ? String(localized: "Photo Booth") : t
    }
    /// Datei an alle aktiven Upload-Ziele geben.
    private func upload(_ url: URL, isRAW: Bool) {
        if !isRAW || settingsRef?.immichUploadRAW == true { immich.enqueue(url) }
        if !isRAW || settingsRef?.webdavUploadRAW == true { webdav.enqueue(url) }
    }

    func syncImmich() {
        guard let s = settingsRef else { return }
        immich.log = { [weak self] m in Task { @MainActor in self?.appendLog(m) } }
        immich.configure(enabled: s.immichEnabled, server: s.immichURL, album: Self.safeName(s.eventName))
        if s.immichEnabled, immich.shareURL == nil, !s.immichURL.isEmpty {
            Task { [weak self] in
                do { try await self?.immich.ensureShareLink() } catch { self?.appendLog("Immich: share link: \(error.localizedDescription)") }
            }
        }
    }
    @Published var idle = false {   // Leerlauf: Collage anzeigen
        didSet {
            guard idle != oldValue else { return }
            lastNoiseLog = Date()   // Ruhepegel erst 30 s nach Leerlaufbeginn protokollieren
            updateBrightness()
            if !idle, settingsRef?.soundsEnabled ?? true, settingsRef?.soundWelcome ?? true { Sounds.shared.play("welcome") }
        }
    }
    @Published var motionLevel: Double = 0    // letzte Bildaenderung im Leerlauf (Debug)
    @Published var liveHistogram: Histogram?  // alle 3 Liveview-Bilder, wenn im Admin eingeschaltet
    @Published var resultHistogram: Histogram?
    private var wantHistogram: Bool { settingsRef?.showHistogram ?? false }
    /// Bewegungserkennung aktiv? Wird vom Liveview-Task gelesen (laeuft dort im Hintergrund, nicht auf dem Main-Thread).
    private var motionArmed: Bool { idle && (settingsRef?.motionWake ?? true) }
    private var motionThreshold: Double { Double(settingsRef?.motionThreshold ?? 8) }

    /// Rueckmeldung fuer Gaeste, klar und ohne Technik.
    struct Banner: Equatable {
        enum Kind { case info, working, warning, error }
        let kind: Kind
        let text: String
        var detail: String? = nil
    }
    @Published var banner: Banner? = Banner(kind: .info, text: String(localized: "Connect a camera"))
    @Published var captureError: String?      // Overlay mit "Try again"
    @Published var lastError: String?         // fuer das Admin-Panel
    private var recoverAttempts = 0
    private var recoverTask: Task<Void, Never>?
    private var connectedSince: Date?
    private var lastInteraction = Date()
    private var lastFrame = Date()
    private var watchdog: Timer?
    @Published var countdown: Int?            // 3, 2, 1 vor der Aufnahme
    @Published var capturePhrase: String?     // "Cheese!" waehrend der Aufnahme
    private var lastPhrase = ""
    /// Zufaelliger Spruch aus den Einstellungen, nie zweimal derselbe hintereinander.
    private func nextPhrase() -> String {
        let list = (settingsRef?.phrases ?? AppSettings.defaultPhrases).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { return "Cheese!" }
        var p = list.randomElement()!
        if list.count > 1 { while p == lastPhrase { p = list.randomElement()! } }
        lastPhrase = p
        return p
    }
    @Published var resultPhoto: UIImage?      // grosse Vorschau nach der Aufnahme (erstes Bild der Serie)
    @Published var resultPhotos: [UIImage] = [] // alle Bilder der Serie
    @Published var resultURLs: [URL] = []       // zugehoerige Dateien im App-Ordner
    @Published var resultShownAt: Date?       // fuer den Restzeit-Balken
    @Published var shotNumber = 0             // laufende Nummer in der Serie (1..n), 0 = keine Serie
    @Published var shotTotal = 1
    @Published var capturing = false
    @Published var sessionPhotos: [URL] = []  // Fotos des Abends, neueste zuerst
    var resultSeconds: Double { Double(settingsRef?.resultSeconds ?? 10) }
    private var resultTask: Task<Void, Never>?

    private let browser = ICDeviceBrowser()
    private var device: ICCameraDevice?
    private(set) var sony: SonyCamera?
    private var liveTask: Task<Void, Never>?

    override init() {
        super.init()
        browser.delegate = self
        sessionPhotos = Self.loadSessionPhotos()
        UIApplication.shared.isIdleTimerDisabled = true   // iPad bleibt an
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private var tickCount = 0
    private var frameCount = 0
    /// Alle 2 s: Leerlauf erkennen, Liveview ueberwachen, Log-Kopie schreiben.
    private func tick() {
        tickCount += 1
        sampleUserBrightness()
        if tickCount % 150 == 0 { appendLog("Battery: iPad \(batteryText(iPadBattery())), camera \(cameraBattery().map { "\($0) %" } ?? "unknown")") }
        if tickCount % 3 == 0 { Self.logFile.snapshot() }
        if tickCount % 15 == 0, liveRunning { lastFPS = frameCount / 30; appendLog("Live view: \(lastFPS) fps"); frameCount = 0 }
        if !liveRunning { lastFPS = 0 }
        let idleFor = Date().timeIntervalSince(lastInteraction)
        let limit = TimeInterval(settingsRef?.idleSeconds ?? 120)
        let shouldIdle = idleFor > limit && !capturing && resultPhoto == nil && countdown == nil && !sessionPhotos.isEmpty
        if shouldIdle != idle { idle = shouldIdle }

        // Liveview-Waechter: seit 8 s kein Bild -> neu starten. Kommen aber Kamera-Events (Kamera arbeitet, z. B. eigener
        // Ausloeser, Menue offen), erst nach 20 s: dann ist der Liveview wirklich haengen geblieben.
        let stalled = Date().timeIntervalSince(lastFrame)
        let eventsRecently = Date().timeIntervalSince(lastEventAt) < 8
        if state == .connected, liveRunning, !capturing, ipadCam == nil, stalled > (eventsRecently ? 20 : 8) {
            appendLog(String(format: "Live view stalled for %.0f s%@, restarting", stalled, eventsRecently ? " (camera is sending events)" : ""))
            stopLiveView()
            startLiveView()
        }
        // Verbunden, aber Liveview aus (z. B. nach Fehlern) -> wieder an
        if state == .connected, !liveRunning, !capturing, !settingsBusy, autoConnect, sony != nil, ipadCam == nil {
            startLiveView()
        }
        // Fremdausloesung: mit Events nur noch alle 30 s als Sicherheitsnetz, sonst alle 2 s
        if !eventsWorking || tickCount % 15 == 0 { pollExternalCapture() }
        if tickCount % 30 == 0, !eventCounts.isEmpty {
            appendLog("Events last 60 s: " + eventCounts.sorted { $0.key < $1.key }.map { String(format: "0x%04X×%d", $0.key, $0.value) }.joined(separator: " "))
            eventCounts = [:]
        }
    }

    /// Ergebnis der Bewegungserkennung aus dem Liveview-Task.
    private var lastNoiseLog = Date.distantPast
    private func motionResult(level: Double, hit: Bool, noise: Double = 0, global: Double = 0) {
        motionLevel = level
        // alle 30 s im Leerlauf (erst nach Einschwingen, nicht direkt beim Leerlaufbeginn): Ruhepegel und Rauschen
        if noise > 0, Date().timeIntervalSince(lastNoiseLog) > 30 {
            lastNoiseLog = Date()
            appendLog(String(format: "Motion idle level: cell %.1f, global %.1f, noise %.1f, threshold %d", level, global, noise, settingsRef?.motionThreshold ?? 8))
        }
        if hit, idle {
            appendLog(String(format: "Motion detected (%.1f), collage off", level))
            noteInteraction()
        }
    }

    /// Faehigkeitsbericht der Kamera nach Documents/openbooth-capabilities.log (holen mit tools/pull-caps.sh).
    static var capabilitiesURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("openbooth-capabilities.log") }
    private func writeCapabilities(_ cam: SonyCamera) {
        let report = cam.capabilitiesReport()
        try? report.data(using: .utf8)?.write(to: Self.capabilitiesURL, options: .atomic)
        let di = cam.deviceInfo
        appendLog("Capabilities: \(di.operations.count) operations, \(di.events.count) events, \(di.properties.count)+\(cam.vendorProps.count) properties, \(cam.controlCodes.count) control codes → openbooth-capabilities.log")
        appendLog("Operations: " + di.operations.sorted().map { PTPNames.hex($0) }.joined(separator: " "))
    }

    // MARK: Display-Helligkeit

    /// QR-Seite sichtbar (setzt ContentView), erzwingt volle Helligkeit.
    @Published var qrShown = false { didSet { updateBrightness() } }
    private var forcingBrightness = false                        // wir halten gerade volle Helligkeit
    private var userBrightness: CGFloat = UIScreen.main.brightness // Wert des Nutzers, nur gemessen, wenn wir nicht eingreifen

    /// Volle Helligkeit bei QR-Seite oder Option "dauerhaft", nicht waehrend der Leerlauf-Collage.
    /// Der Nutzerwert wird laufend im tick() gemessen, solange wir nicht eingreifen. So kann er nie versehentlich
    /// mit 1.0 ueberschrieben werden (frueher: Wert beim Hochdrehen gemerkt, war er da schon 1.0, blieb es dabei).
    func updateBrightness() {
        let wantFull = qrShown || ((settingsRef?.maxBrightness ?? false) && !idle)
        let screen = UIScreen.main
        if wantFull, !forcingBrightness {
            sampleUserBrightness()
            forcingBrightness = true
            screen.brightness = 1.0
            appendLog(String(format: "Brightness full (was %.2f)", userBrightness))
        } else if !wantFull, forcingBrightness {
            forcingBrightness = false
            screen.brightness = userBrightness
            appendLog(String(format: "Brightness back to %.2f", userBrightness))
        }
    }

    /// Nutzerwert merken, aber nie einen Wert, den wir selbst gesetzt haben.
    private func sampleUserBrightness() {
        guard !forcingBrightness else { return }
        let b = UIScreen.main.brightness
        if b < 0.98 { userBrightness = b }
    }

    /// Beim Verlassen der App die Helligkeit des Nutzers wiederherstellen.
    func restoreBrightness() {
        if forcingBrightness { UIScreen.main.brightness = userBrightness; forcingBrightness = false }
    }

    /// Diagnosedatei zum Teilen: Umgebung, aktueller Faehigkeitsbericht mit Rohdaten, komplettes Protokoll.
    // MARK: Akku

    /// iPad-Akku in Prozent (-1 unbekannt) und ob es laedt
    func iPadBattery() -> (Int, Bool) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let l = UIDevice.current.batteryLevel
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        return (l < 0 ? -1 : Int((l * 100).rounded()), charging)
    }
    func batteryText(_ b: (Int, Bool)) -> String { b.0 < 0 ? String(localized: "unknown") : "\(b.0) %\(b.1 ? String(localized: " (charging)") : "")" }
    /// Kamera-Akku in Prozent aus Sony-Property 0xD218 (aktualisiert bei jedem Property-Abruf)
    func cameraBattery() -> Int? {
        guard let cam = sony else { return nil }
        if let v = cam.currentValue(0xD218) { return Int(v) }
        if let v = cam.currentValue(0x5001) { return Int(v) }
        return nil
    }

    /// Diagnose an den OpenBooth-Endpunkt schicken. Liefert die Kennung des Servers.
    @Published private(set) var reportStatus = ""
    private var lastAutoReport = Date.distantPast
    func sendDiagnostics(reason: String) async -> String? {
        guard let url = makeDiagnosticsFile() else { return nil }
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + "-" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
        reportStatus = String(localized: "Sending…")
        do {
            let id = try await ReportSender.send(fileURL: url, appVersion: v)
            reportStatus = "Sent, ID \(id)"
            appendLog("Diagnostics sent (\(reason)), ID \(id)")
            return id
        } catch {
            reportStatus = "Sending failed: \(error.localizedDescription)"
            appendLog("Send diagnostics: \(error.localizedDescription)")
            return nil
        }
    }
    /// Bei Fehlern automatisch, wenn eingeschaltet, hoechstens alle 10 Minuten.
    private func autoReport(_ reason: String) {
        guard settingsRef?.autoReports == true, Date().timeIntervalSince(lastAutoReport) > 600 else { return }
        lastAutoReport = Date()
        Task { await sendDiagnostics(reason: "automatic: \(reason)") }
    }

    func makeDiagnosticsFile() -> URL? {
        var text = Diagnostics.environment(settingsRef)
        text += "Camera state: \(status)\(lastError.map { ", last error: \($0)" } ?? "")\n\n"
        if let cam = sony { text += cam.capabilitiesReport() }
        else if let d = try? String(contentsOf: Self.capabilitiesURL, encoding: .utf8) { text += d }
        else { text += "(no capability report, camera not detected yet)\n" }
        text += "\n# Log\n"
        Self.logFile.snapshot()
        let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("openbooth.export.log")
        text += (try? String(contentsOf: logURL, encoding: .utf8)) ?? log.joined(separator: "\n")
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("OpenBooth-Diagnose-\(f.string(from: Date())).txt")
        do { try text.data(using: .utf8)?.write(to: out, options: .atomic); return out } catch { appendLog("Diagnostics: \(error.localizedDescription)"); return nil }
    }

    func noteInteraction() {
        lastInteraction = Date()
        if idle { idle = false }
    }

    func appendLog(_ s: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "\(ts)  \(s)"
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
        Self.logFile.append(line)
    }

    /// Logdatei im App-Ordner (Documents/openbooth.log), abholbar per devicectl. Wird bei 2 MB rotiert.
    static let logFile = LogFile()
    final class LogFile {
        private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("openbooth.log")
        private let q = DispatchQueue(label: "openbooth.log")
        init() { append("===== App started \(Date()) =====") }
        /// Abgeschlossene Kopie fuer den Download (die wachsende Datei laesst sich per devicectl nicht uebertragen).
        func snapshot() {
            q.async {
                let dst = self.url.deletingLastPathComponent().appendingPathComponent("openbooth.export.log")
                guard let data = try? Data(contentsOf: self.url) else { return }
                try? data.write(to: dst, options: .atomic)
            }
        }
        func append(_ line: String) {
            q.async {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: self.url.path), let size = attrs[.size] as? Int, size > 2_000_000 {
                    try? FileManager.default.moveItem(at: self.url, to: self.url.deletingPathExtension().appendingPathExtension("1.log"))
                }
                guard let data = (line + "\n").data(using: .utf8) else { return }
                if let h = try? FileHandle(forWritingTo: self.url) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                } else {
                    try? data.write(to: self.url)
                }
            }
        }
    }

    // MARK: Suche

    func start() {
        appendLog("Requesting authorization…")
        #if targetEnvironment(simulator)
        // Der Simulator kennt weder USB-Kameras noch die Autorisierungsabfrage von ImageCaptureCore
        authorization = "Simulator"
        state = .browsing
        status = String(localized: "Simulator: no camera available")
        banner = Banner(kind: .info, text: String(localized: "Connect a camera"), detail: String(localized: "Sony in “PC Remote” mode via USB-C"))
        return
        #endif
        browser.requestContentsAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.authorization = Self.describe(status)
                self.appendLog("Authorization: \(self.authorization)")
                self.browser.start()
                self.state = .browsing
                self.status = String(localized: "Looking for a camera…")
                if self.authorization == "denied" {
                    self.banner = Banner(kind: .error, text: String(localized: "No access to the camera"), detail: String(localized: "Allow Camera under Settings › OpenBooth"))
                } else if self.devices.isEmpty {
                    self.banner = Banner(kind: .info, text: String(localized: "Connect a camera"), detail: String(localized: "Sony in “PC Remote” mode via USB-C"))
                    self.scheduleFallback()
                }
            }
        }
    }

    static func describe(_ s: ICAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        default: return "\(s.rawValue)"
        }
    }

    // MARK: Session

    func openSession(_ dev: ICCameraDevice) {
        device = dev
        dev.delegate = self
        appendLog("Opening session: \(dev.name ?? "?")")
        status = String(localized: "Connecting…")
        dev.requestOpenSession { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error = error {
                    self.appendLog("Session error: \(error.localizedDescription)")
                    self.state = .error(error.localizedDescription)
                    self.status = String(localized: "Session failed")
                    self.lastError = error.localizedDescription
                    self.scheduleRecover(reason: "Session")
                    return
                }
                self.appendLog("Session open")
                self.state = .sessionOpen
                self.status = "Session open"
                self.banner = Banner(kind: .working, text: String(localized: "Connecting camera…"))
                let cam = SonyCamera(device: dev)
                self.sony = cam
                await cam.transport.setLogHandler { [weak self] line in
                    Task { @MainActor in self?.appendLog(line) }
                }
                if self.autoConnect {
                    if await self.probeAsync(), await self.connectAsync() {
                        self.startLiveView()
                    } else {
                        self.scheduleRecover(reason: "Connection")
                    }
                }
            }
        }
    }

    /// Meilenstein 1: GetDeviceInfo durchreichen. Entscheidet, ob iPadOS PTP-Passthrough erlaubt.
    func probe() { Task { _ = await probeAsync() } }

    @discardableResult
    func probeAsync() async -> Bool {
        guard let cam = sony else { return false }
        do {
                let info = try await cam.probe()
                let ops = info.operations.map { String(format: "%04X", $0) }.joined(separator: " ")
                deviceSummary = "\(info.manufacturer) \(info.model) FW \(info.deviceVersion), VendorExt 0x\(String(info.vendorExtensionID, radix: 16)), \(info.operations.count) Operationen"
                appendLog("DeviceInfo OK: \(deviceSummary)")
                appendLog("Operations: \(ops)")
                appendLog("Events: " + info.events.map { String(format: "%04X", $0) }.joined(separator: " "))
                appendLog("Properties: " + info.properties.map { String(format: "%04X", $0) }.joined(separator: " "))
                writeCapabilities(cam)   // schon nach dem Probe, damit auch fremde Kameras (Handshake scheitert) im Bericht landen
                state = .probed
                status = String(localized: "PTP pass-through works")
                return true
            } catch {
                appendLog("PROBE ERROR: \(error.localizedDescription)  [\((error as NSError).domain) \((error as NSError).code)]")
                state = .error(error.localizedDescription)
                status = String(localized: "PTP pass-through blocked")
                lastError = error.localizedDescription
                return false
            }
    }

    func connect() { Task { _ = await connectAsync() } }

    @discardableResult
    func connectAsync() async -> Bool {
        guard let cam = sony else { return false }
            do {
                status = String(localized: "Sony handshake…")
                try await cam.connect()
                appendLog("Handshake OK, protocol 0x\(String(cam.protocolVersion, radix: 16)), \(cam.vendorCodes.count) vendor codes, \(cam.props.count) properties")
                writeCapabilities(cam)
                if let iso = cam.currentValue(SonyProp.iso) { appendLog("ISO = \(iso)") }
                if let f = cam.currentValue(SonyProp.fNumber) { appendLog("Aperture = f/\(Double(f) / 100)") }
                if let s = cam.currentValue(SonyProp.shutterSpeed) { appendLog("Shutter = \(SonyFormat.label(code: SonyProp.shutterSpeed, value: s))") }
                appendLog("ObjectInMemory(0xD215) = \(cam.currentValue(SonyProp.objectInMemory).map(String.init) ?? "fehlt"), FocusFound(0xD213) = \(cam.currentValue(SonyProp.focusFound).map(String.init) ?? "fehlt")")
                state = .connected
                status = String(localized: "Connected")
                settings = cam.settings()
                await restoreRememberedSettings(cam)
                connectedSince = Date()
                recoverAttempts = 0
                lastError = nil
                banner = Banner(kind: .working, text: String(localized: "Camera ready, image coming…"))
                return true
            } catch {
                appendLog("HANDSHAKE ERROR: \(error.localizedDescription)")
                state = .error(error.localizedDescription)
                status = String(localized: "Handshake failed")
                lastError = error.localizedDescription
                return false
            }
    }

    // MARK: Einstellungen

    func reloadSettings() {
        guard let cam = sony else { return }
        Task {
            do { try await cam.refreshProps(); settings = cam.settings() }
            catch { appendLog("Reading settings: \(error.localizedDescription)") }
        }
    }

    /// Gesetzten Wert je Kameramodell merken, damit er beim naechsten Anstecken wieder gesetzt wird
    private func remember(code: UInt16, value: Int64, for cam: SonyCamera) {
        guard let s = settingsRef else { return }
        let model = cam.deviceInfo.model.isEmpty ? "Camera" : cam.deviceInfo.model
        var m = s.rememberedCamera[model] ?? [:]
        m[String(format: "%04X", code)] = Int(value)
        s.rememberedCamera[model] = m
    }

    /// Nach dem Verbinden: gemerkte Werte setzen, die von der Kamera abweichen (nur schreibbare Properties).
    private func restoreRememberedSettings(_ cam: SonyCamera) async {
        guard let s = settingsRef, s.restoreCameraSettings else { return }
        let model = cam.deviceInfo.model.isEmpty ? "Camera" : cam.deviceInfo.model
        guard let saved = s.rememberedCamera[model], !saved.isEmpty else { return }
        var applied = 0
        for (hex, value) in saved.sorted(by: { $0.key < $1.key }) {
            guard let code = UInt16(hex, radix: 16), let cur = cam.currentValue(code), cur != Int64(value) else { continue }
            guard cam.settings().first(where: { $0.code == code })?.writable == true else { continue }
            do {
                try await cam.setSetting(code, to: Int64(value))
                applied += 1
                appendLog("Restored: 0x\(hex) = \(SonyFormat.label(code: code, value: Int64(value)))")
            } catch { appendLog("Restore 0x\(hex): \(error.localizedDescription)") }
        }
        if applied > 0 { try? await cam.refreshProps(); settings = cam.settings(); appendLog("\(applied) camera setting(s) restored from the app") }
    }

    func apply(_ code: UInt16, value: Int64) {
        guard let cam = sony, !settingsBusy else { return }
        settingsBusy = true
        let wasLive = liveTask != nil
        stopLiveView()
        Task {
            do {
                try await cam.setSetting(code, to: value) { [weak self] m in Task { @MainActor in self?.appendLog(m) } }
                appendLog("Setting 0x\(String(code, radix: 16)) = \(SonyFormat.label(code: code, value: value))")
                remember(code: code, value: value, for: cam)
            } catch {
                appendLog("SETTING ERROR: \(error.localizedDescription)")
                status = String(localized: "Setting not applied")
            }
            settings = cam.settings()
            settingsBusy = false
            if wasLive { startLiveView() }
        }
    }

    // MARK: Liveview

    func startLiveView() {
        if ipadCam != nil { liveRunning = true; return }
        guard let cam = sony, liveTask == nil else { return }
        liveRunning = true
        lastFrame = Date()
        liveTask = Task { [weak self] in
            var failures = 0
            var histCounter = 0
            var motion = MotionDetector()
            while !Task.isCancelled {
                do {
                    if let jpeg = try await cam.liveViewFrame(), let raw = UIImage(data: jpeg) {
                        // JPEG hier im Hintergrund dekodieren, damit der Main-Thread nur noch anzeigt
                        let img = raw.preparingForDisplay() ?? raw
                        let (armed, threshold, wantHist) = await MainActor.run { (self?.motionArmed ?? false, self?.motionThreshold ?? 8, self?.wantHistogram ?? false) }
                        var level = 0.0, hit = false, noise = 0.0, global = 0.0
                        if armed { hit = motion.feed(img, threshold: threshold); level = motion.level; noise = motion.noiseLevel; global = motion.globalLevel } else { motion.reset() }
                        histCounter += 1
                        let hist: Histogram? = (wantHist && histCounter % 3 == 0) ? Histogram.compute(img) : nil
                        await MainActor.run {
                            if let hist { self?.liveHistogram = hist } else if !wantHist, self?.liveHistogram != nil { self?.liveHistogram = nil }
                            self?.liveFrame = img; self?.lastFrame = Date(); self?.frameCount += 1
                            if self?.banner != nil { self?.banner = nil }
                            if armed { self?.motionResult(level: level, hit: hit, noise: noise, global: global) } else if self?.motionLevel != 0 { self?.motionLevel = 0 }
                        }
                        failures = 0
                    } else {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                } catch {
                    failures += 1
                    await MainActor.run { self?.appendLog("Live view: \(error.localizedDescription)") }
                    if failures > 20 {
                        await MainActor.run { self?.scheduleRecover(reason: "live view") }
                        break
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            await MainActor.run { self?.liveRunning = false; self?.liveTask = nil }
        }
    }

    func stopLiveView() {
        liveTask?.cancel()
        liveTask = nil
        liveRunning = false
    }

    // MARK: Wiederherstellung

    /// Verbindung neu aufbauen: Session schliessen, kurz warten, neu oeffnen. Mit Zaehler und klarer Rueckmeldung.
    func scheduleRecover(reason: String) {
        guard recoverTask == nil, let dev = device else { return }
        recoverAttempts += 1
        appendLog("Recovery #\(recoverAttempts) (\(reason))")
        if recoverAttempts > 5 {
            banner = Banner(kind: .error, text: String(localized: "Camera not responding"), detail: String(localized: "Power-cycle the camera or reconnect USB"))
            autoReport("camera not responding after 5 attempts")
            recoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)   // danach weiter versuchen, aber langsamer
                await MainActor.run { self?.recoverTask = nil; self?.recoverAttempts = 3; self?.scheduleRecover(reason: "retry") }
            }
            return
        }
        banner = Banner(kind: .warning, text: String(localized: "Reconnecting to the camera…"), detail: "Attempt \(recoverAttempts) of 5")
        stopLiveView()
        state = .deviceFound
        recoverTask = Task { [weak self] in
            try? await dev.requestCloseSession()
            try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * min(4, self?.recoverAttempts ?? 1)))
            await MainActor.run {
                guard let self else { return }
                self.recoverTask = nil
                self.sony = nil
                if self.devices.contains(where: { $0 === dev }) {
                    self.device = nil
                    self.openSession(dev)
                } else {
                    self.banner = Banner(kind: .warning, text: String(localized: "Camera disconnected"), detail: String(localized: "Please check the USB cable"))
                }
            }
        }
    }

    // MARK: Aufnahme

    /// Fotobox-Ablauf: Countdown, ein oder mehrere Bilder mit Pause, grosse Vorschau, speichern.
    func capture(withCountdown seconds: Int = 3) {
        guard sony != nil || ipadCam != nil, !capturing else { return }
        let cam = sony
        noteInteraction()
        dismissResult()
        let shots = max(1, settingsRef?.shotsPerCapture ?? 1)
        let interval = max(0, settingsRef?.shotInterval ?? 3)
        if seconds > 0 { countdown = seconds }
        capturing = true
        shotTotal = shots
        shotNumber = 0
        Task {
            let wasLive = liveTask != nil
            var taken: [UIImage] = []
            var takenURLs: [URL] = []
            for shot in 1...shots {
                shotNumber = shot
                // Countdown: beim ersten Bild der eingestellte, danach die Pause
                let cd = shot == 1 ? seconds : interval
                if wasLive, liveTask == nil, cd >= 2 { startLiveView() }   // Pause mit Liveview ueberbruecken
                let beep = (settingsRef?.soundsEnabled ?? true) && (settingsRef?.soundCountdown ?? true)
                for n in stride(from: cd, through: 1, by: -1) {
                    countdown = n
                    if beep { Sounds.shared.play("tick") }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                capturePhrase = nextPhrase()
                if beep { Sounds.shared.play("shot") }
                countdown = nil
                stopLiveView()
                do {
                    let objects: [CapturedObject]
                    if let cam {
                        objects = try await cam.capture { [weak self] msg in
                            Task { @MainActor in self?.status = msg; self?.appendLog(msg) }
                        }
                    } else if let ip = ipadCam {
                        let o = try await ip.capture()
                        appendLog("iPad camera: \(o.filename) (\(o.data.count / 1024) KB)")
                        objects = [o]
                    } else { throw SonyError.noSession }
                    if let (img, url) = try await store(objects) { taken.append(img); takenURLs.append(url) }
                } catch {
                    appendLog("CAPTURE ERROR (image \(shot)/\(shots)): \(error.localizedDescription)")
                    status = String(localized: "Capture failed")
                    lastError = error.localizedDescription
                    if taken.isEmpty {
                        captureError = Self.friendly(error)
                        autoReport(String(localized: "Capture failed"))
                        capturePhrase = nil
                        break
                    }
                }
                capturePhrase = nil
            }
            shotNumber = 0
            if !taken.isEmpty {
                showResult(taken, urls: takenURLs)
                status = taken.count == 1 ? String(localized: "Photo saved") : "\(taken.count) photos saved"
            }
            capturing = false
            if wasLive { startLiveView() }
        }
    }

    /// Objekte einer Aufnahme sichern: App-Galerie (immer), Mediathek und Immich nach Einstellung.
    /// Liefert Vorschaubild und Galerie-URL fuer die Rueckschau.
    private func store(_ objects: [CapturedObject]) async throws -> (UIImage, URL)? {
        var result: (UIImage, URL)?
        let jpegObj = objects.first { $0.isJPEG } ?? objects.first { !$0.isRAW }
        let rawObj = objects.first { $0.isRAW }
        let stamp = Self.stamp()
        var rawURL: URL?
        if let raw = rawObj {
            rawURL = try Self.saveRAW(raw.data, stamp: stamp)
            appendLog("RAW saved: \(rawURL!.lastPathComponent) (\(raw.data.count / 1_000_000) MB)")
            upload(rawURL!, isRAW: true)
        }
        if let jpeg = jpegObj?.data {
            let url = try Self.saveToDocuments(jpeg, stamp: stamp)
            ThumbnailStore.prepare(url)
            sessionPhotos.insert(url, at: 0)
            upload(url, isRAW: false)
            if settingsRef?.saveToPhotos ?? true {
                Self.saveToPhotos(jpeg, raw: rawObj?.data) { [weak self] m in Task { @MainActor in self?.appendLog(m) } }
            }
            if let img = await Self.previewImage(from: jpeg) { result = (img, url); lastPhoto = img }
        } else if let raw = rawObj, let rawURL {
            // Nur RAW: ARW als RAW in die Mediathek, Vorschau aus dem eingebetteten Bild
            if settingsRef?.saveToPhotos ?? true {
                Self.saveRAWOnlyToPhotos(raw.data) { [weak self] m in Task { @MainActor in self?.appendLog(m) } }
            }
            let preview = await Self.previewImage(from: raw.data)
            appendLog(preview == nil ? "RAW preview: no decodable preview in the ARW" : "RAW preview: \(Int(preview!.size.width))x\(Int(preview!.size.height))")
            if let img = preview {
                result = (img, rawURL); lastPhoto = img
                // JPEG-Ableitung fuer Galerie und Collage neben das ARW legen
                if let jpg = img.jpegData(compressionQuality: 0.9) {
                    let url = try Self.saveToDocuments(jpg, stamp: stamp)
                    ThumbnailStore.prepare(url)
                    sessionPhotos.insert(url, at: 0)
                    result = (img, url)
                }
            }
        }
        return result
    }

    // MARK: PTP-Events (zuhoeren statt fragen)

    private var eventCounts: [UInt16: Int] = [:]
    private(set) var eventsWorking = false      // mindestens ein ObjectAdded empfangen: Fremdausloesung laeuft ueber Events

    private var lastEventAt = Date.distantPast
    private func handleEvent(code: UInt16, params: [UInt32]) {
        eventCounts[code, default: 0] += 1
        lastEventAt = Date()
        switch code {
        case 0xC201:   // Sony ObjectAdded: neues Bild im RAM (Handle in Param 1)
            appendLog(String(format: "Event ObjectAdded 0x%08X", params.first ?? 0))
            if !eventsWorking { eventsWorking = true; appendLog("Camera events arrive, external shutter now reacts instantly") }
            sony?.objectAdded.fire()
            if !capturing { pollExternalCapture() }
        case 0xC203:   // PropertyChanged: kommt bei jeder Einstellungsaenderung und beim Fokussieren, nur zaehlen
            break
        default:
            if eventCounts[code] == 1 { appendLog(String(format: "PTP-Event 0x%04X %@", code, params.map { String(format: "0x%X", $0) }.joined(separator: " "))) }
        }
    }

    // MARK: Fremdausloesung (Ausloeser an der Kamera, Fernausloeser)

    private var pickupTask: Task<Void, Never>?
    /// Alle 2 s aus tick(): meldet die Kamera ein Bild im RAM, ohne dass die App ausgeloest hat, wird es genauso
    /// wie ein App-Foto uebernommen und in der Rueckschau gezeigt.
    private func pollExternalCapture() {
        guard settingsRef?.pickupExternal ?? true, let cam = sony, state == .connected,
              !capturing, !settingsBusy, pickupTask == nil, recoverTask == nil else { return }
        pickupTask = Task { [weak self] in
            defer { Task { @MainActor in self?.pickupTask = nil } }
            guard (try? await cam.hasPendingObject()) == true, let self else { return }
            guard !self.capturing else { return }
            self.capturing = true
            self.noteInteraction()
            self.dismissResult()
            let wasLive = self.liveTask != nil
            self.stopLiveView()
            self.appendLog("Picture taken on the camera, picking it up")
            do {
                let objects = try await cam.fetchObjects { [weak self] msg in Task { @MainActor in self?.appendLog(msg) } }
                if let (img, url) = try await self.store(objects) {
                    self.showResult([img], urls: [url])
                    self.status = String(localized: "Photo picked up from the camera")
                }
            } catch {
                self.appendLog("EXTERNAL SHUTTER ERROR: \(error.localizedDescription)")
            }
            self.capturing = false
            if wasLive { self.startLiveView() }
        }
    }

    func showResult(_ imgs: [UIImage], urls: [URL] = []) {
        resultPhotos = imgs
        resultURLs = urls
        resultHistogram = nil
        if wantHistogram, let first = imgs.first {
            Task.detached(priority: .userInitiated) { [weak self] in
                let h = Histogram.compute(first)
                await MainActor.run { self?.resultHistogram = h }
            }
        }
        resultPhoto = imgs.first
        resultShownAt = Date()
        resultTask?.cancel()
        resultTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.resultSeconds ?? 10) * 1_000_000_000))
            if !Task.isCancelled { await MainActor.run { self?.dismissResult() } }
        }
    }

    /// Bild fuer die Anzeige auf 2000 px Kantenlaenge verkleinern (Original 33 MP waere ~130 MB im Speicher).
    /// Ueber ImageIO, damit auch Sony-RAW (ARW) dekodiert wird; nutzt eingebettete Vorschauen.
    nonisolated static func previewImage(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2000,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return UIImage(cgImage: cg) }
            // RAW nicht dekodierbar: eingebettete JPEG-Vorschau aus dem ARW (TIFF) holen
            if let jpg = embeddedJPEG(in: data), let img = UIImage(data: jpg) { return img }
            return UIImage(data: data)
        }.value
    }

    /// Sony ARW ist TIFF: IFD0 traegt JPEGInterchangeFormat (0x0201) und -Length (0x0202) fuer die grosse Vorschau.
    /// Fallback: erstes JPEG (FF D8 FF) in der Datei.
    nonisolated static func embeddedJPEG(in d: Data) -> Data? {
        func u16(_ o: Int, _ le: Bool) -> Int { guard o + 2 <= d.count else { return 0 }; return le ? Int(d.readLE(UInt16.self, at: o)) : Int(d[d.startIndex + o]) << 8 | Int(d[d.startIndex + o + 1]) }
        func u32(_ o: Int, _ le: Bool) -> Int { guard o + 4 <= d.count else { return 0 }; return le ? Int(d.readLE(UInt32.self, at: o)) : (u16(o, false) << 16) | u16(o + 2, false) }
        if d.count > 16, (d[d.startIndex] == 0x49 && d[d.startIndex + 1] == 0x49) || (d[d.startIndex] == 0x4D && d[d.startIndex + 1] == 0x4D) {
            let le = d[d.startIndex] == 0x49
            var ifd = u32(4, le)
            var guardCount = 0
            while ifd > 0, ifd + 2 <= d.count, guardCount < 4 {
                guardCount += 1
                let n = u16(ifd, le)
                var off = 0, len = 0
                for i in 0..<n {
                    let e = ifd + 2 + i * 12
                    guard e + 12 <= d.count else { break }
                    let tag = u16(e, le)
                    if tag == 0x0201 { off = u32(e + 8, le) }
                    if tag == 0x0202 { len = u32(e + 8, le) }
                }
                if off > 0, len > 1000, off + len <= d.count { return d.subdata(in: (d.startIndex + off)..<(d.startIndex + off + len)) }
                ifd = u32(ifd + 2 + n * 12, le)
            }
        }
        // Fallback: erstes JPEG in den Daten
        let bytes = [UInt8](d)
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0xFF, bytes[i + 1] == 0xD8, bytes[i + 2] == 0xFF { return Data(bytes[i...]) }
            i += 1
        }
        return nil
    }

    /// Technischen Fehler in einen Satz fuer Gaeste uebersetzen.
    static func friendly(_ error: Error) -> String {
        let t = error.localizedDescription
        if t.contains("focus") || t.contains("no image") { return String(localized: "The camera didn’t take a picture. Maybe no focus? Please try again.") }
        if t.contains("Timeout") || t.contains("timeout") { return String(localized: "The camera took too long. Please try again.") }
        if t.contains("PTP error") { return String(localized: "The camera rejected the command. Please try again.") }
        return String(localized: "That didn’t work. Please try again.")
    }

    func dismissResult() {
        resultTask?.cancel()
        resultPhoto = nil
        resultPhotos = []
        resultURLs = []
        resultShownAt = nil
    }

    /// Loescht ein Bild der Rueckschau aus der App-Galerie. Die Apple-Mediathek bleibt unveraendert.
    func deleteResult(at index: Int) {
        guard resultPhotos.indices.contains(index) else { return }
        if resultURLs.indices.contains(index) {
            let url = resultURLs[index]
            try? FileManager.default.removeItem(at: url)
            ThumbnailStore.remove(url)
            sessionPhotos.removeAll { $0 == url }
            resultURLs.remove(at: index)
            appendLog("Photo deleted from app gallery: \(url.lastPathComponent)")
        }
        resultPhotos.remove(at: index)
        resultPhoto = resultPhotos.first
        lastPhoto = resultPhotos.last ?? lastPhoto
        if resultPhotos.isEmpty { dismissResult() } else { resultShownAt = Date(); resultTask?.cancel()
            resultTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.resultSeconds ?? 10) * 1_000_000_000))
                if !Task.isCancelled { await MainActor.run { self?.dismissResult() } }
            }
        }
    }

    static var photosRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Fotos", isDirectory: true)
    }
    static var photosDir: URL { photosRoot.appendingPathComponent(currentEvent, isDirectory: true) }

    nonisolated static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }

    @discardableResult
    static func saveToDocuments(_ jpeg: Data, stamp: String = stamp()) throws -> URL {
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let url = photosDir.appendingPathComponent("openbooth-\(stamp).jpg")
        try jpeg.write(to: url)
        return url
    }

    static var rawDir: URL { photosDir.appendingPathComponent("raw", isDirectory: true) }

    @discardableResult
    static func saveRAW(_ data: Data, stamp: String) throws -> URL {
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let url = rawDir.appendingPathComponent("openbooth-\(stamp).ARW")
        try data.write(to: url)
        return url
    }

    static func loadSessionPhotos() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: photosDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// In die Mediathek: JPEG und RAW als getrennte Eintraege. (Ein gemeinsamer Eintrag mit dem ARW als
    /// alternatePhoto wird von Photos mit Fehler 3300 abgelehnt, am Geraet geprueft.)
    static func saveToPhotos(_ jpeg: Data, raw: Data?, log: ((String) -> Void)? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else { log?("Photo library: no access (\(st.rawValue))"); return }
            let base = stamp()
            PHPhotoLibrary.shared().performChanges({
                let r1 = PHAssetCreationRequest.forAsset()
                let o1 = PHAssetResourceCreationOptions(); o1.originalFilename = "openbooth-\(base).jpg"
                r1.addResource(with: .photo, data: jpeg, options: o1)
                if let raw {
                    let r2 = PHAssetCreationRequest.forAsset()
                    let o2 = PHAssetResourceCreationOptions(); o2.originalFilename = "openbooth-\(base).ARW"
                    o2.uniformTypeIdentifier = "com.sony.arw-raw-image"
                    r2.addResource(with: .photo, data: raw, options: o2)
                }
            }) { ok, err in
                log?(ok ? "Photo library: saved\(raw != nil ? " (JPEG + RAW)" : "")" : "Photo library: ERROR \(err?.localizedDescription ?? "?")")
            }
        }
    }

    static func saveRAWOnlyToPhotos(_ raw: Data, log: ((String) -> Void)? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else { log?("Photo library: no access"); return }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = "openbooth-\(stamp()).ARW"
                o.uniformTypeIdentifier = "com.sony.arw-raw-image"
                req.addResource(with: .photo, data: raw, options: o)
            }) { ok, err in log?(ok ? "Photo library: RAW saved" : "Photo library: RAW ERROR \(err?.localizedDescription ?? "?")") }
        }
    }

}

// MARK: - ICDeviceBrowserDelegate

extension CameraManager: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard let cam = device as? ICCameraDevice else { return }
            appendLog("Camera found: \(cam.name ?? "?")  model: \(cam.productKind ?? "?")  transport: \(cam.transportType ?? "?")")
            stopIPadCamera(reason: "USB camera found")
            if !devices.contains(where: { $0 === cam }) { devices.append(cam) }
            state = .deviceFound
            status = String(localized: "Camera found")
            banner = Banner(kind: .working, text: String(localized: "Camera found, connecting…"))
            if autoConnect && self.device == nil {
                // kurz warten, bis die Kamera nach dem Anstecken bereit ist
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if self.device == nil, devices.contains(where: { $0 === cam }) { openSession(cam) }
            }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            appendLog("Camera removed: \(device.name ?? "?")")
            devices.removeAll { $0 === device }
            if self.device === device {
                stopLiveView()
                recoverTask?.cancel(); recoverTask = nil
                self.device = nil
                sony = nil
                liveFrame = nil
                state = .browsing
                status = String(localized: "Camera disconnected")
                scheduleFallback()
                banner = Banner(kind: .warning, text: String(localized: "Camera disconnected"), detail: String(localized: "It continues automatically once reconnected"))
            }
        }
    }
}

// MARK: - ICCameraDeviceDelegate (Pflichtmethoden, groesstenteils ungenutzt)

extension CameraManager: ICCameraDeviceDelegate {
    nonisolated func didRemove(_ device: ICDevice) {}
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Task { @MainActor in appendLog("Session closed\(error.map { ": \($0.localizedDescription)" } ?? "")") }
    }
    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {
        Task { @MainActor in appendLog("Device ready") }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    /// PTP-Event-Container: u32 Laenge, u16 Typ (4), u16 Code, u32 Transaktion, dann u32-Parameter.
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        guard eventData.count >= 12 else { return }
        let code = eventData.readLE(UInt16.self, at: 6)
        var params: [UInt32] = []
        var off = 12
        while off + 4 <= eventData.count { params.append(eventData.readLE(UInt32.self, at: off)); off += 4 }
        Task { @MainActor in self.handleEvent(code: code, params: params) }
    }
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
}
