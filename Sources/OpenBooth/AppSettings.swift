//
//  AppSettings.swift
//  OpenBooth
//
//  App-Einstellungen, in UserDefaults gespeichert. Kamera-Einstellungen liegen in der Kamera selbst.
//

import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var eventName: String { didSet { d.set(eventName, forKey: "eventName") } }
    @Published var events: [String] { didSet { d.set(events, forKey: "events") } }
    @Published var qrEnabled: Bool { didSet { d.set(qrEnabled, forKey: "qrEnabled") } }
    @Published var pin: String { didSet { d.set(pin, forKey: "pin") } }
    @Published var debugMode: Bool { didSet { d.set(debugMode, forKey: "debugMode") } }
    @Published var autoConnect: Bool { didSet { d.set(autoConnect, forKey: "autoConnect") } }
    @Published var countdownSeconds: Int { didSet { d.set(countdownSeconds, forKey: "countdownSeconds") } }
    @Published var resultSeconds: Int { didSet { d.set(resultSeconds, forKey: "resultSeconds") } }
    @Published var idleSeconds: Int { didSet { d.set(idleSeconds, forKey: "idleSeconds") } }
    @Published var slideshowInterval: Int { didSet { d.set(slideshowInterval, forKey: "slideshowInterval") } }
    @Published var mirrorLiveView: Bool { didSet { d.set(mirrorLiveView, forKey: "mirrorLiveView") } }
    @Published var welcomeTitle: String { didSet { d.set(welcomeTitle, forKey: "welcomeTitle") } }
    @Published var welcomeText: String { didSet { d.set(welcomeText, forKey: "welcomeText") } }
    @Published var guestGallery: Bool { didSet { d.set(guestGallery, forKey: "guestGallery") } }
    @Published var gallerySeconds: Int { didSet { d.set(gallerySeconds, forKey: "gallerySeconds") } }
    @Published var shotsPerCapture: Int { didSet { d.set(shotsPerCapture, forKey: "shotsPerCapture") } }
    @Published var shotInterval: Int { didSet { d.set(shotInterval, forKey: "shotInterval") } }
    @Published var phrases: [String] { didSet { d.set(phrases, forKey: "phrases") } }
    @Published var pickupExternal: Bool { didSet { d.set(pickupExternal, forKey: "pickupExternal") } }
    @Published var saveToPhotos: Bool { didSet { d.set(saveToPhotos, forKey: "saveToPhotos") } }
    @Published var immichEnabled: Bool { didSet { d.set(immichEnabled, forKey: "immichEnabled") } }
    @Published var immichURL: String { didSet { d.set(immichURL, forKey: "immichURL") } }
    @Published var immichUploadRAW: Bool { didSet { d.set(immichUploadRAW, forKey: "immichUploadRAW") } }
    @Published var webdavEnabled: Bool { didSet { d.set(webdavEnabled, forKey: "webdavEnabled") } }
    @Published var webdavURL: String { didSet { d.set(webdavURL, forKey: "webdavURL") } }
    @Published var webdavUser: String { didSet { d.set(webdavUser, forKey: "webdavUser") } }
    @Published var webdavUploadRAW: Bool { didSet { d.set(webdavUploadRAW, forKey: "webdavUploadRAW") } }
    /// Rahmen fuer alle Layouts und Quellen je Ziel: "original", "single", "grid4" oder "strip4"
    @Published var frameStyle: String { didSet { d.set(frameStyle, forKey: "frameStyle") } }
    @Published var sourceReview: String { didSet { d.set(sourceReview, forKey: "sourceReview") } }
    @Published var sourceImmich: String { didSet { d.set(sourceImmich, forKey: "sourceImmich") } }
    @Published var sourceWebDAV: String { didSet { d.set(sourceWebDAV, forKey: "sourceWebDAV") } }
    @Published var immichAlsoOriginal: Bool { didSet { d.set(immichAlsoOriginal, forKey: "immichAlsoOriginal") } }
    @Published var webdavAlsoOriginal: Bool { didSet { d.set(webdavAlsoOriginal, forKey: "webdavAlsoOriginal") } }
    @Published var brandingText: String { didSet { d.set(brandingText, forKey: "brandingText") } }
    @Published var soundsEnabled: Bool { didSet { d.set(soundsEnabled, forKey: "soundsEnabled") } }
    @Published var soundWelcome: Bool { didSet { d.set(soundWelcome, forKey: "soundWelcome") } }
    @Published var soundCountdown: Bool { didSet { d.set(soundCountdown, forKey: "soundCountdown") } }
    @Published var maxBrightness: Bool { didSet { d.set(maxBrightness, forKey: "maxBrightness") } }
    @Published var motionWake: Bool { didSet { d.set(motionWake, forKey: "motionWake") } }
    @Published var motionThreshold: Int { didSet { d.set(motionThreshold, forKey: "motionThreshold") } }

    static let defaultPhrases = ["Cheese!", "Bitte lächeln!", "Käsekuchen!", "Spaghetti!", "Sonnenschein!", "Zähne zeigen!",
                                 "Alle zusammen!", "Und… lächeln!", "Sag Cheeeese!", "Ananas!", "Whisky!", "Strahlen!",
                                 "Ein Lächeln bitte!", "Jetzt!", "Gummibärchen!", "Dreikäsehoch!"]

    init() {
        let name = d.string(forKey: "eventName") ?? d.string(forKey: "immichAlbum") ?? "Fotobox"
        var ev = d.stringArray(forKey: "events") ?? []
        if !ev.contains(name) { ev.append(name) }
        eventName = name
        events = ev
        qrEnabled = d.object(forKey: "qrEnabled") as? Bool ?? true
        pin = d.string(forKey: "pin") ?? "0000"
        debugMode = d.object(forKey: "debugMode") as? Bool ?? false
        autoConnect = d.object(forKey: "autoConnect") as? Bool ?? true
        countdownSeconds = d.object(forKey: "countdownSeconds") as? Int ?? 3
        resultSeconds = d.object(forKey: "resultSeconds") as? Int ?? 10
        idleSeconds = d.object(forKey: "idleSeconds") as? Int ?? 120
        slideshowInterval = d.object(forKey: "slideshowInterval") as? Int ?? 7
        mirrorLiveView = d.object(forKey: "mirrorLiveView") as? Bool ?? true
        welcomeTitle = d.string(forKey: "welcomeTitle") ?? "📸 Fotobox"
        welcomeText = d.string(forKey: "welcomeText") ?? "Stellt euch vor die Kamera\nund drückt auf den Knopf!"
        guestGallery = d.object(forKey: "guestGallery") as? Bool ?? true
        gallerySeconds = d.object(forKey: "gallerySeconds") as? Int ?? 30
        shotsPerCapture = d.object(forKey: "shotsPerCapture") as? Int ?? 1
        shotInterval = d.object(forKey: "shotInterval") as? Int ?? 3
        phrases = d.stringArray(forKey: "phrases") ?? Self.defaultPhrases
        pickupExternal = d.object(forKey: "pickupExternal") as? Bool ?? true
        saveToPhotos = d.object(forKey: "saveToPhotos") as? Bool ?? true
        immichEnabled = d.object(forKey: "immichEnabled") as? Bool ?? false
        immichURL = d.string(forKey: "immichURL") ?? ""
        immichUploadRAW = d.object(forKey: "immichUploadRAW") as? Bool ?? false
        webdavEnabled = d.object(forKey: "webdavEnabled") as? Bool ?? false
        webdavURL = d.string(forKey: "webdavURL") ?? ""
        webdavUser = d.string(forKey: "webdavUser") ?? ""
        webdavUploadRAW = d.object(forKey: "webdavUploadRAW") as? Bool ?? false
        frameStyle = d.string(forKey: "frameStyle") ?? FrameStyle.wedding.rawValue
        // Quellen: nur noch feste Kennungen; alles andere (alte UUIDs) faellt auf Original zurueck
        let ud = UserDefaults.standard
        let src: (String) -> String = { key in
            let v = ud.string(forKey: key) ?? FixedLayout.originalID
            return FixedLayout.from(v) != nil ? v : FixedLayout.originalID
        }
        sourceReview = src("sourceReview"); sourceImmich = src("sourceImmich"); sourceWebDAV = src("sourceWebDAV")
        immichAlsoOriginal = d.object(forKey: "immichAlsoOriginal") as? Bool ?? false
        webdavAlsoOriginal = d.object(forKey: "webdavAlsoOriginal") as? Bool ?? false
        brandingText = d.string(forKey: "brandingText") ?? ""
        soundsEnabled = d.object(forKey: "soundsEnabled") as? Bool ?? true
        soundWelcome = d.object(forKey: "soundWelcome") as? Bool ?? true
        soundCountdown = d.object(forKey: "soundCountdown") as? Bool ?? true
        maxBrightness = d.object(forKey: "maxBrightness") as? Bool ?? false
        motionWake = d.object(forKey: "motionWake") as? Bool ?? true
        motionThreshold = d.object(forKey: "motionThreshold") as? Int ?? 8
    }

    // MARK: Layout-Hilfen

    func layout(for source: String) -> FixedLayout? { FixedLayout.from(source) }
    /// Layout der Rueckschau bestimmt die Serienlaenge, wenn es mehrere Bilder hat.
    var seriesLayout: FixedLayout? { layout(for: sourceReview).flatMap { $0.slots > 1 ? $0 : nil } }
    var effectiveShots: Int { seriesLayout?.slots ?? max(1, shotsPerCapture) }
    var frame: FrameStyle { FrameStyle(rawValue: frameStyle) ?? .wedding }
}
