import Foundation

/// Text subtitles rendered by the app (used with AVPlayer, which can't load sidecar files).
struct SubtitleCues {
    struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    private(set) var cues: [Cue]

    /// Parses WebVTT or SRT.
    init(text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = Self.parseTimestamp(parts[0]),
                  let end = Self.parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else {
                continue
            }
            let body = lines[(timingIndex + 1)...]
                .map(Self.stripTags)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !body.isEmpty {
                cues.append(Cue(start: start, end: end, text: body))
            }
        }
        self.cues = cues.sorted { $0.start < $1.start }
    }

    func text(at time: Double) -> String? {
        // Binary search for the last cue starting before `time`, then scan back for overlaps.
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var lines: [String] = []
        var index = low - 1
        while index >= 0, index >= low - 8 {
            let cue = cues[index]
            if cue.start <= time, time < cue.end {
                lines.insert(cue.text, at: 0)
            }
            index -= 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func parseTimestamp(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = value.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else {
            return nil
        }
        var seconds = 0.0
        for part in parts {
            guard let number = Double(part) else {
                return nil
            }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    private static func stripTags(_ line: String) -> String {
        var result = ""
        var inTag = false
        for character in line {
            if character == "<" {
                inTag = true
            } else if character == ">" {
                inTag = false
            } else if !inTag {
                result.append(character)
            }
        }
        // ASS-style override blocks like {\an8}.
        while let open = result.range(of: "{\\"), let close = result.range(of: "}", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
