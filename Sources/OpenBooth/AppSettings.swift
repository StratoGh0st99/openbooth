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
    @Published var autoReports: Bool { didSet { d.set(autoReports, forKey: "autoReports") } }
    @Published var webEnabled: Bool { didSet { d.set(webEnabled, forKey: "webEnabled") } }
    @Published var ipadFallback: Bool { didSet { d.set(ipadFallback, forKey: "ipadFallback") } }
    @Published var ipadFrontCamera: Bool { didSet { d.set(ipadFrontCamera, forKey: "ipadFrontCamera") } }
    @Published var restoreCameraSettings: Bool { didSet { d.set(restoreCameraSettings, forKey: "restoreCameraSettings") } }
    /// Zuletzt in der App gesetzte Kamerawerte je Modell: [Modell: [Code(hex): Wert]]
    @Published var rememberedCamera: [String: [String: Int]] { didSet { d.set(rememberedCamera, forKey: "rememberedCamera") } }
    @Published var autoConnect: Bool { didSet { d.set(autoConnect, forKey: "autoConnect") } }
    @Published var countdownSeconds: Int { didSet { d.set(countdownSeconds, forKey: "countdownSeconds") } }
    @Published var resultSeconds: Int { didSet { d.set(resultSeconds, forKey: "resultSeconds") } }
    @Published var idleSeconds: Int { didSet { d.set(idleSeconds, forKey: "idleSeconds") } }
    @Published var slideshowInterval: Int { didSet { d.set(slideshowInterval, forKey: "slideshowInterval") } }
    @Published var mirrorLiveView: Bool { didSet { d.set(mirrorLiveView, forKey: "mirrorLiveView") } }
    @Published var showHistogram: Bool { didSet { d.set(showHistogram, forKey: "showHistogram") } }
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
    @Published var soundsEnabled: Bool { didSet { d.set(soundsEnabled, forKey: "soundsEnabled") } }
    @Published var soundWelcome: Bool { didSet { d.set(soundWelcome, forKey: "soundWelcome") } }
    @Published var soundCountdown: Bool { didSet { d.set(soundCountdown, forKey: "soundCountdown") } }
    @Published var maxBrightness: Bool { didSet { d.set(maxBrightness, forKey: "maxBrightness") } }
    @Published var motionWake: Bool { didSet { d.set(motionWake, forKey: "motionWake") } }
    @Published var motionThreshold: Int { didSet { d.set(motionThreshold, forKey: "motionThreshold") } }

    static let defaultPhrases = String(localized: "Cheese!|Smile!|Cheesecake!|Spaghetti!|Sunshine!|Show your teeth!|Everyone together!|And… smile!|Say cheeeese!|Pineapple!|Whisky!|Shine!|A smile please!|Now!|Gummy bears!|Big cheese!").components(separatedBy: "|")

    init() {
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
        immichUploadRAW = d.object(forKey: "immichUploadRAW") as? Bool ?? false
        webdavEnabled = d.object(forKey: "webdavEnabled") as? Bool ?? false
        webdavURL = d.string(forKey: "webdavURL") ?? ""
        webdavUser = d.string(forKey: "webdavUser") ?? ""
        webdavUploadRAW = d.object(forKey: "webdavUploadRAW") as? Bool ?? false
        soundsEnabled = d.object(forKey: "soundsEnabled") as? Bool ?? true
        soundWelcome = d.object(forKey: "soundWelcome") as? Bool ?? true
        soundCountdown = d.object(forKey: "soundCountdown") as? Bool ?? true
        maxBrightness = d.object(forKey: "maxBrightness") as? Bool ?? false
        motionWake = d.object(forKey: "motionWake") as? Bool ?? true
        // Standard 6 (Dauerlauf 2026-09-06: Ruhepegel max 2,9, Treffer ab 8,8); alter Standard 8 wird einmalig migriert
        var mt = d.object(forKey: "motionThreshold") as? Int ?? 6
        if mt == 8, !d.bool(forKey: "motionThresholdV2") { mt = 6 }
        d.set(true, forKey: "motionThresholdV2")
        motionThreshold = mt
    }
}
