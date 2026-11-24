import Foundation

/// Helpers for very large JSON-lines files: find lines by a literal, then pull out only the
/// small pieces needed, instead of decoding whole lines that can be hundreds of kilobytes.
public enum JSONLScanner {
    /// Calls `body` with each complete line (newline excluded) and returns the number of bytes
    /// consumed, which ends after the last newline; a trailing partial line is left for later.
    @discardableResult
    public static func forEachLine(in data: Data, _ body: (Data) -> Void) -> Int {
        var consumed = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            let count = buffer.count
            while start < count {
                guard let found = memchr(base + start, 0x0A, count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(found))
                if end > start {
                    body(data.subdata(in: data.startIndex + start..<data.startIndex + end))
                }
                start = end + 1
                consumed = start
            }
        }
        return consumed
    }

    /// Like `forEachLine`, but only hands over lines containing one of `markers`, with where
    /// each marker first appears in the line (`hits[i]` for `markers[i]`, nil when absent) so a
    /// parser can start there instead of searching the line again. The search runs over the
    /// whole buffer, so lines without a marker are never copied or examined; in transcripts
    /// that is most of the data.
    ///
    /// Each pass is a vectorised `memmem`/`memchr`: one per marker, then one sweep over the
    /// newlines up to the hits to find where their lines start. The line handed over shares
    /// the buffer's memory and is only valid during the call; copy it to keep it.
    @discardableResult
    public static func forEachLine(containing markers: [String], in data: Data, _ body: (_ line: Data, _ hits: [Int?]) -> Void) -> Int {
        let needles = markers.map { Array($0.utf8) }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress, let finalNewline = Self.lastNewline(in: base, before: buffer.count) else { return 0 }
            let end = finalNewline + 1
            func newline(from start: Int, before limit: Int) -> Int? {
                memchr(base + start, 0x0A, limit - start).map { base.distance(to: UnsafeRawPointer($0)) }
            }

            // Every marker's first hit in each line, in buffer order.
            var hits: [(position: Int, marker: Int)] = []
            for (marker, needle) in needles.enumerated() where !needle.isEmpty {
                var offset = 0
                while offset < end, let hit = needle.withUnsafeBytes({ memmem(base + offset, end - offset, $0.baseAddress, needle.count) }) {
                    let position = base.distance(to: UnsafeRawPointer(hit))
                    hits.append((position, marker))
                    // A line counts once per marker: carry on after it.
                    offset = (newline(from: position, before: end) ?? end) + 1
                }
            }
            if hits.isEmpty { return end }
            hits.sort { $0.position < $1.position }

            var cursor = 0  // a line start at or before the next hit
            var line: Range<Int>?
            var found = [Int?](repeating: nil, count: needles.count)
            func flush() {
                guard let range = line else { return }
                let pointer = UnsafeMutableRawPointer(mutating: base + range.lowerBound)
                body(Data(bytesNoCopy: pointer, count: range.count, deallocator: .none), found)
                found = [Int?](repeating: nil, count: needles.count)
            }
            for hit in hits {
                if let range = line, range.contains(hit.position) {
                    if found[hit.marker] == nil { found[hit.marker] = hit.position - range.lowerBound }
                    continue
                }
                flush()
                var start = cursor
                while let next = newline(from: start, before: hit.position) { start = next + 1 }
                let stop = newline(from: hit.position, before: end) ?? end
                line = start..<stop
                found[hit.marker] = hit.position - start
                cursor = stop + 1
            }
            flush()
            return end
        }
    }

    /// The offset of the last newline before `position` (macOS has no memrchr). Used only on
    /// the trailing partial line of a buffer.
    private static func lastNewline(in base: UnsafeRawPointer, before position: Int) -> Int? {
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var index = position - 1
        while index >= 0 {
            if bytes[index] == 0x0A { return index }
            index -= 1
        }
        return nil
    }

    public static func contains(_ line: Data, _ needle: String) -> Bool {
        range(of: Array(needle.utf8), in: line, last: false) != nil
    }

    /// The string after a literal marker such as `"aiTitle":"`, up to its closing quote,
    /// with JSON escapes decoded.
    public static func string(after marker: String, in line: Data, last: Bool = false) -> String? {
        string(after: marker, in: line, within: nil, last: last)
    }

    /// Like `string(after:in:last:)`, looking for the marker only within `window` (byte offsets).
    public static func string(after marker: String, in line: Data, within window: Range<Int>?, last: Bool = false) -> String? {
        guard let start = range(of: Array(marker.utf8), in: line, within: window, last: last)?.upperBound else { return nil }
        return line.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> String? in
            var index = start
            var escaped = false
            while index < buffer.count {
                let byte = buffer[index]
                if escaped {
                    escaped = false
                } else if byte == 0x5C {  // backslash
                    escaped = true
                } else if byte == 0x22 {  // closing quote
                    let raw = UnsafeRawBufferPointer(rebasing: buffer[start..<index])
                    // Most values have no escapes; only those need a JSON decoder.
                    guard raw.contains(0x5C) else { return String(decoding: raw, as: UTF8.self) }
                    let quoted = Data([0x22]) + Data(raw) + Data([0x22])
                    return (try? JSONDecoder().decode(String.self, from: quoted)) ?? String(decoding: raw, as: UTF8.self)
                }
                index += 1
            }
            return nil
        }
    }

    /// The JSON object that follows `"key":`, with its braces balanced, decoded as a dictionary.
    public static func object(forKey key: String, in line: Data, last: Bool = false) -> [String: Any]? {
        guard let start = range(of: Array("\"\(key)\":{".utf8), in: line, last: last)?.upperBound else { return nil }
        return object(openingAt: start - 1, in: line)
    }

    /// The JSON object whose opening brace is at byte `open`, decoded as a dictionary.
    public static func object(openingAt open: Int, in line: Data) -> [String: Any]? {
        return line.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [String: Any]? in
            guard open >= 0, open < buffer.count, buffer[open] == 0x7B else { return nil }
            var depth = 0
            var inString = false
            var escaped = false
            var index = open
            while index < buffer.count {
                let byte = buffer[index]
                if inString {
                    if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B {
                    depth += 1
                } else if byte == 0x7D {
                    depth -= 1
                    if depth == 0 {
                        let slice = Data(buffer[open...index])
                        return (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any]
                    }
                }
                index += 1
            }
            return nil
        }
    }

    /// Byte offsets of the first (or last) occurrence of `needle`, using memmem.
    static func range(of needle: [UInt8], in data: Data, last: Bool) -> Range<Int>? {
        range(of: needle, in: data, within: nil, last: last)
    }

    /// Byte offsets of the first (or last) occurrence of `needle` inside `window`, using memmem.
    static func range(of needle: [UInt8], in data: Data, within window: Range<Int>?, last: Bool) -> Range<Int>? {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Range<Int>? in
            let lower = max(0, window?.lowerBound ?? 0), upper = min(buffer.count, window?.upperBound ?? buffer.count)
            guard let base = buffer.baseAddress, !needle.isEmpty, upper - lower >= needle.count else { return nil }
            var result: Range<Int>?
            var offset = lower
            while offset <= upper - needle.count {
                guard let found = needle.withUnsafeBytes({ memmem(base + offset, upper - offset, $0.baseAddress, needle.count) })
                else { break }
                let position = base.distance(to: UnsafeRawPointer(found))
                result = position..<position + needle.count
                if !last { break }
                offset = position + 1
            }
            return result
        }
    }

    /// The last occurrence of `needle` that ends at or before `limit`, searching backwards
    /// from there. For a value known to sit just before a marker, this reads only the bytes
    /// in between instead of the whole line.
    public static func lastRange(of needle: String, in data: Data, before limit: Int) -> Range<Int>? {
        let needle = Array(needle.utf8)
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Range<Int>? in
            let limit = min(limit, buffer.count)
            guard !needle.isEmpty, limit >= needle.count, let first = needle.first else { return nil }
            var index = limit - needle.count
            while index >= 0 {
                if buffer[index] == first, memcmp(buffer.baseAddress! + index, needle, needle.count) == 0 {
                    return index..<index + needle.count
                }
                index -= 1
            }
            return nil
        }
    }
}
