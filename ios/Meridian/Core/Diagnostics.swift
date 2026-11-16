//
//  Diagnostics.swift
//  Meridian — "why won't it connect" in one tap.
//
//  The status line can only say the phase. This probes both schemes against the
//  configured host and reports the real HTTP status or the URLSession error
//  domain/code, so a screenshot of the result is enough to tell a wrong path
//  from a blocked plaintext request from a rejected certificate.
//

import Foundation

enum Diagnostics {

    static func run(baseURL: String, allowSelfSigned: Bool) async -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "先填服务器地址" }

        // Register the host before probing: the run happens while the user is
        // still editing the field, and an unregistered host is exactly the case
        // where https fails with -1200 (TLS) even though the switch is on.
        // The switch value is passed in rather than assumed, so the probe tests
        // the configuration the user actually chose.
        let host = URLComponents(string: normalise(trimmed))?.host
        TrustingSession.shared.update(host: host, allowSelfSigned: allowSelfSigned)

        var lines: [String] = ["build \(BuildTag.build) · \(BuildTag.builtAt)"]

        for scheme in ["https", "http"] {
            guard let url = endpoint(trimmed, scheme: scheme) else {
                lines.append("\(scheme)：地址无法解析")
                continue
            }
            lines.append(await probe(url))
        }

        lines.append("本机时间 \(timestamp())")
        return lines.joined(separator: "\n")
    }

    private static func normalise(_ base: String) -> String {
        var trimmed = base
        let lower = trimmed.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func endpoint(_ base: String, scheme: String) -> URL? {
        guard var comps = URLComponents(string: normalise(base)) else { return nil }
        comps.scheme = scheme
        comps.query = nil
        comps.fragment = nil
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path + "/api/health"
        return comps.url
    }

    private static func probe(_ url: URL) async -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let started = Date()
        do {
            let (data, response) = try await TrustingSession.shared.client.data(for: request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data.prefix(80), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? ""
            return "\(url.absoluteString)\n  → HTTP \(code) · \(ms)ms · \(body)"
        } catch {
            let ns = error as NSError
            return "\(url.absoluteString)\n  → \(ns.domain) \(ns.code)：\(ns.localizedDescription)"
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
