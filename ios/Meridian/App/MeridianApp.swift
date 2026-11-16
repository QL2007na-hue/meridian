//
//  MeridianApp.swift
//  Meridian — the entry point.
//
//  Everything interesting is in RootView. The app deliberately has one window,
//  one screen and no navigation stack: it is an instrument, not a document
//  browser.
//

import SwiftUI

@main
struct MeridianApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
