//
//  OpenBoothApp.swift
//  OpenBooth
//
//  Open photo booth app for the iPad: camera via USB-C (PTP), live view, shutter, gallery.
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
