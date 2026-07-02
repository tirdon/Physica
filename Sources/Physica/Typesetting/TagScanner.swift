// TagScanner — minimal markup scanner (opening/closing tags + attributes, skips
// text/comments/doctype) used by MathSVG to walk MathJax output. See MathSVG.swift.

// MARK: - Tag scanner

/// Minimal markup scanner: yields opening/closing tags with attributes,
/// skips text content, comments, <!doctype> and <?...?> blocks.
import PhysicaMath
import PhysicaGeometry

struct TagScanner {
    struct Tag {
        var name: String
        var attributes: [String: String] = [:]
        var isClosing = false
        var isSelfClosing = false
    }

    private let bytes: [UInt8]
    private var index = 0

    init(_ markup: String) {
        bytes = Array(markup.utf8)
    }

    mutating func nextTag() -> Tag? {
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            index += 1
            if matches("!--") {
                skip(past: "-->")
                continue
            }
            if peek() == UInt8(ascii: "!") || peek() == UInt8(ascii: "?") {
                skip(past: ">")
                continue
            }

            var tag = Tag(name: "")
            if peek() == UInt8(ascii: "/") {
                tag.isClosing = true
                index += 1
            }
            tag.name = readName()
            if tag.isClosing {
                skip(past: ">")
                return tag
            }

            while index < bytes.count {
                skipWhitespace()
                guard let byte = peek() else { break }
                if byte == UInt8(ascii: ">") {
                    index += 1
                    break
                }
                if byte == UInt8(ascii: "/") {
                    tag.isSelfClosing = true
                    index += 1
                    continue
                }
                let attribute = readName()
                guard !attribute.isEmpty else {
                    index += 1
                    continue
                }
                skipWhitespace()
                guard peek() == UInt8(ascii: "=") else {
                    tag.attributes[attribute] = ""
                    continue
                }
                index += 1
                skipWhitespace()
                guard let quote = peek(),
                    quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'")
                else { continue }
                index += 1
                let start = index
                while index < bytes.count, bytes[index] != quote { index += 1 }
                tag.attributes[attribute] = String(decoding: bytes[start..<index], as: UTF8.self)
                if index < bytes.count { index += 1 }
            }
            return tag
        }
        return nil
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func matches(_ text: String) -> Bool {
        let pattern = Array(text.utf8)
        guard index + pattern.count <= bytes.count else { return false }
        return Array(bytes[index..<index + pattern.count]) == pattern
    }

    private mutating func skip(past terminator: String) {
        let pattern = Array(terminator.utf8)
        while index < bytes.count {
            if matches(terminator) {
                index += pattern.count
                return
            }
            index += 1
        }
    }

    private mutating func skipWhitespace() {
        while let byte = peek(),
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
                || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
        {
            index += 1
        }
    }

    /// Tag/attribute name: letters, digits, ':', '-', '_'.
    private mutating func readName() -> String {
        let start = index
        while let byte = peek() {
            let isLetter = (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            let isDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            let isPunctuation = byte == UInt8(ascii: ":") || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
            guard isLetter || isDigit || isPunctuation else { break }
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}
