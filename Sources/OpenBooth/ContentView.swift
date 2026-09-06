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
                    let w: CGFloat = 400
                    let sc = w / max(1, geo.size.width)
                    VStack(spacing: 6) {
                        Text("Gästesicht (live)").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
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
                        Text("Foto \(cam.shotNumber) von \(cam.shotTotal)")
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

            // Bedienleiste unten
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if settings.guestGallery {
                        Button {
                            cam.noteInteraction()
                            showGallery = true
                        } label: {
                            Label("Galerie", systemImage: "photo.on.rectangle").frame(width: 160, height: 56)
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
                            Text("Foto aufnehmen").font(.headline)
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
                            Label("Fotos aufs Handy", systemImage: "qrcode").frame(width: 160, height: 56)
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
                        Text("Alle Fotos vom Abend").font(.system(size: 40, weight: .bold))
                        Text("QR-Code mit der Handykamera scannen").font(.title3).foregroundStyle(.secondary)
                        QRCodeView(text: link).frame(width: 360, height: 360)
                            .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                        Text(link).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        Button { showQR = false; cam.qrShown = false } label: { Label("Schließen", systemImage: "xmark").frame(width: 200, height: 56) }
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
                                    Label("Löschen", systemImage: "trash").frame(width: 160, height: 56)
                                }
                                .buttonStyle(.bordered)
                            }
                            Button {
                                cam.dismissResult()
                                cam.capture(withCountdown: settings.countdownSeconds)
                            } label: {
                                Label("Noch ein Foto!", systemImage: "camera.fill").frame(width: 220, height: 56)
                            }
                            .buttonStyle(.borderedProminent).tint(.red)
                            Button {
                                cam.dismissResult()
                            } label: {
                                Label("Fertig", systemImage: "checkmark").frame(width: 160, height: 56)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 30)
                    if let link = qrLink {
                        VStack(spacing: 6) {
                            QRCodeView(text: link).frame(width: 110, height: 110)
                                .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8))
                            Text("Fotos aufs Handy").font(.caption).foregroundStyle(.secondary)
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
                            } label: { Label("Nochmal versuchen", systemImage: "arrow.clockwise").frame(width: 240, height: 56) }
                            .buttonStyle(.borderedProminent).tint(.red)
                            Button { cam.captureError = nil } label: { Text("Schließen").frame(width: 160, height: 56) }
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
    @State private var showLog = true
    @State private var newPin = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("OpenBooth").font(.largeTitle.bold())
                    Spacer()
                    Button("Schließen") { adminUnlocked = false }.buttonStyle(.bordered)
                }
                Text(cam.status).font(.headline).foregroundStyle(.secondary)
                if let e = cam.lastError {
                    Text("Letzter Fehler: \(e)").font(.caption).foregroundStyle(.red)
                }

                GroupBox("Veranstaltung") {
                    EventPanel()
                }

                GroupBox("Kamera") {
                    VStack(alignment: .leading, spacing: 6) {
                        if !cam.deviceSummary.isEmpty { Text(cam.deviceSummary).font(.caption) }
                        if cam.devices.isEmpty {
                            Text("Keine Kamera. Sony im Modus „PC-Fernbedienung“ per USB-C anschließen.").font(.callout)
                        }
                        ForEach(cam.devices, id: \.self) { dev in
                            Button { cam.openSession(dev) } label: { Label(dev.name ?? "Kamera", systemImage: "camera") }
                                .buttonStyle(.borderedProminent)
                                .disabled(cam.state == .sessionOpen || cam.state == .probed || cam.state == .connected)
                        }
                        HStack {
                            Button("PTP-Test") { cam.probe() }.buttonStyle(.bordered)
                                .disabled(!(cam.state == .sessionOpen || cam.state == .probed || cam.state == .connected))
                            Button("Handshake") { cam.connect() }.buttonStyle(.bordered)
                                .disabled(!(cam.state == .probed || cam.state == .connected))
                            Button(cam.liveRunning ? "Liveview stop" : "Liveview") {
                                cam.liveRunning ? cam.stopLiveView() : cam.startLiveView()
                            }.buttonStyle(.bordered).disabled(cam.state != .connected)
                        }
                        Toggle("Automatisch verbinden", isOn: $settings.autoConnect).font(.caption)
                    }
                }

                if cam.state == .connected && !cam.settings.isEmpty {
                    GroupBox("Kameraeinstellungen") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(cam.settings) { st in
                                HStack {
                                    Text(st.title).font(.callout)
                                    Spacer()
                                    if st.options.isEmpty || !st.writable {
                                        Text(st.currentLabel).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                    } else {
                                        SettingPicker(setting: st) { cam.apply(st.code, value: $0) }
                                            .disabled(cam.settingsBusy)
                                    }
                                }
                            }
                            Button("Neu laden") { cam.reloadSettings() }.font(.caption).buttonStyle(.bordered)
                        }
                    }
                }

                GroupBox("Fotobox") {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper("Countdown: \(settings.countdownSeconds) s", value: $settings.countdownSeconds, in: 0...10)
                        Stepper("Rückschau: \(settings.resultSeconds) s", value: $settings.resultSeconds, in: 3...60)
                        Stepper("Bilder pro Auslösung: \(settings.shotsPerCapture)", value: $settings.shotsPerCapture, in: 1...5, step: 2)
                        Stepper("Pause zwischen Bildern: \(settings.shotInterval) s", value: $settings.shotInterval, in: 0...10)
                        Toggle("Töne", isOn: $settings.soundsEnabled)
                        if settings.soundsEnabled {
                            HStack(spacing: 24) {
                                Toggle("Willkommensklang beim Aufwachen", isOn: $settings.soundWelcome)
                                Toggle("Countdown-Piepen", isOn: $settings.soundCountdown)
                            }
                            .padding(.leading, 20)
                            HStack(spacing: 12) {
                                Button("Willkommen anhören") { Sounds.shared.play("welcome") }
                                Button("Countdown anhören") { Sounds.shared.play("tick"); Task { try? await Task.sleep(nanoseconds: 900_000_000); Sounds.shared.play("shot") } }
                            }
                            .buttonStyle(.bordered).font(.caption).padding(.leading, 20)
                        }
                        Toggle("Display dauerhaft auf volle Helligkeit", isOn: $settings.maxBrightness)
                            .onChange(of: settings.maxBrightness) { _, _ in cam.updateBrightness() }
                        Text("Während der Leerlauf-Collage geht die Helligkeit auf den vorherigen Wert zurück, bei Bewegung oder Aufnahme wieder hoch. Die QR-Seite ist immer voll hell.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Collage bei Bewegung vor der Kamera beenden", isOn: $settings.motionWake)
                        if settings.motionWake {
                            Stepper("Empfindlichkeit: Schwelle \(settings.motionThreshold)", value: $settings.motionThreshold, in: 2...40)
                            Text(String(format: "Kleinere Schwelle reagiert früher. Aktuelle Bildänderung im Leerlauf: %.1f (nur sichtbar, während die Collage läuft).", cam.motionLevel))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Fotos vom Kamera-Auslöser übernehmen", isOn: $settings.pickupExternal)
                        Text("Auch Bilder, die direkt an der Kamera oder per Fernauslöser gemacht werden, landen in Galerie, Rückschau und Speicherorten.")
                            .font(.caption).foregroundStyle(.secondary)
                        Stepper("Collage nach: \(settings.idleSeconds) s", value: $settings.idleSeconds, in: 30...900, step: 30)
                        Stepper("Collage wechselt alle: \(settings.slideshowInterval) s", value: $settings.slideshowInterval, in: 3...30)
                        Toggle("Liveview spiegeln", isOn: $settings.mirrorLiveView)
                        Toggle("Galerie für Gäste", isOn: $settings.guestGallery)
                        if settings.guestGallery {
                            Stepper("Galerie schließt nach: \(settings.gallerySeconds) s ohne Berührung", value: $settings.gallerySeconds, in: 10...300, step: 5)
                        }
                        TextField("Titel", text: $settings.welcomeTitle).textFieldStyle(.roundedBorder)
                        TextField("Text", text: $settings.welcomeText, axis: .vertical).textFieldStyle(.roundedBorder)
                    }
                    .font(.callout)
                }

                GroupBox("Speicherorte") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("App-Galerie auf dem iPad", systemImage: "internaldrive")
                            Spacer()
                            Text("immer").foregroundStyle(.secondary)
                        }
                        Toggle(isOn: $settings.saveToPhotos) { Label("iPad-Mediathek (Fotos-App)", systemImage: "photo.on.rectangle.angled") }
                        Toggle(isOn: $settings.immichEnabled) { Label("Immich-Server", systemImage: "server.rack") }
                            .onChange(of: settings.immichEnabled) { _, _ in cam.syncImmich() }
                        Toggle(isOn: $settings.webdavEnabled) { Label("WebDAV-Ordner (Nextcloud, NAS, Storage Box)", systemImage: "externaldrive.connected.to.line.below") }
                            .onChange(of: settings.webdavEnabled) { _, _ in cam.syncWebDAV() }
                        Text("Die App-Galerie ist die Quelle für Rückschau, Galerie und Collage und bleibt immer an.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                if settings.immichEnabled {
                    GroupBox("Immich-Server") {
                        ImmichPanel()
                    }
                }
                if settings.webdavEnabled {
                    GroupBox("WebDAV-Ordner") {
                        WebDAVPanel()
                    }
                }

                GroupBox("Sprüche beim Auslösen") {
                    PhraseEditor()
                }

                GroupBox("Zugang") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Debug-Modus (Seitenleiste immer sichtbar)", isOn: $settings.debugMode)
                        HStack {
                            SecureField("Neue PIN", text: $newPin).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                            Button("Setzen") {
                                if newPin.count >= 4 { settings.pin = newPin; newPin = "" }
                            }.buttonStyle(.bordered).disabled(newPin.count < 4)
                        }
                        Text("Admin öffnen: mit zwei Fingern von oben nach unten wischen.").font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                Toggle("Log anzeigen", isOn: $showLog).font(.caption)
                if showLog {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(cam.log.enumerated()), id: \.offset) { i, line in
                                    Text(line).font(.system(size: 10, design: .monospaced)).id(i)
                                }
                            }
                        }
                        .onChange(of: cam.log.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
                    }
                    .frame(height: 320)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding()
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
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
                if wrong { Text("Falsche PIN").foregroundStyle(.red).font(.callout) }
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
                Text("\(title)  ·  Drückt auf den Knopf!")
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
            .navigationTitle("Galerie (\(photos.count))")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Schließen") { dismiss() } } }
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
                    TextField("Spruch", text: Binding(
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
                TextField("Neuer Spruch", text: $newPhrase).textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Hinzufügen") { add() }.buttonStyle(.bordered)
                    .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Text("\(settings.phrases.count) Sprüche, zufällig, nie zweimal derselbe nacheinander.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Standard") { settings.phrases = AppSettings.defaultPhrases }.font(.caption).buttonStyle(.bordered)
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

struct EventPanel: View {
    @EnvironmentObject var cam: CameraManager
    @EnvironmentObject var settings: AppSettings
    @State private var newName = ""
    @State private var askNew = false
    @State private var askDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Aktuell", selection: $settings.eventName) {
                    ForEach(settings.events, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: settings.eventName) { _, _ in cam.syncUploaders() }
                Spacer()
                Text("\(cam.sessionPhotos.count) Fotos").foregroundStyle(.secondary)
                Button { newName = ""; askNew = true } label: { Label("Neu", systemImage: "plus") }
                    .buttonStyle(.bordered)
                Button(role: .destructive) { askDelete = true } label: { Label("Entfernen", systemImage: "trash") }
                    .buttonStyle(.bordered).disabled(settings.events.count <= 1)
            }
            Text("Jede Veranstaltung hat eigene Fotos in Galerie und Collage, ein eigenes Album in Immich und einen eigenen Ordner im WebDAV-Ziel. Beim Wechsel bleiben die Fotos der anderen erhalten.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
        .alert("Neue Veranstaltung", isPresented: $askNew) {
            TextField("Name, z. B. Hochzeit Anna & Paul", text: $newName)
            Button("Anlegen") {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { return }
                if !settings.events.contains(n) { settings.events.append(n) }
                settings.eventName = n
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("„\(settings.eventName)“ aus der Liste entfernen?", isPresented: $askDelete) {
            Button("Entfernen", role: .destructive) {
                let old = settings.eventName
                settings.events.removeAll { $0 == old }
                settings.eventName = settings.events.first ?? "Fotobox"
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Fotos bleiben auf dem iPad im Ordner der Veranstaltung erhalten, nur der Eintrag verschwindet.")
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
            TextField("Basis-URL, z. B. https://cloud.example.de/remote.php/dav/files/name", text: $settings.webdavURL)
                .textFieldStyle(.roundedBorder).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { cam.syncWebDAV(); runTest() }
            HStack {
                TextField("Benutzer", text: $settings.webdavUser)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { cam.syncWebDAV() }
                SecureField(pwStored ? "Passwort gespeichert, neues eingeben zum Ersetzen" : "Passwort oder App-Passwort", text: $password)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(testing ? "Prüfe …" : "Speichern") {
                    Keychain.set(password, for: "webdavPassword")
                    pwStored = !password.isEmpty; password = ""; cam.syncWebDAV()
                    runTest()
                }.buttonStyle(.bordered).disabled(password.isEmpty || testing)
            }
            Toggle("RAW-Dateien mit hochladen", isOn: $settings.webdavUploadRAW)
            HStack {
                Button(testing ? "Teste …" : "Verbindung testen") { cam.syncWebDAV(); runTest() }
                    .buttonStyle(.bordered).disabled(testing || settings.webdavURL.isEmpty)
                Spacer()
                Text("Status: \(cam.webdav.lastMessage)").font(.caption).foregroundStyle(.secondary)
            }
            if !testResult.isEmpty { Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("OK") ? .green : .red) }
            Text("Darunter wird der Ordner „\(settings.eventName)“ angelegt. Nextcloud: remote.php/dav/files/BENUTZER, am besten mit App-Passwort. Passwort liegt im Schlüsselbund des iPads.")
                .font(.caption).foregroundStyle(.secondary)
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
            TextField("Server, z. B. https://immich.example.de", text: $settings.immichURL)
                .textFieldStyle(.roundedBorder).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { cam.syncImmich(); runTest() }
            HStack {
                SecureField(keyStored ? "API-Key gespeichert, neuen eingeben zum Ersetzen" : "API-Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(testing ? "Prüfe …" : "Speichern") {
                    Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "immichAPIKey")
                    keyStored = !apiKey.isEmpty; apiKey = ""; cam.syncImmich()
                    runTest()
                }.buttonStyle(.bordered).disabled(apiKey.isEmpty || testing)
            }
            Text("Album: „\(settings.eventName)“ (Name der Veranstaltung)").foregroundStyle(.secondary)
            Toggle("QR-Code zum Album für Gäste anzeigen", isOn: $settings.qrEnabled)
            if let link = cam.immich.shareURL {
                Text("Freigabelink: \(link)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Der Link zeigt auf die Server-Adresse oben. Gäste müssen sie erreichen können, also z. B. https://immich.example.de statt einer IP im Heimnetz eintragen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("RAW-Dateien mit hochladen", isOn: $settings.immichUploadRAW)
            Text("Wirkt nur, wenn die Bildqualität in den Kameraeinstellungen auf RAW oder RAW+JPEG steht. Das JPEG geht immer hoch.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(testing ? "Teste …" : "Verbindung testen") { cam.syncImmich(); runTest() }
                    .buttonStyle(.bordered).disabled(testing || settings.immichURL.isEmpty)
                Spacer()
                Text("Status: \(cam.immich.lastMessage)").font(.caption).foregroundStyle(.secondary)
            }
            if !testResult.isEmpty { Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("OK") ? .green : .red) }
            Text("API-Key in Immich unter Kontoeinstellungen › API-Schlüssel anlegen. Er wird im Schlüsselbund des iPads gespeichert. Upload läuft im Hintergrund mit Warteschlange, ohne Netz wird nachgeholt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func runTest() {
        guard !settings.immichURL.isEmpty, !testing else { return }
        testing = true
        Task { testResult = await cam.immich.test(); testing = false }
    }
}
