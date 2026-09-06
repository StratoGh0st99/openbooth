//
//  ContentView.swift
//  OpenBooth
//
//  Gaestemodus: Vollbild-Liveview, roter Knopf, Galerie, Leerlauf-Collage.
//  Zwei-Finger-Wischen von oben nach unten -> PIN -> Admin-Panel. Debug-Modus blendet die Seitenleiste dauerhaft ein.
//

import SwiftUI
import CoreImage.CIFilterBuiltins
import ImageCaptureCore

struct ContentView: View {
    @EnvironmentObject var cam: CameraManager
    @EnvironmentObject var settings: AppSettings
    @State private var showGallery = false
    @State private var showQR = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPinPad = false
    @State private var adminUnlocked = false
    /// QR-Code nur, wenn gewuenscht und der Freigabelink des Albums existiert.
    private var qrLink: String? { settings.qrEnabled ? cam.immich.shareURL : nil }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if adminUnlocked {
                    // Admin nimmt die Breite, die Gaestesicht laeuft verkleinert oben rechts weiter
                    AdminPanel(adminUnlocked: $adminUnlocked)
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemBackground))
                        .transition(.move(edge: .leading))
                    Divider()
                    // Vorschau-Spalte: 400 pt auf grossen iPads, auf dem iPad mini schmaler, damit der Admin Platz behaelt
                    let w: CGFloat = min(400, geo.size.width * 0.3)
                    let sc = w / max(1, geo.size.width)
                    VStack(spacing: 6) {
                        Text("Guest view (live)").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        stage
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(sc, anchor: .topLeading)
                            .frame(width: w, height: geo.size.height * sc, alignment: .topLeading)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2)))
                        Spacer()
                    }
                    .frame(width: w + 16)
                    .background(Color(.secondarySystemBackground))
                } else {
                    stage
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: adminUnlocked)
        .onAppear {
            adminUnlocked = settings.debugMode   // Debug-Modus: Admin beim Start offen, Wischgeste ohne PIN
            cam.settingsRef = settings
            cam.start()
            cam.updateBrightness()
        }
        .fullScreenCover(isPresented: $showGallery) { GalleryView(photos: cam.sessionPhotos, autoClose: settings.gallerySeconds, onActivity: { cam.noteInteraction() }) }
        // Leerlauf beginnt oder endet: Galerie und QR-Seite schliessen, die Buehne gehoert wieder der Fotobox
        .onChange(of: cam.idle) { _, _ in showGallery = false; showQR = false; cam.qrShown = false }
        .overlay {
            if showPinPad {
                PinPadView(expected: settings.pin) { ok in
                    showPinPad = false
                    if ok { adminUnlocked = true }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { cam.updateBrightness() } else { cam.restoreBrightness() }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    // MARK: Buehne

    var stage: some View {
        ZStack {
            Color.black

            // Liveview
            if let img = cam.liveFrame {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: settings.mirrorLiveView ? -1 : 1, y: 1)
            } else {
                Image(systemName: "camera.aperture").font(.system(size: 80)).foregroundStyle(.gray).offset(y: -140)
            }

            // Begruessung: ohne Liveview mittig gross, mit Liveview als Schriftzug oben ueber dem Bild
            if cam.banner == nil, cam.countdown == nil, cam.capturePhrase == nil {
                if cam.liveFrame == nil {
                    VStack(spacing: 12) {
                        Text(settings.welcomeTitle).font(.system(size: 64, weight: .bold))
                        Text(settings.welcomeText)
                            .multilineTextAlignment(.center).font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack {
                        VStack(spacing: 4) {
                            Text(settings.welcomeTitle).font(.system(size: 52, weight: .bold))
                            Text(settings.welcomeText.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 30, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                        }
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.9), radius: 8)
                        .padding(.horizontal, 32).padding(.vertical, 14)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
                        .padding(.top, 22)
                        Spacer()
                    }
                }
            }

            // Leerlauf-Collage ueber dem Liveview
            if cam.idle && !cam.sessionPhotos.isEmpty {
                CollageView(photos: cam.sessionPhotos, interval: settings.slideshowInterval, title: settings.welcomeTitle)
                    .transition(.opacity)
                    .onTapGesture { cam.noteInteraction() }
            }

            // Countdown
            if let n = cam.countdown {
                VStack(spacing: 0) {
                    Text("\(n)")
                        .font(.system(size: 260, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 20)
                        .transition(.scale.combined(with: .opacity))
                        .id(n)
                    if cam.shotTotal > 1 {
                        Text("Photo \(cam.shotNumber) of \(cam.shotTotal)")
                            .font(.title.bold()).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 10)
                    }
                }
            } else if let phrase = cam.capturePhrase {
                Text(phrase)
                    .font(.system(size: 110, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 20)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .transition(.scale.combined(with: .opacity))
            }

            // Histogramm zum Liveview (Admin-Option), unten links ueber der Leiste
            if settings.showHistogram, !cam.idle, cam.resultPhotos.isEmpty, cam.countdown == nil, let h = cam.liveHistogram {
                VStack { Spacer(); HStack { HistogramView(histogram: h).frame(width: 220, height: 90).padding(.leading, 20).padding(.bottom, 110); Spacer() } }
                    .allowsHitTesting(false)
            }

            // Bedienleiste unten
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if settings.guestGallery {
                        Button {
                            cam.noteInteraction()
                            showGallery = true
                        } label: {
                            Label("Gallery", systemImage: "photo.on.rectangle").frame(width: 160, height: 56)
                        }
                        .buttonStyle(.borderedProminent).tint(Color(white: 0.22))
                        .disabled(cam.sessionPhotos.isEmpty)
                        .padding()
                    } else {
                        Color.clear.frame(width: 160, height: 56).padding()
                    }
                    Spacer()
                    Button {
                        cam.noteInteraction()
                        cam.capture(withCountdown: settings.countdownSeconds)
                    } label: {
                        VStack {
                            Image(systemName: "camera.fill").font(.system(size: 40))
                            Text("Take a photo").font(.headline)
                        }
                        .frame(width: 240, height: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(cam.state != .connected || cam.capturing)
                    .padding()
                    Spacer()
                    if qrLink != nil {
                        Button {
                            cam.noteInteraction()
                            showQR = true; cam.qrShown = true
                        } label: {
                            Label("Photos to your phone", systemImage: "qrcode").frame(width: 160, height: 56)
                        }
                        .buttonStyle(.borderedProminent).tint(Color(white: 0.22))
                        .padding()
                    } else {
                        Color.clear.frame(width: 160, height: 56).padding()
                    }
                }
            }

            // QR-Code zum Immich-Album
            if showQR, let link = qrLink {
                ZStack {
                    Color.black.opacity(0.92)
                    VStack(spacing: 20) {
                        Text("All photos of the evening").font(.system(size: 40, weight: .bold))
                        Text("Scan the QR code with your phone camera").font(.title3).foregroundStyle(.secondary)
                        QRCodeView(text: link).frame(width: 360, height: 360)
                            .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                        Text(link).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        Button { showQR = false; cam.qrShown = false } label: { Label("Close", systemImage: "xmark").frame(width: 200, height: 56) }
                            .buttonStyle(.bordered)
                    }
                }
                .transition(.opacity)
                .onTapGesture { showQR = false; cam.qrShown = false }
            }

            // Grosse Vorschau nach der Aufnahme (ein Bild oder Serie)
            if !cam.resultPhotos.isEmpty {
                ZStack {
                    Color.black.opacity(0.92)
                    VStack(spacing: 16) {
                        // Restzeit-Balken
                        if let shownAt = cam.resultShownAt {
                            TimelineView(.animation(minimumInterval: 0.05)) { ctx in
                                let total = max(1, Double(settings.resultSeconds))
                                let frac = max(0, 1 - ctx.date.timeIntervalSince(shownAt) / total)
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.15))
                                        Capsule().fill(Color.red).frame(width: g.size.width * frac)
                                    }
                                }
                                .frame(height: 8)
                            }
                            .padding(.horizontal, 40)
                        }
                        if cam.resultPhotos.count == 1, let result = cam.resultPhotos.first {
                            Image(uiImage: result)
                                .resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(radius: 20)
                                .padding(.horizontal, 40)
                                .overlay(alignment: .bottomLeading) {
                                    if settings.showHistogram, let h = cam.resultHistogram {
                                        HistogramView(histogram: h).frame(width: 220, height: 90).padding(56)
                                    }
                                }
                        } else {
                            let cols = cam.resultPhotos.count <= 4 ? 2 : 3
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: cols), spacing: 14) {
                                ForEach(Array(cam.resultPhotos.enumerated()), id: \.offset) { i, img in
                                    Image(uiImage: img)
                                        .resizable().scaledToFit()
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .shadow(radius: 10)
                                        .overlay(alignment: .topTrailing) {
                                            Button { cam.deleteResult(at: i) } label: {
                                                Image(systemName: "xmark").font(.headline.bold())
                                                    .frame(width: 40, height: 40)
                                                    .background(.black.opacity(0.65), in: Circle())
                                            }
                                            .buttonStyle(.plain)
                                            .padding(8)
                                        }
                                }
                            }
                            .padding(.horizontal, 40)
                        }
                        HStack(spacing: 24) {
                            if cam.resultPhotos.count == 1 {
                                Button(role: .destructive) {
                                    cam.deleteResult(at: 0)
                                } label: {
                                    Label("Delete", systemImage: "trash").frame(width: 160, height: 56)
                                }
                                .buttonStyle(.bordered)
                            }
                            Button {
                                cam.dismissResult()
                                cam.capture(withCountdown: settings.countdownSeconds)
                            } label: {
                                Label("One more!", systemImage: "camera.fill").frame(width: 220, height: 56)
                            }
                            .buttonStyle(.borderedProminent).tint(.red)
                            Button {
                                cam.dismissResult()
                            } label: {
                                Label("Done", systemImage: "checkmark").frame(width: 160, height: 56)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 30)
                    if let link = qrLink {
                        VStack(spacing: 6) {
                            QRCodeView(text: link).frame(width: 110, height: 110)
                                .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8))
                            Text("Photos to your phone").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(24)
                    }
                }
                .transition(.opacity)
                .onTapGesture { cam.dismissResult() }
            }

            // Statusbanner oben (nur wenn etwas nicht laeuft)
            if let b = cam.banner, cam.resultPhotos.isEmpty {
                VStack {
                    HStack(spacing: 12) {
                        switch b.kind {
                        case .working: ProgressView().tint(.white)
                        case .info: Image(systemName: "cable.connector").font(.title2)
                        case .warning: Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.yellow)
                        case .error: Image(systemName: "xmark.octagon.fill").font(.title2).foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.text).font(.title3.bold())
                            if let d = b.detail { Text(d).font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(b.kind == .error ? Color.red : b.kind == .warning ? Color.yellow : Color.white.opacity(0.2), lineWidth: 1.5))
                    .padding(.top, 24)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Aufnahmefehler fuer Gaeste
            if let err = cam.captureError {
                ZStack {
                    Color.black.opacity(0.85)
                    VStack(spacing: 22) {
                        Text("😕").font(.system(size: 90))
                        Text(err).font(.title2).multilineTextAlignment(.center).padding(.horizontal, 60)
                        HStack(spacing: 24) {
                            Button {
                                cam.captureError = nil
                                cam.capture(withCountdown: settings.countdownSeconds)
                            } label: { Label("Try again", systemImage: "arrow.clockwise").frame(width: 240, height: 56) }
                            .buttonStyle(.borderedProminent).tint(.red)
                            Button { cam.captureError = nil } label: { Text("Close").frame(width: 160, height: 56) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .transition(.opacity)
                .task { try? await Task.sleep(nanoseconds: 20_000_000_000); cam.captureError = nil }
            }

            // Versteckter Admin-Zugang: mit zwei Fingern von oben nach unten wischen (UIKit-Erkenner am Fenster)
            TwoFingerSwipeDown {
                cam.noteInteraction()
                if adminUnlocked { adminUnlocked = false } else if settings.debugMode { adminUnlocked.toggle() } else { showPinPad = true }
            }
            .frame(width: 0, height: 0)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { cam.noteInteraction() })
        .animation(.spring(duration: 0.3), value: cam.capturePhrase)
        .animation(.easeInOut(duration: 0.3), value: cam.banner)
        .animation(.easeInOut(duration: 0.25), value: cam.captureError == nil)
        .animation(.easeInOut(duration: 0.25), value: cam.resultPhoto == nil)
        .animation(.easeInOut(duration: 0.6), value: cam.idle)
        .animation(.spring(duration: 0.3), value: cam.countdown)
    }
}

// MARK: - Admin-Panel (Seitenleiste)

struct AdminPanel: View {
    @EnvironmentObject var cam: CameraManager
    @EnvironmentObject var settings: AppSettings
    @Binding var adminUnlocked: Bool
    // Startabschnitt per Startargument waehlbar (-adminSection "Camera"), fuer Screenshots im Simulator
    @State private var section: Section = Section(rawValue: UserDefaults.standard.string(forKey: "adminSection") ?? "") ?? .event
    @State private var newPin = ""
    @State private var diagnosticsURL: URL?

    enum Section: String, CaseIterable, Identifiable {
        case event = "Event", camera = "Camera", flow = "Flow", screen = "Display & Sounds",
             storage = "Destinations", phrases = "Phrases", access = "Access", log = "Log"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .event: "calendar"; case .camera: "camera"; case .flow: "timer"; case .screen: "display"
            case .storage: "externaldrive"; case .phrases: "text.bubble"; case .access: "lock"; case .log: "doc.text.magnifyingglass"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Seitenleiste
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image("Logo").resizable().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("OpenBooth").font(.title3.bold())
                        Text(settings.eventName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)
                ForEach(Section.allCases) { sec in
                    Button { section = sec } label: {
                        HStack(spacing: 10) {
                            Image(systemName: sec.icon).frame(width: 22)
                            Text(LocalizedStringKey(sec.rawValue))
                            Spacer()
                            badge(for: sec)
                        }
                        .font(.body)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(section == sec ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(section == sec ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }
                Spacer()
                // Kamerastatus kompakt
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(cam.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
                Button { adminUnlocked = false } label: {
                    Label("Back to the booth", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 12).padding(.bottom, 16)
            }
            .frame(width: 230)
            .background(Color(.systemBackground).opacity(0.5))

            Divider()

            // Inhalt
            Form {
                switch section {
                case .event: eventSection
                case .camera: cameraSection
                case .flow: flowSection
                case .screen: screenSection
                case .storage: storageSection
                case .phrases: phrasesSection
                case .access: accessSection
                case .log: logSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var statusColor: Color {
        if cam.liveFrame != nil && cam.state == .connected { return .green }
        return cam.devices.isEmpty ? .red : .yellow
    }

    @ViewBuilder private func badge(for sec: Section) -> some View {
        switch sec {
        case .storage:
            let n = 1 + (settings.saveToPhotos ? 1 : 0) + (settings.immichEnabled ? 1 : 0) + (settings.webdavEnabled ? 1 : 0)
            Text("\(n)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
        case .camera where cam.state != .connected:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.caption)
        case .log where cam.lastError != nil:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
        default: EmptyView()
        }
    }

    // MARK: Abschnitte

    private var eventSection: some View {
        SwiftUI.Section {
            EventPanel()
        } header: { Text("Event") } footer: { Text("Also used as Immich album and WebDAV folder.") }
    }

    @ViewBuilder private var cameraSection: some View {
        SwiftUI.Section("Connection") {
            if !cam.deviceSummary.isEmpty { Text(cam.deviceSummary).font(.caption).foregroundStyle(.secondary) }
            if cam.devices.isEmpty {
                Label("No camera. Connect a Sony in “PC Remote” mode via USB-C.", systemImage: "cable.connector")
            }
            ForEach(cam.devices, id: \.self) { dev in
                Button { cam.openSession(dev) } label: { Label(dev.name ?? "Camera", systemImage: "camera") }
                    .disabled(cam.state == .sessionOpen || cam.state == .probed || cam.state == .connected)
            }
            Toggle("Connect automatically", isOn: $settings.autoConnect)
            Toggle("Restore camera settings made in the app when connecting", isOn: $settings.restoreCameraSettings)
            Toggle("Use the iPad camera as fallback when no USB camera is present", isOn: $settings.ipadFallback)
                .onChange(of: settings.ipadFallback) { _, _ in cam.syncFallback() }
            if settings.ipadFallback {
                Picker("iPad camera", selection: $settings.ipadFrontCamera) { Text("Front camera").tag(true); Text("Rear camera").tag(false) }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.ipadFrontCamera) { _, _ in cam.syncFallback() }
                if cam.usingIPadCamera { Label("iPad camera active", systemImage: "ipad.and.arrow.forward").foregroundStyle(.orange) }
            }
            LabeledContent("Battery", value: "iPad \(cam.batteryText(cam.iPadBattery()))" + (cam.cameraBattery().map { String(localized: ", camera \($0) %") } ?? ""))
            Toggle("Mirror live view", isOn: $settings.mirrorLiveView)
            Toggle("Histogram in live view and review", isOn: $settings.showHistogram)
            HStack {
                Button("PTP test") { cam.probe() }
                    .disabled(!(cam.state == .sessionOpen || cam.state == .probed || cam.state == .connected))
                Button("Handshake") { cam.connect() }.disabled(!(cam.state == .probed || cam.state == .connected))
                Button(cam.liveRunning ? "Stop live view" : "Start live view") {
                    cam.liveRunning ? cam.stopLiveView() : cam.startLiveView()
                }.disabled(cam.state != .connected)
            }
            .buttonStyle(.bordered)
        }
        if cam.state == .connected && !cam.settings.isEmpty {
            SwiftUI.Section {
                ForEach(cam.settings) { st in
                    HStack {
                        Text(st.title)
                        Spacer()
                        if st.options.isEmpty || !st.writable {
                            Text(st.currentLabel).monospacedDigit().foregroundStyle(.secondary)
                        } else {
                            SettingPicker(setting: st) { cam.apply(st.code, value: $0) }.disabled(cam.settingsBusy)
                        }
                    }
                }
            } header: {
                HStack { Text("Camera settings"); Spacer(); Button("Reload") { cam.reloadSettings() }.font(.caption) }
            }
        }
    }

    @ViewBuilder private var flowSection: some View {
        SwiftUI.Section("Capture") {
            Stepper("Countdown: \(settings.countdownSeconds) s", value: $settings.countdownSeconds, in: 0...10)
            Stepper("Shots per capture: \(settings.shotsPerCapture)", value: $settings.shotsPerCapture, in: 1...5, step: 2)
            if settings.shotsPerCapture > 1 {
                Stepper("Pause between shots: \(settings.shotInterval) s", value: $settings.shotInterval, in: 0...10)
            }
            Stepper("Review: \(settings.resultSeconds) s", value: $settings.resultSeconds, in: 3...60)
            Toggle("Pick up photos taken with the camera’s own shutter", isOn: $settings.pickupExternal)
        }
        SwiftUI.Section {
            Stepper("Collage after: \(settings.idleSeconds) s without activity", value: $settings.idleSeconds, in: 30...900, step: 30)
            Stepper("Collage changes every: \(settings.slideshowInterval) s", value: $settings.slideshowInterval, in: 3...30)
            Toggle("End when motion is detected in front of the camera", isOn: $settings.motionWake)
            if settings.motionWake {
                Stepper("Sensitivity: threshold \(settings.motionThreshold)", value: $settings.motionThreshold, in: 2...40)
                LabeledContent("Current image change", value: cam.idle ? String(format: "%.1f", cam.motionLevel) : "only during the collage")
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Idle") } footer: { Text("Lower threshold reacts earlier.") }
        SwiftUI.Section("Gallery") {
            Toggle("Gallery for guests", isOn: $settings.guestGallery)
            if settings.guestGallery {
                Stepper("Closes after: \(settings.gallerySeconds) s without touch", value: $settings.gallerySeconds, in: 10...300, step: 5)
            }
        }
    }

    @ViewBuilder private var screenSection: some View {
        SwiftUI.Section {
            TextField("Title", text: $settings.welcomeTitle)
            TextField("Text", text: $settings.welcomeText, axis: .vertical).lineLimit(2...4)
        } header: { Text("Welcome") }
        SwiftUI.Section {
            Toggle("Keep display at full brightness", isOn: $settings.maxBrightness)
                .onChange(of: settings.maxBrightness) { _, _ in cam.updateBrightness() }
        } header: { Text("Display") } footer: { Text("Dims during the idle collage.") }
        SwiftUI.Section("Sounds") {
            Toggle("Sounds", isOn: $settings.soundsEnabled)
            if settings.soundsEnabled {
                Toggle("Welcome chime when waking up", isOn: $settings.soundWelcome)
                Toggle("Countdown beeps and shutter signal", isOn: $settings.soundCountdown)
                HStack(spacing: 12) {
                    Button("Play welcome") { Sounds.shared.play("welcome") }
                    Button("Play countdown") { Sounds.shared.play("tick"); Task { try? await Task.sleep(nanoseconds: 900_000_000); Sounds.shared.play("shot") } }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var storageSection: some View {
        SwiftUI.Section {
            LabeledContent { Text("always").foregroundStyle(.secondary) } label: { Label("App gallery on the iPad", systemImage: "internaldrive") }
            Toggle(isOn: $settings.saveToPhotos) { Label("iPad photo library (Photos app)", systemImage: "photo.on.rectangle.angled") }
            Toggle(isOn: $settings.immichEnabled) { Label("Immich server", systemImage: "server.rack") }
                .onChange(of: settings.immichEnabled) { _, _ in cam.syncImmich() }
            Toggle(isOn: $settings.webdavEnabled) { Label("WebDAV folder (Nextcloud, NAS, Storage Box)", systemImage: "externaldrive.connected.to.line.below") }
                .onChange(of: settings.webdavEnabled) { _, _ in cam.syncWebDAV() }
        } header: { Text("Targets") }
        if settings.immichEnabled {
            SwiftUI.Section("Immich server") { ImmichPanel() }
        }
        if settings.webdavEnabled {
            SwiftUI.Section("WebDAV folder") { WebDAVPanel() }
        }
    }

    private var phrasesSection: some View {
        SwiftUI.Section {
            PhraseEditor()
        } header: { Text("Phrases at the shutter") }
    }

    @ViewBuilder private var accessSection: some View {
        SwiftUI.Section {
            HStack {
                SecureField("New PIN (at least 4 digits)", text: $newPin).keyboardType(.numberPad)
                Button("Set") { if newPin.count >= 4 { settings.pin = newPin; newPin = "" } }
                    .buttonStyle(.bordered).disabled(newPin.count < 4)
            }
        } header: { Text("PIN") } footer: { Text("Admin: two-finger swipe down, then PIN.") }
        SwiftUI.Section {
            Toggle("Status page on Wi‑Fi", isOn: $settings.webEnabled)
                .onChange(of: settings.webEnabled) { _, _ in cam.syncWeb() }
            if settings.webEnabled {
                let ips = LocalWebServer.localAddresses()
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ips, id: \.self) { ip in
                            LabeledContent("Address") { Text(verbatim: "http://\(ip):\(LocalWebServer.port)").monospaced().textSelection(.enabled) }
                        }
                        if ips.isEmpty { Text("No Wi‑Fi connected").foregroundStyle(.secondary) }
                        Text("Scan the QR code with your phone, then sign in with the admin PIN.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let ip = ips.first {
                        QRCodeView(text: "http://\(ip):\(LocalWebServer.port)").frame(width: 120, height: 120)
                            .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        } header: { Text("Remote access") } footer: { Text("Read-only status page, same Wi‑Fi, admin PIN.") }
        SwiftUI.Section {
            Toggle("Debug mode", isOn: $settings.debugMode)
        } header: { Text("Development") }
    }

    @ViewBuilder private var logSection: some View {
        SwiftUI.Section {
            HStack(spacing: 16) {
                // Datei wird beim Antippen frisch erzeugt, dann Teilen-Menue (AirDrop, Mail, …)
                Button { diagnosticsURL = cam.makeDiagnosticsFile() } label: { Label("Share diagnostics…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                Button { Task { await cam.sendDiagnostics(reason: "manual") } } label: { Label("Send to OpenBooth", systemImage: "paperplane") }
                    .buttonStyle(.bordered).disabled(cam.reportStatus == String(localized: "Sending…"))
                Spacer()
                if !cam.reportStatus.isEmpty { Text(cam.reportStatus).font(.caption).foregroundStyle(.secondary) }
            }
            .sheet(item: $diagnosticsURL) { url in ShareSheet(items: [url]) }
            Toggle("Send error reports automatically", isOn: $settings.autoReports)
        } header: { Text("Diagnostics") } footer: { Text("Camera capabilities and log, no credentials.") }
        if let e = cam.lastError {
            SwiftUI.Section("Last error") { Text(e).foregroundStyle(.red).font(.callout) }
        }
        SwiftUI.Section {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(cam.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).id(i)
                        }
                    }
                    .padding(6)
                }
                .onAppear { if !cam.log.isEmpty { proxy.scrollTo(cam.log.count - 1, anchor: .bottom) } }
                .onChange(of: cam.log.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
            .frame(minHeight: 420)
            .listRowInsets(EdgeInsets())
        } header: { Text("Log (\(cam.log.count) lines)") }
    }
}

// MARK: - PIN-Eingabe

struct PinPadView: View {
    let expected: String
    let done: (Bool) -> Void
    @State private var entry = ""
    @State private var wrong = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea().onTapGesture { done(false) }
            VStack(spacing: 18) {
                Text("PIN").font(.title.bold())
                HStack(spacing: 14) {
                    ForEach(0..<max(4, expected.count), id: \.self) { i in
                        Circle().fill(i < entry.count ? Color.white : Color.gray.opacity(0.4)).frame(width: 18, height: 18)
                    }
                }
                .padding(.bottom, 6)
                if wrong { Text("Wrong PIN").foregroundStyle(.red).font(.callout) }
                let keys = [["1","2","3"],["4","5","6"],["7","8","9"],["⌫","0","OK"]]
                ForEach(keys, id: \.self) { row in
                    HStack(spacing: 14) {
                        ForEach(row, id: \.self) { k in
                            Button {
                                switch k {
                                case "⌫": if !entry.isEmpty { entry.removeLast() }
                                case "OK":
                                    if entry == expected { done(true) } else { wrong = true; entry = "" }
                                default:
                                    entry.append(k)
                                    if entry.count == expected.count {
                                        if entry == expected { done(true) } else { wrong = true; entry = "" }
                                    }
                                }
                            } label: {
                                Text(k).font(.title2.bold()).frame(width: 84, height: 64)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(30)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}

// MARK: - Leerlauf-Collage

struct CollageView: View {
    let photos: [URL]
    let interval: Int
    let title: String
    @State private var picks: [URL] = []
    @State private var seed = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            GeometryReader { geo in
                ZStack {
                    ForEach(Array(picks.enumerated()), id: \.element) { i, url in
                        CollageCard(url: url)
                            .frame(width: geo.size.width * 0.42)
                            .rotationEffect(.degrees(Double((i * 7 + seed) % 15) - 7))
                            .position(position(i, in: geo.size))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            VStack {
                Spacer()
                Text("\(title)  ·  Press the button!")
                    .font(.title2.bold())
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 160)
            }
        }
        .onAppear { shuffle() }
        .task(id: seed) {
            try? await Task.sleep(nanoseconds: UInt64(max(3, interval)) * 1_000_000_000)
            if !Task.isCancelled { shuffle() }
        }
        .animation(.easeInOut(duration: 0.8), value: picks)
    }

    private func position(_ i: Int, in size: CGSize) -> CGPoint {
        let spots = [CGPoint(x: 0.28, y: 0.32), CGPoint(x: 0.72, y: 0.30), CGPoint(x: 0.30, y: 0.70), CGPoint(x: 0.70, y: 0.68)]
        let p = spots[i % spots.count]
        return CGPoint(x: size.width * p.x, y: size.height * p.y)
    }

    private func shuffle() {
        let n = min(4, photos.count)
        picks = Array(photos.shuffled().prefix(n))
        seed += 1
    }
}

struct CollageCard: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.gray.opacity(0.3)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .aspectRatio(3/2, contentMode: .fit)
            .clipped()
            .padding(10)
            Color.white.frame(height: 26)
        }
        .background(Color.white)
        .shadow(color: .black.opacity(0.6), radius: 16, y: 8)
        .task(id: url) { image = await ThumbnailStore.thumbnail(for: url) }
    }
}

// MARK: - Galerie

struct GalleryView: View {
    let photos: [URL]
    var autoClose: Int = 30
    var onActivity: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var selected: URL?
    @State private var lastTouch = Date()

    var body: some View {
        galleryBody
            // Beruehrungen ueber einen UIKit-Beobachter zaehlen: eine SwiftUI-DragGesture stoerte das Einrasten der Seiten
            .background(TouchActivity { lastTouch = Date(); onActivity() })
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if autoClose > 0, Date().timeIntervalSince(lastTouch) > TimeInterval(autoClose) { dismiss(); break }
                }
            }
    }

    private var galleryBody: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(photos, id: \.self) { url in
                        Thumb(url: url).onTapGesture { selected = url }
                    }
                }
                .padding()
            }
            .navigationTitle("Gallery (\(photos.count))")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .overlay {
                if selected != nil {
                    ZStack {
                        Color.black.opacity(0.97).ignoresSafeArea()
                        // Durchwischen: horizontaler ScrollView mit Seiten-Einrasten, jede Seite exakt Containerbreite
                        // (TabView im Seitenstil blieb im Vollbild zwischen zwei Seiten stehen)
                        GeometryReader { g in
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 0) {
                                    ForEach(photos, id: \.self) { url in
                                        LargePhoto(url: url)
                                            .frame(width: g.size.width, height: g.size.height)
                                            .id(url)
                                    }
                                }
                                .scrollTargetLayout()
                            }
                            .scrollTargetBehavior(.paging)
                            .scrollPosition(id: $selected)
                            .scrollIndicators(.hidden)
                        }
                        .ignoresSafeArea()
                        VStack {
                            HStack {
                                if let sel = selected, let i = photos.firstIndex(of: sel) {
                                    Text("\(i + 1) / \(photos.count)").font(.headline).foregroundStyle(.secondary).padding()
                                }
                                Spacer()
                                Button { selected = nil } label: {
                                    Image(systemName: "xmark").font(.title2.bold()).frame(width: 56, height: 56)
                                        .background(.black.opacity(0.5), in: Circle())
                                }
                                .buttonStyle(.plain).padding()
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    struct LargePhoto: View {
        let url: URL
        @State private var image: UIImage?
        var body: some View {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit().padding() } else { ProgressView() }
            }
            .task(id: url) {
                if let data = try? Data(contentsOf: url) { image = await CameraManager.previewImage(from: data) }
            }
        }
    }

    struct Thumb: View {
        let url: URL
        @State private var image: UIImage?
        var body: some View {
            ZStack {
                Color.gray.opacity(0.2)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .aspectRatio(3/2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .task { image = await ThumbnailStore.thumbnail(for: url) }
        }
    }
}


// MARK: - Beruehrungs-Beobachter (UIKit): meldet jeden Touch im Fenster, erkennt selbst nie, stoert nichts

struct TouchActivity: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
        if context.coordinator.recognizer == nil { context.coordinator.attach(to: uiView.window) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.detach() }

    /// Erkenner, der bei jedem Touch-Beginn meldet und sofort fehlschlaegt, damit Scrollen und Paging unberuehrt bleiben.
    final class Observer: UIGestureRecognizer {
        var onTouch: (() -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { onTouch?(); state = .failed }
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        weak var window: UIWindow?
        var recognizer: Observer?
        init(action: @escaping () -> Void) { self.action = action }

        func attach(to window: UIWindow?) {
            guard let window, recognizer == nil else { return }
            let r = Observer()
            r.cancelsTouchesInView = false
            r.delaysTouchesBegan = false
            r.onTouch = { [weak self] in self?.action() }
            window.addGestureRecognizer(r)
            recognizer = r
            self.window = window
        }

        func detach() {
            if let r = recognizer { window?.removeGestureRecognizer(r) }
            recognizer = nil
        }
    }
}

// MARK: - Zwei-Finger-Wischgeste (UIKit), haengt sich ans Fenster, blockiert keine anderen Touches

struct TwoFingerSwipeDown: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
        if context.coordinator.recognizer == nil { context.coordinator.attach(to: uiView.window) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.detach() }

    final class Coordinator: NSObject {
        var action: () -> Void
        weak var window: UIWindow?
        var recognizer: UISwipeGestureRecognizer?
        init(action: @escaping () -> Void) { self.action = action }

        func attach(to window: UIWindow?) {
            guard let window, recognizer == nil else { return }
            let r = UISwipeGestureRecognizer(target: self, action: #selector(fire))
            r.direction = .down
            r.numberOfTouchesRequired = 2
            r.cancelsTouchesInView = false
            window.addGestureRecognizer(r)
            recognizer = r
            self.window = window
        }

        func detach() {
            if let r = recognizer { window?.removeGestureRecognizer(r) }
            recognizer = nil
        }

        @objc func fire() { action() }
    }
}


// MARK: - Sprueche bearbeiten

struct PhraseEditor: View {
    @EnvironmentObject var settings: AppSettings
    @State private var newPhrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(settings.phrases.enumerated()), id: \.offset) { i, p in
                HStack {
                    TextField("Phrase", text: Binding(
                        get: { settings.phrases.indices.contains(i) ? settings.phrases[i] : "" },
                        set: { v in if settings.phrases.indices.contains(i) { settings.phrases[i] = v } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        if settings.phrases.indices.contains(i) { settings.phrases.remove(at: i) }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("New phrase", text: $newPhrase).textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Add") { add() }.buttonStyle(.bordered)
                    .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Text("\(settings.phrases.count) phrases, random, never the same one twice in a row.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Defaults") { settings.phrases = AppSettings.defaultPhrases }.font(.caption).buttonStyle(.bordered)
            }
        }
        .font(.callout)
    }

    private func add() {
        let p = newPhrase.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        settings.phrases.append(p)
        newPhrase = ""
    }
}


// MARK: - Immich-Einstellungen

/// Auswahl eines Kamerawerts in einem scrollbaren Popover (Menus mit 40+ Eintraegen liessen sich nicht scrollen).
struct SettingPicker: View {
    let setting: CameraSetting
    let apply: (Int64) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Text(setting.currentLabel).font(.callout.monospacedDigit())
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $open) {
            ScrollViewReader { proxy in
                List(setting.options) { o in
                    Button {
                        open = false
                        apply(o.value)
                    } label: {
                        HStack {
                            Text(o.label).monospacedDigit()
                            Spacer()
                            if o.value == setting.current { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .id(o.value)
                }
                .listStyle(.plain)
                .frame(width: 280, height: min(520, CGFloat(setting.options.count) * 44 + 16))
                .onAppear { if let c = setting.current { proxy.scrollTo(c, anchor: .center) } }
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Systemweites Teilen-Menue (UIActivityViewController) fuer eine Datei.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct EventPanel: View {
    @EnvironmentObject var cam: CameraManager
    @EnvironmentObject var settings: AppSettings
    @State private var newName = ""
    @State private var askNew = false
    @State private var askDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Current", selection: $settings.eventName) {
                ForEach(settings.events, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: settings.eventName) { _, _ in cam.syncUploaders() }
            HStack {
                Text("\(cam.sessionPhotos.count) photos").foregroundStyle(.secondary)
                Spacer()
                Button { newName = ""; askNew = true } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(.bordered)
                Button(role: .destructive) { askDelete = true } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(.bordered).disabled(settings.events.count <= 1)
            }
            .lineLimit(1)
        }
        .font(.callout)
        .alert("New event", isPresented: $askNew) {
            TextField("Name, e.g. Anna & Paul’s wedding", text: $newName)
            Button("Create") {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { return }
                if !settings.events.contains(n) { settings.events.append(n) }
                settings.eventName = n
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove “\(settings.eventName)” from the list?", isPresented: $askDelete) {
            Button("Remove", role: .destructive) {
                let old = settings.eventName
                settings.events.removeAll { $0 == old }
                settings.eventName = settings.events.first ?? String(localized: "Photo Booth")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos stay on the iPad in the event’s folder, only the entry disappears.")
        }
    }
}

/// QR-Code aus CoreImage, scharf skaliert.
struct QRCodeView: View {
    let text: String
    var body: some View {
        if let img = Self.make(text) {
            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
        }
    }
    static func make(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct WebDAVPanel: View {
    @EnvironmentObject var cam: CameraManager
    @EnvironmentObject var settings: AppSettings
    @State private var password = ""
    @State private var pwStored = Keychain.get("webdavPassword")?.isEmpty == false
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Base URL, e.g. https://cloud.example.com/remote.php/dav/files/name", text: $settings.webdavURL)
                .textFieldStyle(.roundedBorder).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { cam.syncWebDAV(); runTest() }
            HStack {
                TextField("User", text: $settings.webdavUser)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { cam.syncWebDAV() }
                SecureField(pwStored ? "Password saved, enter a new one to replace it" : "Password or app password", text: $password)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(testing ? "Checking…" : "Save") {
                    Keychain.set(password, for: "webdavPassword")
                    pwStored = !password.isEmpty; password = ""; cam.syncWebDAV()
                    runTest()
                }.buttonStyle(.bordered).disabled(password.isEmpty || testing)
            }
            Toggle("Upload RAW files too", isOn: $settings.webdavUploadRAW)
            HStack {
                Button(testing ? "Testing…" : "Test connection") { cam.syncWebDAV(); runTest() }
                    .buttonStyle(.bordered).disabled(testing || settings.webdavURL.isEmpty)
                Spacer()
                Text("Status: \(cam.webdav.lastMessage)").font(.caption).foregroundStyle(.secondary)
            }
            if !testResult.isEmpty { Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("OK") ? .green : .red) }
        }
        .font(.callout)
    }

    private func runTest() {
        guard !settings.webdavURL.isEmpty, !testing else { return }
        testing = true
        Task { testResult = await cam.webdav.test(); testing = false }
    }
}

struct ImmichPanel: View {
    @EnvironmentObject var cam: CameraManager
    @EnvironmentObject var settings: AppSettings
    @State private var apiKey = ""
    @State private var keyStored = Keychain.get("immichAPIKey")?.isEmpty == false
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Server, e.g. https://immich.example.com", text: $settings.immichURL)
                .textFieldStyle(.roundedBorder).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { cam.syncImmich(); runTest() }
            HStack {
                SecureField(keyStored ? "API key saved, enter a new one to replace it" : "API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(testing ? "Checking…" : "Save") {
                    Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "immichAPIKey")
                    keyStored = !apiKey.isEmpty; apiKey = ""; cam.syncImmich()
                    runTest()
                }.buttonStyle(.bordered).disabled(apiKey.isEmpty || testing)
            }
            Text("Album: “\(settings.eventName)” (event name)").foregroundStyle(.secondary)
            Toggle("Show QR code to the album for guests", isOn: $settings.qrEnabled)
            if let link = cam.immich.shareURL {
                Text("Share link: \(link)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Toggle("Upload RAW files too", isOn: $settings.immichUploadRAW)
            HStack {
                Button(testing ? "Testing…" : "Test connection") { cam.syncImmich(); runTest() }
                    .buttonStyle(.bordered).disabled(testing || settings.immichURL.isEmpty)
                Spacer()
                Text("Status: \(cam.immich.lastMessage)").font(.caption).foregroundStyle(.secondary)
            }
            if !testResult.isEmpty { Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("OK") ? .green : .red) }
        }
        .font(.callout)
    }

    private func runTest() {
        guard !settings.immichURL.isEmpty, !testing else { return }
        testing = true
        Task { testResult = await cam.immich.test(); testing = false }
    }
}
