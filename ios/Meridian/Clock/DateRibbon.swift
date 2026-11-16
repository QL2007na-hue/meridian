//
//  DateRibbon.swift
//  Meridian — the date line, in three registers.
//
//  One component for every place a date appears: the rail at the top of the
//  glass (stacked), a crumb sharing the time's own baseline (inline), and
//  nothing at all (minimal). The stage style selects the register, so a date is
//  never formatted twice in two different shapes on one screen.
//
//  Formatters are static: formatting runs on every minute tick, and building a
//  DateFormatter per tick is the classic way a clock app burns power for no
//  visible reason.
//

import Foundation
import SwiftUI

// MARK: - Lunar

/// Chinese lunar month and day, read from Foundation's Chinese calendar.
///
/// Only the number-to-character mapping lives here. The astronomy stays in
/// `Calendar(identifier: .chinese)` — hand-rolling a lunisolar conversion is how
/// a clock ends up a day off on 十五.
enum LunarDate {
    static func text(for date: Date) -> String {
        var calendar = Calendar(identifier: .chinese)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.month, .day], from: date)
        return monthName(parts.month ?? 1) + dayName(parts.day ?? 1)
    }

    private static let months = [
        "正月", "二月", "三月", "四月", "五月", "六月",
        "七月", "八月", "九月", "十月", "冬月", "腊月"
    ]

    private static let decades = ["初", "十", "廿", "三"]
    private static let units = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

    static func monthName(_ month: Int) -> String {
        guard month >= 1, month <= months.count else { return "" }
        return months[month - 1]
    }

    static func dayName(_ day: Int) -> String {
        guard day >= 1, day <= 30 else { return "" }
        switch day {
        case 10: return "初十"
        case 20: return "二十"
        case 30: return "三十"
        default:
            return decades[(day - 1) / 10] + units[(day - 1) % 10]
        }
    }
}

// MARK: - Ribbon

/// The date line, in the register the stage style asks for: a full rail across
/// the top, a crumb on the numerals' baseline, or nothing. One component instead
/// of three near-identical ones keeps the date phrasing identical everywhere.
struct DateRibbon: View {
    let date: Date
    /// Picks the register: rail, inline crumb, or nothing.
    var style: AppSettings.ClockStyle = .stacked
    /// Point size of the labels. 11 in the rail; on the time's baseline the
    /// stage passes something proportional to the numerals instead.
    var size: CGFloat = 11
    var showsYear: Bool = false
    var showsLunar: Bool = true
    var showsTimeZone: Bool = true

    /// The rail is a micro label and takes the positive tracking that goes with
    /// one; the inline crumb is 40% larger and would drift apart at 1.6.
    private var tracking: CGFloat { style == .inline ? size * 0.06 : 1.6 }
    private var gap: CGFloat { size * 0.6 }

    var body: some View {
        Group {
            switch style {
            case .stacked: rail
            case .inline: crumb
            case .minimal: EmptyView()
            }
        }
    }

    /// Full-width row: date on the left, the sky and the zone on the right.
    private var rail: some View {
        HStack(alignment: .firstTextBaseline, spacing: gap) {
            label(weekdayText).foregroundStyle(Palette.inkSecondary)
            separator
            label(dayText).foregroundStyle(Palette.inkSecondary)

            Spacer(minLength: Space.m)

            if showsLunar {
                label(LunarDate.text(for: date)).foregroundStyle(Palette.inkTertiary)
            }
            if showsLunar && showsTimeZone {
                separator
            }
            if showsTimeZone {
                label(Self.timeZoneLabel(for: date)).foregroundStyle(Palette.inkTertiary)
            }
        }
        .textCase(.uppercase)
    }

    /// Compact form that sits on the numerals' baseline and stays out of their way.
    private var crumb: some View {
        HStack(alignment: .firstTextBaseline, spacing: gap) {
            label(weekdayText).foregroundStyle(Palette.inkTertiary)
            separator
            label(dayText).foregroundStyle(Palette.inkTertiary)
        }
    }

    private func label(_ text: String) -> Text {
        Text(text)
            .font(Typeface.digit(size, weight: .medium))
            .tracking(tracking)
    }

    private var separator: some View {
        Text("·")
            .font(Typeface.digit(size, weight: .medium))
            .foregroundStyle(Palette.inkQuaternary)
    }

    // MARK: Text

    private var weekdayText: String {
        let formatter = Self.weekdayFormatter
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private var dayText: String {
        let formatter = showsYear ? Self.dayWithYearFormatter : Self.dayFormatter
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// "GMT+8", or "GMT+5:30" where the offset is not a whole hour. Computed
    /// from the offset rather than the abbreviation: "CST" is three zones.
    /// `secondsFromGMT(for:)` rather than the current offset, so a session left
    /// running across a DST change relabels itself.
    static func timeZoneLabel(for date: Date = Date()) -> String {
        let offset = TimeZone.current.secondsFromGMT(for: date)
        let hours = offset / 3600
        let minutes = abs(offset % 3600) / 60
        let sign = offset < 0 ? "-" : "+"
        let core = "GMT\(sign)\(abs(hours))"
        return minutes == 0 ? core : core + String(format: ":%02d", minutes)
    }

    // MARK: Formatters

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let dayWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}
