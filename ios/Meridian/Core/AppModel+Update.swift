//
//  AppModel+Update.swift
//  Meridian — the update check. OWNER: lead.
//
//  Deliberately modest: it reads one static JSON file, compares build numbers
//  and stores the result. It never downloads, never installs, never asks for a
//  password. The actual install stays with TrollStore / AltStore, which is the
//  only component that can legally replace a signed binary on this platform.
//
//  Robustness rules, because this runs on a clock that may be on a wall for
//  weeks:
//    · 8s timeout, one attempt, no retry storm
//    · any failure is silent and leaves the previous result alone
//    · a build is only "available" when its number is strictly greater
//    · the URL must be http(s); anything else is ignored rather than opened
//

import Foundation
import UIKit

extension AppModel {

    /// Fetches `<server>/meridian/files/version.json`. Safe to call on launch and
    /// from the settings row; concurrent calls are collapsed by a timestamp.
    func checkForUpdate(force: Bool = false) {
        guard let url = WireCodec.endpoint(config, "files/version.json") else {
            return
        }
        if !force, let last = updateCheckedAt, Date().timeIntervalSince(last) < 60 {
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.updateCheckedAt = Date() }

            do {
                let (data, response) = try await TrustingSession.shared.client.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    return
                }
                let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
                guard let link = URL(string: info.url),
                      let scheme = link.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    return
                }
                let running = Int(BuildTag.bundleVersion) ?? 0
                self.availableUpdate = info.numericBuild > running ? info : nil
            } catch {
                // Offline, wrong address, older server without the file: all of
                // these mean "no information", never "you are up to date".
                return
            }
        }
    }

    /// Opens the download page. The installer takes over from there.
    func openUpdate(_ info: UpdateInfo) {
        guard let url = URL(string: info.url) else { return }
        UIApplication.shared.open(url)
    }

    /// One line for the settings row.
    func updateNote() -> String {
        if let update = availableUpdate {
            return "有新版本 \(update.tag)（b\(update.bundleVersion)）· 数据会保留"
        }
        guard config.isConfigured else { return "填好服务器地址后可检查更新" }
        if updateCheckedAt == nil { return "尚未检查" }
        return "已是最新"
    }
}
