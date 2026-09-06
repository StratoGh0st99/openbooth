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
    @Published var status = "Kamera anschließen"
    @Published var authorization = "unbekannt"
    @Published var settings: [CameraSetting] = []
    @Published var settingsBusy = false
    var autoConnect: Bool { settingsRef?.autoConnect ?? true }
    weak var settingsRef: AppSettings? { didSet { syncUploaders() } }
    /// Nach Aenderung von Eventname oder Zielen: Fotoordner wechseln und alle Upload-Ziele neu konfigurieren.
    func syncUploaders() {
        if let s = settingsRef { switchEvent(to: Self.safeName(s.eventName)) }
        syncImmich(); syncWebDAV()
    }

    /// Fotos liegen je Veranstaltung unter Documents/Fotos/<Name>/ (RAW in raw/ darunter).
    private static var currentEvent = "Fotobox"
    private func switchEvent(to name: String) {
        Self.migrateFlatPhotos(into: name)
        guard name != Self.currentEvent || sessionPhotos.isEmpty else { return }
        Self.currentEvent = name
        dismissResult()
        sessionPhotos = Self.loadSessionPhotos()
        lastPhoto = nil
        appendLog("Veranstaltung „\(name)“: \(sessionPhotos.count) Fotos")
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
        return t.isEmpty ? "Fotobox" : t
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
                do { try await self?.immich.ensureShareLink() } catch { self?.appendLog("Immich: Freigabelink: \(error.localizedDescription)") }
            }
        }
    }
    @Published var idle = false {   // Leerlauf: Collage anzeigen
        didSet {
            guard idle != oldValue else { return }
            updateBrightness()
            if !idle, settingsRef?.soundsEnabled ?? true, settingsRef?.soundWelcome ?? true { Sounds.shared.play("welcome") }
        }
    }
    @Published var motionLevel: Double = 0    // letzte Bildaenderung im Leerlauf (Debug)
    private var motion = MotionDetector()

    /// Rueckmeldung fuer Gaeste, klar und ohne Technik.
    struct Banner: Equatable {
        enum Kind { case info, working, warning, error }
        let kind: Kind
        let text: String
        var detail: String? = nil
    }
    @Published var banner: Banner? = Banner(kind: .info, text: "Kamera anschließen")
    @Published var captureError: String?      // Overlay mit "Nochmal versuchen"
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
        if tickCount % 3 == 0 { Self.logFile.snapshot() }
        if tickCount % 15 == 0, liveRunning { appendLog("Liveview: \(frameCount / 30) Bilder/s"); frameCount = 0 }
        let idleFor = Date().timeIntervalSince(lastInteraction)
        let limit = TimeInterval(settingsRef?.idleSeconds ?? 120)
        let shouldIdle = idleFor > limit && !capturing && resultPhoto == nil && countdown == nil && !sessionPhotos.isEmpty
        if shouldIdle != idle { idle = shouldIdle }

        // Liveview-Waechter: laeuft, aber seit 8 s kein Bild -> neu starten
        if state == .connected, liveRunning, !capturing, Date().timeIntervalSince(lastFrame) > 8 {
            appendLog("Liveview liefert nichts mehr, Neustart")
            stopLiveView()
            startLiveView()
        }
        // Verbunden, aber Liveview aus (z. B. nach Fehlern) -> wieder an
        if state == .connected, !liveRunning, !capturing, !settingsBusy, autoConnect, sony != nil {
            startLiveView()
        }
        pollExternalCapture()
    }

    /// Im Leerlauf: Bewegung vor der Kamera beendet die Collage.
    private func checkMotion(_ img: UIImage) {
        guard idle, settingsRef?.motionWake ?? true else { motion.reset(); motionLevel = 0; return }
        let hit = motion.feed(img, threshold: Double(settingsRef?.motionThreshold ?? 8))
        motionLevel = motion.level
        if hit {
            appendLog(String(format: "Bewegung erkannt (%.1f), Collage aus", motion.level))
            noteInteraction()
        }
    }

    /// Faehigkeitsbericht der Kamera nach Documents/openbooth-capabilities.log (holen mit tools/pull-caps.sh).
    private func writeCapabilities(_ cam: SonyCamera) {
        let report = cam.capabilitiesReport()
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("openbooth-capabilities.log")
        try? report.data(using: .utf8)?.write(to: url, options: .atomic)
        let di = cam.deviceInfo
        appendLog("Fähigkeiten: \(di.operations.count) Operationen, \(di.events.count) Events, \(di.properties.count)+\(cam.vendorProps.count) Properties, \(cam.controlCodes.count) Steuercodes → openbooth-capabilities.log")
        appendLog("Operationen: " + di.operations.sorted().map { PTPNames.hex($0) }.joined(separator: " "))
    }

    // MARK: Display-Helligkeit

    /// QR-Seite sichtbar (setzt ContentView), erzwingt volle Helligkeit.
    @Published var qrShown = false { didSet { updateBrightness() } }
    private var savedBrightness: CGFloat?   // Wert vor dem Hochdrehen, wird bei Collage/Beenden zurueckgesetzt

    /// Volle Helligkeit bei QR-Seite oder Option "dauerhaft", nicht waehrend der Leerlauf-Collage.
    func updateBrightness() {
        let wantFull = qrShown || ((settingsRef?.maxBrightness ?? false) && !idle)
        let screen = UIScreen.main
        if wantFull {
            if savedBrightness == nil { savedBrightness = screen.brightness }
            if screen.brightness < 0.999 { screen.brightness = 1.0 }
        } else if let saved = savedBrightness {
            screen.brightness = saved
            savedBrightness = nil
        }
    }

    /// Beim Verlassen der App die Helligkeit des Nutzers wiederherstellen.
    func restoreBrightness() {
        if let saved = savedBrightness { UIScreen.main.brightness = saved; savedBrightness = nil }
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
        init() { append("===== App gestartet \(Date()) =====") }
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
        appendLog("Autorisierung anfragen …")
        browser.requestContentsAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.authorization = Self.describe(status)
                self.appendLog("Autorisierung: \(self.authorization)")
                self.browser.start()
                self.state = .browsing
                self.status = "Suche Kamera …"
                if self.authorization == "verweigert" {
                    self.banner = Banner(kind: .error, text: "Kein Zugriff auf die Kamera", detail: "Einstellungen › OpenBooth › Kamera erlauben")
                } else if self.devices.isEmpty {
                    self.banner = Banner(kind: .info, text: "Kamera anschließen", detail: "Sony im Modus „PC-Fernbedienung“ per USB-C")
                }
            }
        }
    }

    static func describe(_ s: ICAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "erteilt"
        case .denied: return "verweigert"
        case .restricted: return "eingeschränkt"
        case .notDetermined: return "nicht entschieden"
        default: return "\(s.rawValue)"
        }
    }

    // MARK: Session

    func openSession(_ dev: ICCameraDevice) {
        device = dev
        dev.delegate = self
        appendLog("Session öffnen: \(dev.name ?? "?")")
        status = "Verbinde …"
        dev.requestOpenSession { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error = error {
                    self.appendLog("Session-Fehler: \(error.localizedDescription)")
                    self.state = .error(error.localizedDescription)
                    self.status = "Session fehlgeschlagen"
                    self.lastError = error.localizedDescription
                    self.scheduleRecover(reason: "Session")
                    return
                }
                self.appendLog("Session offen")
                self.state = .sessionOpen
                self.status = "Session offen"
                self.banner = Banner(kind: .working, text: "Kamera wird verbunden …")
                let cam = SonyCamera(device: dev)
                self.sony = cam
                await cam.transport.setLogHandler { [weak self] line in
                    Task { @MainActor in self?.appendLog(line) }
                }
                if self.autoConnect {
                    if await self.probeAsync(), await self.connectAsync() {
                        self.startLiveView()
                    } else {
                        self.scheduleRecover(reason: "Verbindung")
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
                appendLog("Operationen: \(ops)")
                state = .probed
                status = "PTP-Durchreichen funktioniert"
                return true
            } catch {
                appendLog("PROBE FEHLER: \(error.localizedDescription)  [\((error as NSError).domain) \((error as NSError).code)]")
                state = .error(error.localizedDescription)
                status = "PTP-Durchreichen blockiert"
                lastError = error.localizedDescription
                return false
            }
    }

    func connect() { Task { _ = await connectAsync() } }

    @discardableResult
    func connectAsync() async -> Bool {
        guard let cam = sony else { return false }
            do {
                status = "Sony-Handshake …"
                try await cam.connect()
                appendLog("Handshake OK, Protokoll 0x\(String(cam.protocolVersion, radix: 16)), \(cam.vendorCodes.count) Vendor-Codes, \(cam.props.count) Properties")
                writeCapabilities(cam)
                if let iso = cam.currentValue(SonyProp.iso) { appendLog("ISO = \(iso)") }
                if let f = cam.currentValue(SonyProp.fNumber) { appendLog("Blende = f/\(Double(f) / 100)") }
                if let s = cam.currentValue(SonyProp.shutterSpeed) { appendLog("Verschluss = \(SonyFormat.label(code: SonyProp.shutterSpeed, value: s))") }
                appendLog("ObjectInMemory(0xD215) = \(cam.currentValue(SonyProp.objectInMemory).map(String.init) ?? "fehlt"), FocusFound(0xD213) = \(cam.currentValue(SonyProp.focusFound).map(String.init) ?? "fehlt")")
                state = .connected
                status = "Verbunden"
                settings = cam.settings()
                connectedSince = Date()
                recoverAttempts = 0
                lastError = nil
                banner = Banner(kind: .working, text: "Kamera bereit, Bild kommt …")
                return true
            } catch {
                appendLog("HANDSHAKE FEHLER: \(error.localizedDescription)")
                state = .error(error.localizedDescription)
                status = "Handshake fehlgeschlagen"
                lastError = error.localizedDescription
                return false
            }
    }

    // MARK: Einstellungen

    func reloadSettings() {
        guard let cam = sony else { return }
        Task {
            do { try await cam.refreshProps(); settings = cam.settings() }
            catch { appendLog("Einstellungen lesen: \(error.localizedDescription)") }
        }
    }

    func apply(_ code: UInt16, value: Int64) {
        guard let cam = sony, !settingsBusy else { return }
        settingsBusy = true
        let wasLive = liveTask != nil
        stopLiveView()
        Task {
            do {
                try await cam.setSetting(code, to: value) { [weak self] m in Task { @MainActor in self?.appendLog(m) } }
                appendLog("Einstellung 0x\(String(code, radix: 16)) = \(SonyFormat.label(code: code, value: value))")
            } catch {
                appendLog("EINSTELLUNG FEHLER: \(error.localizedDescription)")
                status = "Einstellung nicht übernommen"
            }
            settings = cam.settings()
            settingsBusy = false
            if wasLive { startLiveView() }
        }
    }

    // MARK: Liveview

    func startLiveView() {
        guard let cam = sony, liveTask == nil else { return }
        liveRunning = true
        lastFrame = Date()
        liveTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    if let jpeg = try await cam.liveViewFrame(), let img = UIImage(data: jpeg) {
                        await MainActor.run {
                            self?.liveFrame = img; self?.lastFrame = Date(); self?.frameCount += 1
                            if self?.banner != nil { self?.banner = nil }
                            self?.checkMotion(img)
                        }
                        failures = 0
                    } else {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                } catch {
                    failures += 1
                    await MainActor.run { self?.appendLog("Liveview: \(error.localizedDescription)") }
                    if failures > 20 {
                        await MainActor.run { self?.scheduleRecover(reason: "Liveview") }
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
        appendLog("Wiederherstellung #\(recoverAttempts) (\(reason))")
        if recoverAttempts > 5 {
            banner = Banner(kind: .error, text: "Kamera antwortet nicht", detail: "Kamera aus- und einschalten oder USB neu stecken")
            recoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)   // danach weiter versuchen, aber langsamer
                await MainActor.run { self?.recoverTask = nil; self?.recoverAttempts = 3; self?.scheduleRecover(reason: "erneut") }
            }
            return
        }
        banner = Banner(kind: .warning, text: "Verbindung zur Kamera wird erneuert …", detail: "Versuch \(recoverAttempts) von 5")
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
                    self.banner = Banner(kind: .warning, text: "Kamera getrennt", detail: "Bitte USB-Kabel prüfen")
                }
            }
        }
    }

    // MARK: Aufnahme

    /// Fotobox-Ablauf: Countdown, ein oder mehrere Bilder mit Pause, grosse Vorschau, speichern.
    func capture(withCountdown seconds: Int = 3) {
        guard let cam = sony, !capturing else { return }
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
                    let objects = try await cam.capture { [weak self] msg in
                        Task { @MainActor in self?.status = msg; self?.appendLog(msg) }
                    }
                    if let (img, url) = try await store(objects) { taken.append(img); takenURLs.append(url) }
                } catch {
                    appendLog("AUFNAHME FEHLER (Bild \(shot)/\(shots)): \(error.localizedDescription)")
                    status = "Aufnahme fehlgeschlagen"
                    lastError = error.localizedDescription
                    if taken.isEmpty {
                        captureError = Self.friendly(error)
                        capturePhrase = nil
                        break
                    }
                }
                capturePhrase = nil
            }
            shotNumber = 0
            if !taken.isEmpty {
                showResult(taken, urls: takenURLs)
                status = taken.count == 1 ? "Foto gespeichert" : "\(taken.count) Fotos gespeichert"
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
            appendLog("RAW gesichert: \(rawURL!.lastPathComponent) (\(raw.data.count / 1_000_000) MB)")
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
            appendLog(preview == nil ? "RAW-Vorschau: keine dekodierbare Vorschau in der ARW" : "RAW-Vorschau: \(Int(preview!.size.width))x\(Int(preview!.size.height))")
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
            self.appendLog("Bild von der Kamera ausgelöst, wird übernommen")
            do {
                let objects = try await cam.fetchObjects { [weak self] msg in Task { @MainActor in self?.appendLog(msg) } }
                if let (img, url) = try await self.store(objects) {
                    self.showResult([img], urls: [url])
                    self.status = "Foto von der Kamera übernommen"
                }
            } catch {
                self.appendLog("FREMDAUSLÖSUNG FEHLER: \(error.localizedDescription)")
            }
            self.capturing = false
            if wasLive { self.startLiveView() }
        }
    }

    func showResult(_ imgs: [UIImage], urls: [URL] = []) {
        resultPhotos = imgs
        resultURLs = urls
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
        if t.contains("Fokus") || t.contains("kein Bild gemeldet") { return "Die Kamera hat kein Bild gemacht. Vielleicht kein Fokus? Bitte noch einmal." }
        if t.contains("Zeitueberschreitung") || t.contains("Zeitüberschreitung") { return "Die Kamera hat zu lange gebraucht. Bitte noch einmal." }
        if t.contains("PTP-Fehler") { return "Die Kamera hat den Befehl nicht angenommen. Bitte noch einmal." }
        return "Das hat leider nicht geklappt. Bitte noch einmal."
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
            appendLog("Foto aus App-Galerie gelöscht: \(url.lastPathComponent)")
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
            guard st == .authorized || st == .limited else { log?("Mediathek: kein Zugriff (\(st.rawValue))"); return }
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
                log?(ok ? "Mediathek: gespeichert\(raw != nil ? " (JPEG + RAW)" : "")" : "Mediathek: FEHLER \(err?.localizedDescription ?? "?")")
            }
        }
    }

    static func saveRAWOnlyToPhotos(_ raw: Data, log: ((String) -> Void)? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else { log?("Mediathek: kein Zugriff"); return }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = "openbooth-\(stamp()).ARW"
                o.uniformTypeIdentifier = "com.sony.arw-raw-image"
                req.addResource(with: .photo, data: raw, options: o)
            }) { ok, err in log?(ok ? "Mediathek: RAW gespeichert" : "Mediathek: RAW FEHLER \(err?.localizedDescription ?? "?")") }
        }
    }

}

// MARK: - ICDeviceBrowserDelegate

extension CameraManager: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard let cam = device as? ICCameraDevice else { return }
            appendLog("Kamera gefunden: \(cam.name ?? "?")  Modell: \(cam.productKind ?? "?")  Transport: \(cam.transportType ?? "?")")
            if !devices.contains(where: { $0 === cam }) { devices.append(cam) }
            state = .deviceFound
            status = "Kamera gefunden"
            banner = Banner(kind: .working, text: "Kamera gefunden, wird verbunden …")
            if autoConnect && self.device == nil {
                // kurz warten, bis die Kamera nach dem Anstecken bereit ist
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if self.device == nil, devices.contains(where: { $0 === cam }) { openSession(cam) }
            }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            appendLog("Kamera entfernt: \(device.name ?? "?")")
            devices.removeAll { $0 === device }
            if self.device === device {
                stopLiveView()
                recoverTask?.cancel(); recoverTask = nil
                self.device = nil
                sony = nil
                liveFrame = nil
                state = .browsing
                status = "Kamera getrennt"
                banner = Banner(kind: .warning, text: "Kamera getrennt", detail: "Sobald sie wieder angeschlossen ist, geht es automatisch weiter")
            }
        }
    }
}

// MARK: - ICCameraDeviceDelegate (Pflichtmethoden, groesstenteils ungenutzt)

extension CameraManager: ICCameraDeviceDelegate {
    nonisolated func didRemove(_ device: ICDevice) {}
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Task { @MainActor in appendLog("Session geschlossen \(error.map { ": \($0.localizedDescription)" } ?? "")") }
    }
    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {
        Task { @MainActor in appendLog("Gerät bereit") }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        let code = eventData.count >= 8 ? eventData.readLE(UInt16.self, at: 6) : 0
        Task { @MainActor in appendLog(String(format: "PTP-Event 0x%04X (%d Byte)", code, eventData.count)) }
    }
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
}
