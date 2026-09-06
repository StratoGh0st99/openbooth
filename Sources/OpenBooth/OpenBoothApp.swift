//
//  OpenBoothApp.swift
//  OpenBooth
//
//  Offene Fotobox-App fuer das iPad: Kamera per USB-C (PTP), Liveview, Ausloesen, Galerie.
//

import SwiftUI

@main
struct OpenBoothApp: App {
    @StateObject private var camera = CameraManager()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .environmentObject(settings)
        }
    }
}
