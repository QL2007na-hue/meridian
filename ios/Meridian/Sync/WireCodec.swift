//
//  WireCodec.swift
//  Meridian — the HTTP/JSON plumbing shared by the sync engine.
//  OWNER: agenda/sync engineer.
//
//  Endpoints, coders and request shapes live in exactly one place so that a
//  backend change is one edit rather than a grep. Coders are built per call:
//  JSONDecoder is not documented as thread-safe and a fresh one costs nothing
//  next to a network round trip.
//

import Foundation

enum WireCodec {

    // MARK: - Paths

    /// Relative to the configured base URL. See docs/API.md.
    enum Path {
        static let snapshot = "api/v1/snapshot"
        /// SSE endpoint. Matches the backend route in docs/API.md §3.7 —
        /// `GET /api/v1/stream` (not `/events`).
        static let events = "api/v1/stream"
        static func task(_ id: String) -> String { "api/v1/tasks/\(id)" }
    }

    // MARK: - Coders

    /// The server sends `2026-11-15T21:30:00Z`: ISO 8601, no fractional seconds.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - URLs and requests

    /// `http://host:8787/` + `api/v1/snapshot` → one URL. Built by string
    /// concatenation on purpose: the base may carry a sub-path
    /// (`https://example.com/clock`) and `appendingPathComponent` would encode
    /// the slashes in the appended fragment.
    static func endpoint(_ config: ServerConfig, _ path: String) -> URL? {
        guard let base = config.endpoint?.absoluteString else { return nil }
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + "/" + path)
    }

    static func request(_ url: URL, method: String, token: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Bodies

    /// A full-state mutation. The server merges by `updatedAt`, so sending every
    /// field is safe and avoids tracking a dirty-field set in the UI.
    static func mutation(for task: AgendaTask, deleted: Bool? = nil) -> TaskMutation {
        TaskMutation(
            id: task.id,
            title: task.title,
            note: task.note,
            day: task.day,
            due: task.due,
            priority: task.priority.rawValue,
            isDone: task.isDone,
            updatedAt: task.updatedAt,
            deleted: deleted
        )
    }

    /// A tombstone carries nothing but the id and the instant that decided it.
    static func deletion(id: String, at date: Date = Date()) -> TaskMutation {
        TaskMutation(
            id: id,
            title: nil,
            note: nil,
            day: nil,
            due: nil,
            priority: nil,
            isDone: nil,
            updatedAt: date,
            deleted: true
        )
    }

    /// Shape of a `delete`/`removed` stream event.
    struct Tombstone: Codable {
        var id: String
        var updatedAt: Date?
    }
}
