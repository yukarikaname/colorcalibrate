//
//  ContentView.swift
//  colorcalibrate
//
//  Created by Yukari Kaname on 3/22/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        #if os(macOS)
            MacCalibrationRootView()
        #else
            PhoneCalibrationRootView()
        #endif
    }
}

#Preview {
    ContentView()
}
