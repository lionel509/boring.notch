//
//  HomelabQuery.swift
//  boringNotch
//
//  Talking to Prometheus and Loki, and reducing what comes back to strings a row can hold.
//

import Foundation

/// Split out of `HomelabManager` purely for size: the state machine and the wire format
/// are separate concerns and neither file should have to be scrolled to read the other.
@MainActor
extension HomelabManager {
    // MARK: - Transport

    struct Sample { let labels: [String: String]; let value: Double }

    func lokiVector(_ base: URL, _ query: String) async throws -> [Sample] {
        var components = URLComponents(url: base.appendingPathComponent("loki/api/v1/query"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        return try await vector(at: components, key: "metric")
    }

    func vector(at components: URLComponents, key: String) async throws -> [Sample] {
        let object = try await json(components)
        guard let data = object["data"] as? [String: Any],
              let result = data["result"] as? [[String: Any]]
        else { throw URLError(.cannotParseResponse) }
        return result.compactMap { entry in
            guard let labels = entry[key] as? [String: String],
                  let pair = entry["value"] as? [Any],
                  let text = pair.last as? String, let value = Double(text)
            else { return nil }
            return Sample(labels: labels, value: value)
        }
    }

    func streams(_ base: URL, _ query: String, limit: Int, hours: Int) async throws -> [AlertLine] {
        var components = URLComponents(url: base.appendingPathComponent("loki/api/v1/query_range"),
                                       resolvingAgainstBaseURL: false)!
        let start = Date().addingTimeInterval(-Double(hours) * 3600).timeIntervalSince1970
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "direction", value: "backward"),
            URLQueryItem(name: "start", value: String(Int64(start)) + "000000000"),
        ]
        let object = try await json(components)
        guard let data = object["data"] as? [String: Any],
              let result = data["result"] as? [[String: Any]]
        else { throw URLError(.cannotParseResponse) }

        var lines: [AlertLine] = []
        for stream in result {
            let labels = stream["stream"] as? [String: String] ?? [:]
            for pair in (stream["values"] as? [[String]] ?? []) {
                guard pair.count == 2, let nanoseconds = Double(pair[0]) else { continue }
                lines.append(AlertLine(
                    id: pair[0],
                    date: Date(timeIntervalSince1970: nanoseconds / 1_000_000_000),
                    level: labels["level"] ?? labels["detected_level"] ?? "WARN",
                    host: labels["host"] ?? "",
                    text: Self.summarise(pair[1], check: labels["check"])))
            }
        }
        // Loki orders within a stream, not across them, so the merge has to happen here.
        return Array(lines.sorted { $0.date > $1.date }.prefix(limit))
    }

    func json(_ components: URLComponents) async throws -> [String: Any] {
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw URLError(.cannotParseResponse) }
        return object
    }

    // MARK: - Formatting

    /// The custom scripts log JSON; journald ships plain text. Unwrap the first into
    /// `check: detail` and pass the second through, so one row renders both.
    static func summarise(_ line: String, check: String?) -> String {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? String
        else { return line }
        guard let check = check ?? object["check"] as? String else { return detail }
        return "\(check): \(detail)"
    }

    static func base(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if !text.contains("://") { text = "http://" + text }
        return URL(string: text)
    }

    static func reason(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .timedOut: "timed out"
        case .cannotConnectToHost, .cannotFindHost: "unreachable"
        case .badServerResponse: "rejected the query"
        case .cannotParseResponse: "unreadable reply"
        default: (error as NSError).localizedDescription
        }
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "--" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func bytes(_ value: Double?) -> String {
        guard let value else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    /// Compact enough for a 15 pt row: `4s`, `12m`, `3h`, `2d`.
    static func age(since date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        return switch seconds {
        case ..<60: "\(Int(seconds))s"
        case ..<3600: "\(Int(seconds / 60))m"
        case ..<86400: "\(Int(seconds / 3600))h"
        default: "\(Int(seconds / 86400))d"
        }
    }
}

@MainActor
extension HomelabManager {
    /// The one sentence a panel shows when it has nothing to draw, and whether that is a
    /// failure or just an empty configuration. Nil means both sources are answering and the
    /// panel's own emptiness is the thing worth saying.
    var sourceProblem: (failed: Bool, message: String)? {
        switch (prometheus, loki) {
        case (.unset, .unset):
            (false, "Set the Prometheus and Loki URLs in Settings")
        case (.failed(let prom), .failed(let logs)):
            (true, "Prometheus \(prom), Loki \(logs)")
        case (.failed(let prom), _):
            (true, "Prometheus \(prom)")
        case (_, .failed(let logs)):
            (true, "Loki \(logs)")
        default:
            nil
        }
    }
}
