//
//  UpdateInfo.swift
//  Meridian — what the server says the newest build is.
//
//  iOS does not allow an app to replace its own binary; there is no in-app
//  installer, signed or not. What an app *can* do is know that a newer build
//  exists, show its fingerprint, and hand the user a link that the installer
//  (TrollStore, AltStore, SideStore) will pick up. Keeping the file's md5 next
//  to the URL is what makes "did I actually get the new one" answerable.
//
//  The payload is served as a plain JSON file at:
//      <server>/meridian/files/version.json
//  so it needs no API change and can be read before the user has a token.
//

import Foundation

struct UpdateInfo: Codable, Equatable {
    var tag: String
    var bundleVersion: String
    var builtAt: String
    var url: String
    var md5: String
    var notes: String?

    /// Numeric comparison, not string: "100" must beat "99".
    var numericBuild: Int {
        Int(bundleVersion) ?? 0
    }
}
