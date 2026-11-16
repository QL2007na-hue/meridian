//
//  BuildTag.swift
//  Meridian — which build is actually running.
//
//  Bumped by hand (and by the build script) every time a package is published,
//  because "is this the new one?" was the question that cost a whole round of
//  debugging: two different IPAs shared one download name.
//

import Foundation

enum BuildTag {
    static let version = "1.0.0"
    static let build = "r22"
    static let builtAt = "2026-11-16 20:30"

    /// CFBundleVersion, injected by CI from the run number. Two IPAs with the
    /// same bundle version look identical to iOS, and a reinstall can silently
    /// leave the old binary in place — which is how a device kept reporting an
    /// older build than the one it had just been handed.
    static var bundleVersion: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    static var label: String { "\(version) · \(build) · b\(bundleVersion)" }
}
