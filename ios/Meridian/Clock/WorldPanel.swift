//
//  WorldPanel.swift
//  Meridian — four cities, one glance.
//
//  A row per city: a day/night dot, the name, the date delta and the local time.
//  Rows are separated by hairlines, not by cards inside cards — nesting surfaces
//  is how a calm panel turns into a dashboard.
//
//  Refreshes once a minute. A world clock has no seconds, so nothing here is
//  allowed to wake up at 1 Hz.
//

import Foundation
import SwiftUI

/// Four cities, one row each, separated by hairlines. Chosen for the person
/// watching a market open somewhere and a team waking up somewhere else: the
/// delta is the interesting number, so it sits right next to the time.
struct WorldPanel: View {
    @EnvironmentObject private var model: AppModel

    private struct City: Identifiable {
        let id: String
        let name: String
        let zone: String
    }

    private static let cities = [
        City(id: "beijing", name: "北京", zone: "Asia/Shanghai"),
        City(id: "newyork", name: "纽约", zone: "America/New_York"),
        City(id: "london", name: "伦敦", zone: "Europe/London"),
        City(id: "tokyo", name: "东京", zone: "Asia/Tokyo")
    ]

    var body: some View {
        MeridianCard(padding: Space.l) {
            TimelineView(.everyMinute) { context in
                VStack(spacing: 0) {
                    ForEach(Self.cities) { city in
                        row(city, now: context.date)
                        if city.id != Self.cities.first?.id {
                            Hairline()
                        }
                    }
                }
            }
        }
    }

    // MARK: Row

    private func row(_ city: City, now: Date) -> some View {
        let zone = TimeZone(identifier: city.zone) ?? .current
        let delta = Self.dayOffset(now, zone: zone)

        return HStack(spacing: Space.s) {
            Circle()
                .fill(Self.isDaytime(now, zone: zone) ? Palette.ember : Palette.inkQuaternary)
                .frame(width: 5, height: 5)

            Text(city.name)
                .font(Typeface.body)
                .foregroundStyle(Palette.inkSecondary)

            Spacer(minLength: Space.s)

            Text(Self.deltaText(delta))
                .font(Typeface.micro)
                .tracking(1.0)
                .foregroundStyle(Palette.inkQuaternary)

            Text(Self.timeText(now, zone: zone, use24Hour: model.settings.use24Hour))
                .font(Typeface.digit(17, weight: .regular))
                .tracking(0.5)
                .foregroundStyle(Palette.ink)
        }
        .frame(height: Metrics.rowHeight)
    }

    // MARK: Derived

    /// Day runs 06:00–18:00 local. One dot is enough: a sun and a moon would be
    /// two more symbols than this row needs.
    private static func isDaytime(_ date: Date, zone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        return hour >= 6 && hour < 18
    }

    private static func deltaText(_ delta: Int) -> String {
        if delta > 0 { return "+1" }
        if delta < 0 { return "-1" }
        return "今天"
    }

    /// Calendar-day difference between the city and the device. Reducing each
    /// day to a noon-UTC stamp makes month and year boundaries stop mattering.
    private static func dayOffset(_ date: Date, zone: TimeZone) -> Int {
        dayStamp(date, zone: zone) - dayStamp(date, zone: .current)
    }

    private static func dayStamp(_ date: Date, zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        var stamp = DateComponents()
        stamp.year = parts.year
        stamp.month = parts.month
        stamp.day = parts.day
        stamp.hour = 12

        guard let day = utc.date(from: stamp) else { return 0 }
        return Int((day.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    private static func timeText(_ date: Date, zone: TimeZone, use24Hour: Bool) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)

        let raw = parts.hour ?? 0
        let hour = use24Hour ? raw : (raw % 12 == 0 ? 12 : raw % 12)
        return String(format: "%02d:%02d", hour, parts.minute ?? 0)
    }
}
