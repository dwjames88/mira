import Foundation

/// A small block-level reading of release-note markdown (headings, bullets, paragraphs). Inline markup
/// (`code`, **bold**, links) is left in the text for `AttributedString(markdown:)` to render.
public enum ReleaseNotes {
    public enum Block: Equatable, Sendable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    public static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(text)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if let last = blocks.last, paragraph.isEmpty, case .bullet(let text) = last, rawLine.hasPrefix("  ") {
                // A wrapped continuation of the previous bullet.
                blocks[blocks.count - 1] = .bullet(text + " " + line)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// The notes worth showing in an update window: everything before the install boilerplate
    /// (`## Install ...`) that `scripts/release.sh` appends for first-time downloads.
    public static func updateNotes(from markdown: String) -> String {
        var kept: [Substring] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            if lower.hasPrefix("## install") { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
