import SwiftUI
import AppKit

/// Foundation parses Markdown; AppKit lays out the resulting native, selectable text.
/// Images and HTML are never loaded, so a saved note cannot fetch remote resources.
@MainActor enum ReviewMarkdown {
    private struct Block {
        var intents: [PresentationIntent.IntentType]
        var text = NSMutableAttributedString(string: "")
    }
    static func render(_ source: String) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
        }
        var blocks: [Block] = []
        for run in parsed.runs {
            let intents = run.presentationIntent?.components ?? []
            if blocks.isEmpty || blocks.last?.intents.first?.identity != intents.first?.identity { blocks.append(Block(intents: intents)) }
            let inline = run.inlinePresentationIntent ?? []
            var font = baseFont(intents)
            if inline.contains(.code) { font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
            if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if inline.contains(.code) { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
            if let url = run.link { attributes[.link] = url }
            let text = inline.contains(.softBreak) ? "\u{2028}" : String(parsed[run.range].characters)
            blocks[blocks.count - 1].text.append(NSAttributedString(string: text, attributes: attributes))
        }
        let output = NSMutableAttributedString(string: "")
        var previousListItem: Int?
        var tables: [Int: NSTextTable] = [:]
        for block in blocks {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4; paragraph.paragraphSpacing = 10
            let content = NSMutableAttributedString(attributedString: block.text)
            var listItem: PresentationIntent.IntentType?
            var depth = 0, ordered = false, quote = false, code = false, heading = false
            var table: (Int, [PresentationIntent.TableColumn])?
            var row = 0, column = 0, headerRow = false
            for intent in block.intents {
                switch intent.kind {
                case .header: heading = true
                case .listItem: if listItem == nil { listItem = intent }
                case .orderedList: if depth == 0 { ordered = true }; depth += 1
                case .unorderedList: depth += 1
                case .blockQuote: quote = true
                case .codeBlock: code = true
                case .table(let columns): table = (intent.identity, columns)
                case .tableCell(let index): column = index
                case .tableRow(let index): row = index
                case .tableHeaderRow: headerRow = true
                default: break
                }
            }
            if heading { paragraph.paragraphSpacingBefore = output.length == 0 ? 0 : 16; paragraph.paragraphSpacing = 10 }
            if let item = listItem, case .listItem(let ordinal) = item.kind {
                let indent = CGFloat(max(1, depth)) * 22
                paragraph.headIndent = indent; paragraph.firstLineHeadIndent = indent
                if previousListItem != item.identity {
                    paragraph.firstLineHeadIndent = indent - 20
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    content.insert(NSAttributedString(string: ordered ? "\(ordinal).\t" : "•\t", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]), at: 0)
                }
                paragraph.paragraphSpacing = 7
                previousListItem = item.identity
            } else { previousListItem = nil }
            if quote { paragraph.headIndent += 18; paragraph.firstLineHeadIndent += 18; content.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: content.length)) }
            if code {
                paragraph.headIndent = 12; paragraph.firstLineHeadIndent = 12; paragraph.paragraphSpacingBefore = 0; paragraph.paragraphSpacing = 0; paragraph.lineSpacing = 2
                content.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .backgroundColor: NSColor.quaternaryLabelColor], range: NSRange(location: 0, length: content.length))
            }
            if let (id, columns) = table {
                let grid = tables[id] ?? NSTextTable()
                grid.numberOfColumns = max(1, columns.count); grid.collapsesBorders = true
                grid.setValue(100, type: .percentage, for: .width)
                tables[id] = grid
                let cell = NSTextTableBlock(table: grid, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(7, type: .absolute, for: .padding)
                cell.setWidth(0.5, type: .absolute, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.setValue(100 / CGFloat(max(1, columns.count)), type: .percentage, for: .width)
                paragraph.textBlocks = [cell]; paragraph.paragraphSpacing = 0
                if column < columns.count {
                    switch columns[column].alignment { case .center: paragraph.alignment = .center; case .right: paragraph.alignment = .right; default: break }
                }
                if headerRow { content.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .semibold), range: NSRange(location: 0, length: content.length)) }
            }
            if !content.string.hasSuffix("\n") { content.append(NSAttributedString(string: "\n", attributes: [.font: baseFont(block.intents)])) }
            if code { content.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 8)])) }
            content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))
            output.append(content)
        }
        return output
    }
    private static func baseFont(_ intents: [PresentationIntent.IntentType]) -> NSFont {
        for intent in intents {
            if case .header(let level) = intent.kind { return .systemFont(ofSize: level == 1 ? 25 : level == 2 ? 20 : level == 3 ? 17 : 15, weight: .semibold) }
        }
        return .systemFont(ofSize: 14)
    }
}

struct ReviewMarkdownView: NSViewRepresentable {
    var markdown: String
    var openLink: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(openLink: openLink) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.importsGraphics = false
        text.drawsBackground = false; text.usesFindBar = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true; text.textContainer?.lineFragmentPadding = 0
        text.textContainerInset = NSSize(width: 22, height: 20)
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        text.delegate = context.coordinator; text.setAccessibilityIdentifier("reviewPreview")
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.openLink = openLink
        guard context.coordinator.markdown != markdown, let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.markdown = markdown
        text.textStorage?.setAttributedString(ReviewMarkdown.render(markdown))
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var markdown: String?
        var openLink: (URL) -> Void
        init(openLink: @escaping (URL) -> Void) { self.openLink = openLink }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return true }
            openLink(url)
            return true
        }
    }
}
