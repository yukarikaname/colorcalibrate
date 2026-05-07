//
//  DisplayConditionController.swift
//  colorcalibrate
//
//  Created by Yukari Kaname on 3/23/26.
//

import AppKit
import CoreGraphics
import Foundation
import IOKit.graphics
import Observation
import ObjectiveC.runtime
import Security

enum PrivateFeatureState: Equatable {
    case enabled
    case disabled
    case unavailable

    var description: String {
        switch self {
        case .enabled:
            return "On"
        case .disabled:
            return "Off"
        case .unavailable:
            return "Unavailable"
        }
    }
}

struct DisplaySignalState: Equatable {
    var pixelEncoding: String
    var signalDescription: String
    var limitedRangeLikely: Bool
    var ycbcrLikely: Bool

    static let unavailable = DisplaySignalState(
        pixelEncoding: "Unknown",
        signalDescription: "Unknown",
        limitedRangeLikely: false,
        ycbcrLikely: false
    )
}

struct DisplayConditionSnapshot: Equatable {
    var brightness: Double?
    var brightnessDescription: String
    var nightShift: PrivateFeatureState
    var trueTone: PrivateFeatureState
    var signal: DisplaySignalState

    static let empty = DisplayConditionSnapshot(
        brightness: nil,
        brightnessDescription: "Unavailable",
        nightShift: .unavailable,
        trueTone: .unavailable,
        signal: .unavailable
    )
}

@MainActor
@Observable
final class DisplayConditionController {
    private(set) var snapshot = DisplayConditionSnapshot.empty
    private var storedBrightnessByDisplay: [CGDirectDisplayID: Float] = [:]

    func refresh(displayID: CGDirectDisplayID) {
        if isSandboxed {
            snapshot = DisplayConditionSnapshot(
                brightness: nil,
                brightnessDescription: "Unavailable in sandboxed build",
                nightShift: .unavailable,
                trueTone: .unavailable,
                signal: detectSignalState(for: displayID)
            )
            return
        }

        snapshot = DisplayConditionSnapshot(
            brightness: currentBrightness(for: displayID).map(Double.init),
            brightnessDescription: brightnessDescription(for: displayID),
            nightShift: detectNightShift(),
            trueTone: detectTrueTone(),
            signal: detectSignalState(for: displayID)
        )
    }

    func maximizeBrightness(for displayID: CGDirectDisplayID) {
        guard !isSandboxed else { return }
        guard let currentBrightness = currentBrightness(for: displayID) else { return }

        if storedBrightnessByDisplay[displayID] == nil {
            storedBrightnessByDisplay[displayID] = currentBrightness
        }

        guard let service = displayService(for: displayID) else { return }
        _ = IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, 1.0)
        IOObjectRelease(service)
        refresh(displayID: displayID)
    }

    func restoreBrightness(for displayID: CGDirectDisplayID) {
        guard !isSandboxed else { return }
        guard let storedBrightness = storedBrightnessByDisplay.removeValue(forKey: displayID),
            let service = displayService(for: displayID)
        else { return }

        _ = IODisplaySetFloatParameter(
            service, 0, kIODisplayBrightnessKey as CFString, storedBrightness)
        IOObjectRelease(service)
        refresh(displayID: displayID)
    }

    private func brightnessDescription(for displayID: CGDirectDisplayID) -> String {
        guard let brightness = currentBrightness(for: displayID) else { return "Unavailable" }
        return "\(Int(brightness * 100))%"
    }

    private func currentBrightness(for displayID: CGDirectDisplayID) -> Float? {
        guard let service = displayService(for: displayID) else { return nil }
        defer { IOObjectRelease(service) }

        var brightness: Float = 0
        let result = IODisplayGetFloatParameter(
            service, 0, kIODisplayBrightnessKey as CFString, &brightness)
        guard result == kIOReturnSuccess else { return nil }
        return brightness
    }

    private func displayService(for displayID: CGDirectDisplayID) -> io_service_t? {
        let vendorID = CGDisplayVendorNumber(displayID)
        let productID = CGDisplayModelNumber(displayID)
        let serialNumber = CGDisplaySerialNumber(displayID)

        var iterator: io_iterator_t = 0
        let matchingResult = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        )

        guard matchingResult == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue()
            let dictionary = info as NSDictionary
            let candidateVendorID = dictionary[kDisplayVendorID] as? UInt32
            let candidateProductID = dictionary[kDisplayProductID] as? UInt32
            let candidateSerialNumber = dictionary[kDisplaySerialNumber] as? UInt32 ?? 0

            let matchesIdentity =
                candidateVendorID == vendorID
                && candidateProductID == productID
                && (serialNumber == 0 || candidateSerialNumber == serialNumber)

            if matchesIdentity {
                return service
            }

            IOObjectRelease(service)
        }

        return nil
    }

    private func detectSignalState(for displayID: CGDirectDisplayID) -> DisplaySignalState {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return .unavailable }

        let pixelEncoding = CGDisplayModeCopyPixelEncoding(mode)
            .map { String(describing: $0) } ?? "Unknown"
        let isYCbCr = pixelEncoding.contains("YCbCr") || pixelEncoding.contains("422") || pixelEncoding.contains("420")

        // Check for limited range via I/O flags — kDisplayModeNativeFlag or
        // kDisplayModeLimitedRangeFlag are hints. Also treat YCbCr as inherently
        // limited-range on many consumer displays.
        let ioFlags = CGDisplayModeGetIOFlags(mode)
        let limitedRangeFlag: UInt32 = 1 << 7 // kDisplayModeLimitedRangeFlag (not in public headers)
        let hasLimitedRangeFlag = (ioFlags & limitedRangeFlag) != 0
        let refreshRate = CGDisplayModeGetRefreshRate(mode)

        var descParts: [String] = []
        descParts.append(pixelEncoding)
        descParts.append(String(format: "%.1f Hz", refreshRate))
        if hasLimitedRangeFlag { descParts.append("Limited") }
        if isYCbCr { descParts.append("YCbCr") }

        return DisplaySignalState(
            pixelEncoding: pixelEncoding,
            signalDescription: descParts.joined(separator: " · "),
            limitedRangeLikely: hasLimitedRangeFlag || isYCbCr,
            ycbcrLikely: isYCbCr
        )
    }

    private func detectNightShift() -> PrivateFeatureState {
        guard !isSandboxed else { return .unavailable }
        let bundlePath = "/System/Library/PrivateFrameworks/CoreBrightness.framework"
        Bundle(path: bundlePath)?.load()

        guard let clientClass = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
            return .unavailable
        }

        let client = clientClass.init()
        return readBoolState(
            from: client,
            directKeys: ["enabled", "blueLightEnabled"],
            objectSelectors: ["status", "blueLightStatus"],
            nestedKeys: ["enabled", "active", "isEnabled"]
        )
    }

    private func detectTrueTone() -> PrivateFeatureState {
        guard !isSandboxed else { return .unavailable }
        let bundlePath = "/System/Library/PrivateFrameworks/CoreBrightness.framework"
        Bundle(path: bundlePath)?.load()

        let classNames = ["CBTrueToneClient", "CBClient"]
        for className in classNames {
            guard let clientClass = NSClassFromString(className) as? NSObject.Type else { continue }
            let client = clientClass.init()
            let state = readBoolState(
                from: client,
                directKeys: ["trueToneEnabled", "enabled"],
                objectSelectors: ["status", "trueToneStatus"],
                nestedKeys: ["enabled", "active", "isEnabled"]
            )

            if state != .unavailable {
                return state
            }
        }

        return .unavailable
    }

    private func readBoolState(
        from object: NSObject,
        directKeys: [String],
        objectSelectors: [String],
        nestedKeys: [String]
    ) -> PrivateFeatureState {
        for key in directKeys {
            if let state = boolState(forKey: key, on: object) {
                return state
            }
        }

        for selectorName in objectSelectors {
            let selector = NSSelectorFromString(selectorName)
            guard object.responds(to: selector),
                let unmanaged = object.perform(selector),
                let nestedObject = unmanaged.takeRetainedValue() as? NSObject
            else {
                continue
            }

            for key in nestedKeys {
                if let state = boolState(forKey: key, on: nestedObject) {
                    return state
                }
            }
        }

        return .unavailable
    }

    private func boolState(forKey key: String, on object: NSObject) -> PrivateFeatureState? {
        guard hasKVCReadableProperty(named: key, on: object) else {
            return nil
        }

        guard let value = safeValue(forKey: key, on: object) else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.boolValue ? .enabled : .disabled
        }

        if let value = value as? Bool {
            return value ? .enabled : .disabled
        }

        return nil
    }

    private var isSandboxed: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.security.app-sandbox" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        return (value as? Bool) == true
    }

    private func hasKVCReadableProperty(named key: String, on object: NSObject) -> Bool {
        var cls: AnyClass? = object_getClass(object)
        while let currentClass = cls {
            if class_getProperty(currentClass, key) != nil {
                return true
            }

            cls = class_getSuperclass(currentClass)
        }

        return false
    }

    private func safeValue(forKey key: String, on object: NSObject) -> Any? {
        object.value(forKey: key)
    }
}
