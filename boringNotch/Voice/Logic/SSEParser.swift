import Foundation

/// Reads server-sent events. Partial lines are buffered until their newline arrives.
struct SSEParser {
    private var buffer = ""

    /// Returns the complete `data:` payloads in `text`, minus the `[DONE]` marker.
    mutating func feed(_ text: String) -> [String] {
        buffer += text
        var lines = buffer.components(separatedBy: "\n")
        buffer = lines.removeLast()
        var payloads: [String] = []
        for raw in lines {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            payloads.append(payload)
        }
        return payloads
    }
}

/// Reads one streamed chat-completion payload.
enum CleanupStream {
    /// The content piece in `choices[0].delta.content`, or nil. An error frame carries no content.
    static func delta(_ payload: String) -> String? {
        guard !failed(payload) else { return nil }
        guard let json = object(payload),
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return nil }
        return content
    }

    /// True when the frame is a mid-stream provider failure: a top-level `error` object, or
    /// `choices[0].finish_reason` set to `error`. OpenRouter sends these inside a 200 stream.
    static func failed(_ payload: String) -> Bool {
        guard let json = object(payload) else { return false }
        if json["error"] != nil { return true }
        return finishReason(payload) == "error"
    }

    /// `choices[0].finish_reason` when the frame sets one, or nil.
    static func finishReason(_ payload: String) -> String? {
        guard let json = object(payload),
              let choices = json["choices"] as? [[String: Any]],
              let reason = choices.first?["finish_reason"] as? String
        else { return nil }
        return reason
    }

    /// Token counts from the final usage chunk, or nil.
    static func usage(_ payload: String) -> (prompt: Int, completion: Int)? {
        guard let json = object(payload),
              let usage = json["usage"] as? [String: Any],
              let prompt = usage["prompt_tokens"] as? Int,
              let completion = usage["completion_tokens"] as? Int
        else { return nil }
        return (prompt, completion)
    }

    private static func object(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
