//
//  CalibrationFullScreenView.swift
//  colorcalibrate
//
//  A full-screen overlay managed by NSWindow for calibration patches.
//  Owns its own borderless window that fills the target display.
//

#if os(macOS)
import AppKit
import SwiftUI

/// A SwiftUI view that fills the window with a single solid colour.
struct CalibrationFullScreenContent: View {
    let color: RGBColor
    let showCrosshair: Bool

    var body: some View {
        ZStack {
            color.swiftUIColor
                .ignoresSafeArea()

            if showCrosshair {
                // Thin crosshair to help iPhone alignment.
                Path { path in
                    let midX = NSScreen.main?.frame.width ?? 800
                    let midY = NSScreen.main?.frame.height ?? 600
                    path.move(to: CGPoint(x: midX / 2, y: 0))
                    path.addLine(to: CGPoint(x: midX / 2, y: midY))
                    path.move(to: CGPoint(x: 0, y: midY / 2))
                    path.addLine(to: CGPoint(x: midX, y: midY / 2))
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
            }
        }
    }
}

/// Manages the full-screen calibration window lifecycle.
@MainActor
final class CalibrationFullScreenWindow: NSObject {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Opens a borderless, full-screen window on the given screen showing the patch colour.
    func show(color: RGBColor, on screen: NSScreen? = nil) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else { return }

        if window == nil {
            let rect = targetScreen.frame
            window = NSWindow(
                contentRect: rect,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false,
                screen: targetScreen
            )
            window?.isReleasedWhenClosed = false
            window?.level = .normal
            window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window?.isOpaque = true
            window?.backgroundColor = .clear
            window?.hasShadow = false
            window?.ignoresMouseEvents = true
        }

        // Resize if the screen changed.
        window?.setFrame(targetScreen.frame, display: true)

        window?.contentView = NSHostingView(
            rootView: CalibrationFullScreenContent(color: color, showCrosshair: true)
        )
        window?.makeKeyAndOrderFront(nil)
    }

    /// Updates the colour of the currently visible patch.
    func update(color: RGBColor) {
        guard window?.isVisible == true else { return }
        window?.contentView = NSHostingView(
            rootView: CalibrationFullScreenContent(color: color, showCrosshair: true)
        )
    }

    /// Hides and cleans up the full-screen window.
    func hide() {
        window?.orderOut(nil)
        window?.contentView = nil
    }

    /// Fully destroy the window (call when calibration ends).
    func destroy() {
        hide()
        window = nil
    }
}
#endif
