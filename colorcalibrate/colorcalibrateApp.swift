//
//  colorcalibrateApp.swift
//  colorcalibrate
//
//  Created by Yukari Kaname on 3/22/26.
//

import SwiftUI

@main
struct colorcalibrateApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
            .windowResizability(.contentSize)
        #endif
    }
}
