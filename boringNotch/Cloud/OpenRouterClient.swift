import Foundation

/// The only file in the app that talks to the network. Audio and transcript text leave the Mac here,
/// only to openrouter.ai, and only when the caller holds the strict key (see the single gate in
/// VoiceDictationManager). Nothing in this file logs, prints or stores what it sends or receives.
final class OpenRouterClient {
    struct Transcript {
        let text: String
        let seconds: Double
        let costUSD: Double
    }

    enum CleanupEvent {
        case delta(String)
        case usage(prompt: Int, completion: Int)
    }

    enum Failure: Error {
        case http(Int)
        case zdrBlocked
        case timeout
        case decode
        case cancelled
    }

    private let key: String
    private let session: URLSession

    init(key: String) {
        self.key = key
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// One-shot speech-to-text: the WAV goes as base64 JSON, the dictionary rides along as the prompt.
    func transcribe(wav: Data, model: String, prompt: String?, timeout: TimeInterval) async throws -> Transcript {
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": wav.base64EncodedString(), "format": "wav"],
        ]
        if let prompt { body["prompt"] = prompt }
        var request = try makeRequest(path: "audio/transcriptions", timeout: timeout)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.decode }
        guard http.statusCode == 200 else { throw Self.httpFailure(status: http.statusCode, body: data) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else { throw Failure.decode }
        let usage = json["usage"] as? [String: Any]
        return Transcript(
            text: text,
            seconds: usage?["seconds"] as? Double ?? -1,
            costUSD: usage?["cost"] as? Double ?? -1
        )
    }

    /// Streaming chat completion. Yields each content piece as it arrives, then one usage event.
    func streamCleanup(model: String, system: String, user: String, maxTokens: Int, timeout: TimeInterval) -> AsyncThrowingStream<CleanupEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "temperature": 0,
                        "max_tokens": maxTokens,
                        "stream_options": ["include_usage": true],
                        "messages": [
                            ["role": "system", "content": system],
                            ["role": "user", "content": user],
                        ],
                    ]
                    var request = try self.makeRequest(path: "chat/completions", timeout: timeout)
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw Failure.decode }
                    guard http.statusCode == 200 else {
                        var errorBody = Data()
                        for try await byte in bytes.prefix(4096) { errorBody.append(byte) }
                        throw Self.httpFailure(status: http.statusCode, body: errorBody)
                    }

                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for payload in parser.feed(line + "\n") {
                            if let piece = CleanupStream.delta(payload) {
                                continuation.yield(.delta(piece))
                            }
                            if let usage = CleanupStream.usage(payload) {
                                continuation.yield(.usage(prompt: usage.prompt, completion: usage.completion))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(path: String, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: "https://openrouter.ai/api/v1/" + path) else { throw Failure.decode }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return request
    }

    private static func httpFailure(status: Int, body: Data) -> Failure {
        // The strict key's zero-data-retention guardrail answers 404 with "guardrail" in the body.
        if status == 404, String(decoding: body, as: UTF8.self).contains("guardrail") {
            return .zdrBlocked
        }
        return .http(status)
    }

    private static func map(_ error: Error) -> Error {
        if let failure = error as? Failure { return failure }
        if error is CancellationError { return Failure.cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return Failure.timeout
            case .cancelled: return Failure.cancelled
            default: return urlError
            }
        }
        return error
    }
}
