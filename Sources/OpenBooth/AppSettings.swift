//
//  AppSettings.swift
//  OpenBooth
//
//  App settings, stored in UserDefaults. Camera settings live in the camera itself.
//

import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var eventName: String = "" { didSet { d.set(eventName, forKey: "eventName") } }
    @Published var events: [String] = [] { didSet { d.set(events, forKey: "events") } }
    @Published var qrEnabled: Bool = true { didSet { d.set(qrEnabled, forKey: "qrEnabled") } }
    @Published var pin: String = "0000" { didSet { d.set(pin, forKey: "pin") } }
    @Published var debugMode: Bool = false { didSet { d.set(debugMode, forKey: "debugMode") } }
    @Published var autoReports: Bool = false { didSet { d.set(autoReports, forKey: "autoReports") } }
    @Published var webEnabled: Bool = false { didSet { d.set(webEnabled, forKey: "webEnabled") } }
    @Published var ipadFallback: Bool = true { didSet { d.set(ipadFallback, forKey: "ipadFallback") } }
    @Published var ipadFrontCamera: Bool = true { didSet { d.set(ipadFrontCamera, forKey: "ipadFrontCamera") } }
    @Published var ipadUltraWide: Bool = false { didSet { d.set(ipadUltraWide, forKey: "ipadUltraWide") } }
    @Published var restoreCameraSettings: Bool = true { didSet { d.set(restoreCameraSettings, forKey: "restoreCameraSettings") } }
    /// Camera values last set in the app, per model: [model: [code(hex): value]]
    @Published var rememberedCamera: [String: [String: Int]] = [:] { didSet { d.set(rememberedCamera, forKey: "rememberedCamera") } }
    @Published var autoConnect: Bool = true { didSet { d.set(autoConnect, forKey: "autoConnect") } }
    @Published var countdownSeconds: Int = 3 { didSet { d.set(countdownSeconds, forKey: "countdownSeconds") } }
    @Published var resultSeconds: Int = 10 { didSet { d.set(resultSeconds, forKey: "resultSeconds") } }
    @Published var idleSeconds: Int = 120 { didSet { d.set(idleSeconds, forKey: "idleSeconds") } }
    @Published var slideshowInterval: Int = 7 { didSet { d.set(slideshowInterval, forKey: "slideshowInterval") } }
    @Published var mirrorLiveView: Bool = true { didSet { d.set(mirrorLiveView, forKey: "mirrorLiveView") } }
    @Published var showHistogram: Bool = false { didSet { d.set(showHistogram, forKey: "showHistogram") } }
    @Published var welcomeTitle: String = String(localized: "📸 Photo Booth") { didSet { d.set(welcomeTitle, forKey: "welcomeTitle") } }
    @Published var welcomeText: String = String(localized: "Step in front of the camera\nand press the button!") { didSet { d.set(welcomeText, forKey: "welcomeText") } }
    @Published var guestGallery: Bool = true { didSet { d.set(guestGallery, forKey: "guestGallery") } }
    @Published var gallerySeconds: Int = 30 { didSet { d.set(gallerySeconds, forKey: "gallerySeconds") } }
    @Published var shotsPerCapture: Int = 1 { didSet { d.set(shotsPerCapture, forKey: "shotsPerCapture") } }
    @Published var shotInterval: Int = 3 { didSet { d.set(shotInterval, forKey: "shotInterval") } }
    @Published var phrases: [String] = AppSettings.defaultPhrases { didSet { d.set(phrases, forKey: "phrases") } }
    @Published var pickupExternal: Bool = true { didSet { d.set(pickupExternal, forKey: "pickupExternal") } }
    @Published var saveToPhotos: Bool = true { didSet { d.set(saveToPhotos, forKey: "saveToPhotos") } }
    @Published var immichEnabled: Bool = false { didSet { d.set(immichEnabled, forKey: "immichEnabled") } }
    @Published var immichURL: String = "" { didSet { d.set(immichURL, forKey: "immichURL") } }
    /// true = full-size original, false = web version (2000 px long edge)
    @Published var photosOriginal: Bool = true { didSet { d.set(photosOriginal, forKey: "photosOriginal") } }
    @Published var immichOriginal: Bool = true { didSet { d.set(immichOriginal, forKey: "immichOriginal") } }
    @Published var webdavOriginal: Bool = true { didSet { d.set(webdavOriginal, forKey: "webdavOriginal") } }
    @Published var webdavEnabled: Bool = false { didSet { d.set(webdavEnabled, forKey: "webdavEnabled") } }
    @Published var webdavURL: String = "" { didSet { d.set(webdavURL, forKey: "webdavURL") } }
    @Published var webdavUser: String = "" { didSet { d.set(webdavUser, forKey: "webdavUser") } }
    @Published var soundsEnabled: Bool = true { didSet { d.set(soundsEnabled, forKey: "soundsEnabled") } }
    @Published var soundWelcome: Bool = true { didSet { d.set(soundWelcome, forKey: "soundWelcome") } }
    @Published var soundCountdown: Bool = true { didSet { d.set(soundCountdown, forKey: "soundCountdown") } }
    @Published var maxBrightness: Bool = false { didSet { d.set(maxBrightness, forKey: "maxBrightness") } }
    @Published var motionWake: Bool = true { didSet { d.set(motionWake, forKey: "motionWake") } }
    @Published var motionThreshold: Int = 6 { didSet { d.set(motionThreshold, forKey: "motionThreshold") } }

    static let defaultPhrases = String(localized: "Cheese!|Smile!|Cheesecake!|Spaghetti!|Sunshine!|Show your teeth!|Everyone together!|And… smile!|Say cheeeese!|Pineapple!|Whisky!|Shine!|A smile please!|Now!|Gummy bears!|Big cheese!").components(separatedBy: "|")

    init() { reloadFromDefaults() }

    /// Does any target receive the original? Used for the admin warning.
    var anyTargetKeepsOriginal: Bool {
        (saveToPhotos && photosOriginal) || (immichEnabled && immichOriginal) || (webdavEnabled && webdavOriginal)
    }

    /// Read all values from UserDefaults (at start and after an import)
    func reloadFromDefaults() {
        let name = d.string(forKey: "eventName") ?? d.string(forKey: "immichAlbum") ?? String(localized: "Photo Booth")
        var ev = d.stringArray(forKey: "events") ?? []
        if !ev.contains(name) { ev.append(name) }
        eventName = name
        events = ev
        qrEnabled = d.object(forKey: "qrEnabled") as? Bool ?? true
        pin = d.string(forKey: "pin") ?? "0000"
        debugMode = d.object(forKey: "debugMode") as? Bool ?? false
        autoReports = d.object(forKey: "autoReports") as? Bool ?? false
        webEnabled = d.object(forKey: "webEnabled") as? Bool ?? false
        ipadFallback = d.object(forKey: "ipadFallback") as? Bool ?? true
        ipadFrontCamera = d.object(forKey: "ipadFrontCamera") as? Bool ?? true
        ipadUltraWide = d.object(forKey: "ipadUltraWide") as? Bool ?? false
        restoreCameraSettings = d.object(forKey: "restoreCameraSettings") as? Bool ?? true
        rememberedCamera = d.dictionary(forKey: "rememberedCamera") as? [String: [String: Int]] ?? [:]
        autoConnect = d.object(forKey: "autoConnect") as? Bool ?? true
        countdownSeconds = d.object(forKey: "countdownSeconds") as? Int ?? 3
        resultSeconds = d.object(forKey: "resultSeconds") as? Int ?? 10
        idleSeconds = d.object(forKey: "idleSeconds") as? Int ?? 120
        slideshowInterval = d.object(forKey: "slideshowInterval") as? Int ?? 7
        mirrorLiveView = d.object(forKey: "mirrorLiveView") as? Bool ?? true
        showHistogram = d.object(forKey: "showHistogram") as? Bool ?? false
        welcomeTitle = d.string(forKey: "welcomeTitle") ?? String(localized: "📸 Photo Booth")
        welcomeText = d.string(forKey: "welcomeText") ?? String(localized: "Step in front of the camera\nand press the button!")
        guestGallery = d.object(forKey: "guestGallery") as? Bool ?? true
        gallerySeconds = d.object(forKey: "gallerySeconds") as? Int ?? 30
        shotsPerCapture = d.object(forKey: "shotsPerCapture") as? Int ?? 1
        shotInterval = d.object(forKey: "shotInterval") as? Int ?? 3
        phrases = d.stringArray(forKey: "phrases") ?? Self.defaultPhrases
        pickupExternal = d.object(forKey: "pickupExternal") as? Bool ?? true
        saveToPhotos = d.object(forKey: "saveToPhotos") as? Bool ?? true
        immichEnabled = d.object(forKey: "immichEnabled") as? Bool ?? false
        immichURL = d.string(forKey: "immichURL") ?? ""
        photosOriginal = d.object(forKey: "photosOriginal") as? Bool ?? true
        immichOriginal = d.object(forKey: "immichOriginal") as? Bool ?? true
        webdavOriginal = d.object(forKey: "webdavOriginal") as? Bool ?? true
        webdavEnabled = d.object(forKey: "webdavEnabled") as? Bool ?? false
        webdavURL = d.string(forKey: "webdavURL") ?? ""
        webdavUser = d.string(forKey: "webdavUser") ?? ""
        soundsEnabled = d.object(forKey: "soundsEnabled") as? Bool ?? true
        soundWelcome = d.object(forKey: "soundWelcome") as? Bool ?? true
        soundCountdown = d.object(forKey: "soundCountdown") as? Bool ?? true
        maxBrightness = d.object(forKey: "maxBrightness") as? Bool ?? false
        motionWake = d.object(forKey: "motionWake") as? Bool ?? true
        // Default 6 (endurance run 2026-09-06: idle level max 2.9, hits from 8.8); old default 8 is migrated once
        var mt = d.object(forKey: "motionThreshold") as? Int ?? 6
        if mt == 8, !d.bool(forKey: "motionThresholdV2") { mt = 6 }
        d.set(true, forKey: "motionThresholdV2")
        motionThreshold = mt
    }

    /// Exportable keys (without PIN and without keychain contents)
    static let exportKeys: [String] = ["autoConnect", "autoReports", "countdownSeconds", "debugMode", "eventName", "events", "gallerySeconds", "guestGallery", "idleSeconds", "immichAlbum", "immichEnabled", "immichOriginal", "immichURL", "ipadFallback", "ipadFrontCamera", "ipadUltraWide", "maxBrightness", "mirrorLiveView", "motionThreshold", "motionWake", "photosOriginal", "phrases", "pickupExternal", "qrEnabled", "rememberedCamera", "restoreCameraSettings", "resultSeconds", "saveToPhotos", "shotInterval", "shotsPerCapture", "showHistogram", "slideshowInterval", "soundCountdown", "soundWelcome", "soundsEnabled", "webEnabled", "webdavEnabled", "webdavOriginal", "webdavURL", "webdavUser", "welcomeText", "welcomeTitle"]

    func exportJSON() -> Data? {
        var dict: [String: Any] = [:]
        for k in Self.exportKeys { if let v = d.object(forKey: k) { dict[k] = v } }
        dict["_openbooth"] = "settings"
        return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    /// Import: take only known keys, then reload. Returns the number of values taken over.
    func importJSON(_ data: Data) -> Int {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any], dict["_openbooth"] as? String == "settings" else { return 0 }
        var n = 0
        for k in Self.exportKeys { if let v = dict[k] { d.set(v, forKey: k); n += 1 } }
        reloadFromDefaults()
        return n
    }
}
