import AppKit

// The clip card's rendered view of a note body: headings, lists, quotes, code and inline
// emphasis, drawn line by line. Links are coloured but not live, so a stray click in the
// preview never opens a page. Only the first `limit` characters are drawn, to stay quick.
@MainActor enum MarkdownPreview {
    static let limit = 40_000

    static func render(_ markdown: String, limit: Int = limit, color: NSColor = .labelColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12.5)
        let shown = markdown.count > limit ? String(markdown.prefix(limit)) : markdown
        var fenced = false
        var first = true
        func paragraph(indent: CGFloat = 0, before: CGFloat = 0) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2.5; style.paragraphSpacing = 6; style.paragraphSpacingBefore = before
            style.headIndent = indent; style.firstLineHeadIndent = indent > 0 ? indent - 11 : 0
            return style
        }
        func add(_ text: NSAttributedString) {
            if !first { out.append(NSAttributedString(string: "\n")) }
            out.append(text); first = false
        }
        for raw in shown.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { fenced.toggle(); continue }
            if fenced {
                add(NSAttributedString(string: line.isEmpty ? " " : line, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: color.withAlphaComponent(0.85),
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06), .paragraphStyle: paragraph()]))
                continue
            }
            if trimmed.isEmpty { continue }
            if let heading = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                let level = heading.1.count
                let size: CGFloat = level == 1 ? 17 : level == 2 ? 15 : 13.5
                add(inline(String(heading.2), font: .systemFont(ofSize: size, weight: .semibold), color: color,
                           style: paragraph(before: first ? 0 : 6)))
            } else if let quote = trimmed.firstMatch(of: /^>\s?(.*)$/) {
                let text = NSMutableAttributedString(string: "▎", attributes: [.foregroundColor: RecordingPill.accent, .font: body])
                text.append(inline(" " + String(quote.1), font: body, color: color.withAlphaComponent(0.7), style: paragraph()))
                text.addAttribute(.paragraphStyle, value: paragraph(), range: NSRange(location: 0, length: text.length))
                add(text)
            } else if let item = line.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.*)$/) {
                let depth = CGFloat(item.1.count / 2)
                let marker = item.2.first?.isNumber == true ? String(item.2) : "•"
                let text = NSMutableAttributedString(string: marker + "\t", attributes: [.font: body, .foregroundColor: color.withAlphaComponent(0.55)])
                text.append(inline(String(item.3), font: body, color: color, style: paragraph()))
                let style = paragraph(indent: 16 + depth * 14)
                style.tabStops = [NSTextTab(textAlignment: .left, location: 16 + depth * 14)]
                text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
                add(text)
            } else if trimmed.wholeMatch(of: /([-*_]\s*){3,}/) != nil {
                add(NSAttributedString(string: String(repeating: "─", count: 24), attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor, .font: body, .paragraphStyle: paragraph()]))
            } else {
                add(inline(trimmed, font: body, color: color, style: paragraph()))
            }
        }
        if shown.count < markdown.count {
            add(NSAttributedString(string: "Preview shows the start of the note; Markdown has all of it.", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph(before: 6)]))
        }
        return out
    }

    // One line's inline Markdown: bold, italic, code, links (coloured, not clickable) and images (their alt text).
    static func inline(_ text: String, font: NSFont, color: NSColor, style: NSParagraphStyle) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        guard let parsed = try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes = base
            var piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                attributes[.font] = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
            }
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08)
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.imageURL != nil {
                piece = "▢ " + (piece.isEmpty ? "image" : piece)
                attributes[.foregroundColor] = NSColor.tertiaryLabelColor
            } else if run.link != nil {
                attributes[.foregroundColor] = RecordingPill.accent
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = RecordingPill.accent.withAlphaComponent(0.4)
            }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }

    // The line's words without Markdown marks (for "Copy plain text").
    nonisolated static func inlinePlain(_ text: String) -> String {
        guard let parsed = try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)) else { return text }
        return String(parsed.characters)
    }
}
