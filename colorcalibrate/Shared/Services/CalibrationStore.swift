//
//  CalibrationStore.swift
//  colorcalibrate
//
//  Created by Yukari Kaname on 3/22/26.
//

import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class CalibrationStore {
    var profiles: [CalibrationProfile]
    var settings: RecalibrationSettings

    private let defaults = UserDefaults.standard
    private let profileKey = "latestCalibrationProfiles"
    private let legacyProfileKey = "latestCalibrationProfile"
    private let settingsKey = "recalibrationSettings"

    init() {
        if let data = defaults.data(forKey: profileKey),
            let decodedProfiles = try? JSONDecoder().decode([CalibrationProfile].self, from: data)
        {
            profiles = decodedProfiles
        } else if let legacyData = defaults.data(forKey: legacyProfileKey),
            let legacyProfile = try? JSONDecoder().decode(CalibrationProfile.self, from: legacyData)
        {
            profiles = [legacyProfile]
        } else {
            profiles = []
        }

        if let data = defaults.data(forKey: settingsKey),
            let decoded = try? JSONDecoder().decode(RecalibrationSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = .default
        }
    }

    var latestProfile: CalibrationProfile? {
        profiles.max(by: { $0.createdAt < $1.createdAt })
    }

    func profile(for mode: DisplayDynamicRangeMode) -> CalibrationProfile? {
        profiles
            .filter { $0.dynamicRangeMode == mode }
            .max(by: { $0.createdAt < $1.createdAt })
    }

    var nextReminderDate: Date? {
        guard let baseDate = latestProfile?.createdAt else { return nil }
        return Calendar.current.date(byAdding: .day, value: settings.intervalDays, to: baseDate)
    }

    func save(profile: CalibrationProfile) {
        profiles.removeAll { $0.dynamicRangeMode == profile.dynamicRangeMode }
        profiles.append(profile)

        if let encoded = try? JSONEncoder().encode(profiles) {
            defaults.set(encoded, forKey: profileKey)
        }
        defaults.removeObject(forKey: legacyProfileKey)
    }

    func updateReminderInterval(days: Int) {
        settings.intervalDays = max(days, 7)
        if let encoded = try? JSONEncoder().encode(settings) {
            defaults.set(encoded, forKey: settingsKey)
        }
    }
}

enum RecalibrationScheduler {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
        }
    }

    static func scheduleReminder(afterDays days: Int) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Time to recalibrate your display"
        content.body =
            "A fresh reading keeps the calibrated preview aligned with the panel's current behavior."
        content.sound = .default

        let interval = max(TimeInterval(days * 86_400), 300)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: "recalibration-reminder", content: content, trigger: trigger)

        center.removePendingNotificationRequests(withIdentifiers: ["recalibration-reminder"])
        try? await center.add(request)
    }
}
