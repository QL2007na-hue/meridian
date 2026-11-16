//
//  TrustingSession.swift
//  Meridian — a URLSession that can trust the user's own self-signed server.
//
//  The server is a personal box reached by IP (`https://192.168.1.10`), so its
//  certificate is self-signed: iOS would reject it and there is no domain to put
//  in an ATS exception either. Rather than asking every iPad to install a CA
//  profile, the app accepts the server trust — but only for the host the user
//  typed into settings, and only while the switch in 设置 → 服务器 is on. Every
//  other host keeps the default evaluation, so this is not a global "trust
//  anything" switch.
//

import Foundation

final class TrustingSession: NSObject, URLSessionDelegate {

    static let shared = TrustingSession()

    private let lock = NSLock()
    private var allowedHosts: Set<String> = []
    private var allowsSelfSigned = true

    /// One session, built once. Requests go through `TrustingSession.shared.client`
    /// instead of `URLSession.shared` so the delegate sees the TLS challenge.
    private(set) lazy var client: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Called whenever the server configuration changes.
    func update(host: String?, allowSelfSigned: Bool) {
        lock.lock()
        allowsSelfSigned = allowSelfSigned
        if let host = host?.lowercased(), !host.isEmpty {
            allowedHosts = [host]
        } else {
            allowedHosts = []
        }
        lock.unlock()
    }

    private func shouldTrust(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowsSelfSigned && allowedHosts.contains(host.lowercased())
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if shouldTrust(challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
