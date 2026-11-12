import SwiftUI
import AppKit

/// Notion-style text block: live markdown styling, "/" command menu, list continuation, clickable to-dos, ⌘B/⌘I/⌘E.
struct LiveTextEditor: NSViewRepresentable {
    @Binding var text: String
    var size: CGFloat = 15.5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MDTextView {
        let tv = MDTextView()
        tv.baseSize = size
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 4
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.string = text
        tv.restyle()
        return tv
    }

    func updateNSView(_ tv: MDTextView, context: Context) {
        context.coordinator.parent = self
        if tv.string != text {
            tv.string = text
            tv.restyle()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: MDTextView, context: Context) -> CGSize? {
        let w = max(proposal.width ?? 600, 100)
        tv.textContainer?.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 24
        return CGSize(width: w, height: max(used + tv.textContainerInset.height * 2, 30))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiveTextEditor
        init(_ p: LiveTextEditor) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? MDTextView else { return }
            parent.text = tv.string
            tv.restyle()
            tv.invalidateIntrinsicContentSize()
            tv.maybeShowSlashMenu()
        }
    }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

final class MDTextView: NSTextView {
    var baseSize: CGFloat = 15.5
    private var typedSlash = false
    private var actions: [MenuAction] = []

    // MARK: styling

    private func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> NSFont {
        var f = mono ? NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
                     : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    func restyle() {
        guard let st = textStorage else { return }
        let ns = st.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 4
        ps.paragraphSpacing = 2
        let base: [NSAttributedString.Key: Any] = [.font: font(baseSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: ps]
        let dim = NSColor.tertiaryLabelColor
        st.beginEditing()
        st.setAttributes(base, range: full)
        typingAttributes = base

        ns.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = ns.substring(with: range)
            func sub(_ pat: String, _ f: (NSTextCheckingResult) -> Void) {
                guard let re = try? NSRegularExpression(pattern: pat) else { return }
                for m in re.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) { f(m) }
            }
            func abs(_ r: NSRange) -> NSRange { NSRange(location: range.location + r.location, length: r.length) }

            if let m = try? NSRegularExpression(pattern: "^(#{1,3})\\s").firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let lvl = m.range(at: 1).length
                let sz: CGFloat = [30, 23, 18.5][lvl - 1]
                let ps2 = ps.mutableCopy() as! NSMutableParagraphStyle
                ps2.paragraphSpacingBefore = lvl == 1 ? 10 : 6
                st.addAttributes([.font: self.font(sz, bold: true), .paragraphStyle: ps2], range: range)
                st.addAttribute(.foregroundColor, value: dim, range: abs(m.range))
            } else if line.hasPrefix(">") {
                st.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                st.addAttribute(.font, value: self.font(self.baseSize, italic: true), range: range)
                st.addAttribute(.foregroundColor, value: dim, range: NSRange(location: range.location, length: 1))
            } else if line.trimmingCharacters(in: .whitespaces) == "---" {
                st.addAttribute(.foregroundColor, value: dim, range: range)
            }
            sub("^\\s*(?:[-*]|\\d+\\.)\\s") { st.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: abs($0.range)) }
            sub("^\\s*[-*]\\s(\\[( |x|X)\\])\\s?(.*)$") { m in
                let done = (line as NSString).substring(with: m.range(at: 2)).lowercased() == "x"
                st.addAttributes([.foregroundColor: done ? NSColor.systemGreen : NSColor.controlAccentColor, .font: self.font(self.baseSize, bold: true)], range: abs(m.range(at: 1)))
                if done, m.range(at: 3).length > 0 {
                    st.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: abs(m.range(at: 3)))
                }
            }
            sub("\\*\\*(.+?)\\*\\*") { m in
                st.addAttribute(.font, value: self.font(self.baseSize, bold: true), range: abs(m.range))
                st.addAttribute(.foregroundColor, value: dim, range: NSRange(location: abs(m.range).location, length: 2))
                st.addAttribute(.foregroundColor, value: dim, range: NSRange(location: abs(m.range).location + m.range.length - 2, length: 2))
            }
            sub("(?<![*\\w])\\*(?!\\s)([^*\\n]+?)\\*(?![*\\w])") { m in
                st.addAttribute(.font, value: self.font(self.baseSize, italic: true), range: abs(m.range))
            }
            sub("`([^`\\n]+)`") { m in
                st.addAttributes([.font: self.font(self.baseSize, mono: true), .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08), .foregroundColor: NSColor.systemPink], range: abs(m.range))
            }
            sub("\\[\\[[^\\]]+\\]\\]|\\[[^\\]]+\\]\\([^)]+\\)|https?://\\S+") { m in
                st.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: abs(m.range))
            }
        }
        st.endEditing()
    }

    // MARK: editing helpers

    private func replace(_ r: NSRange, _ s: String) {
        if shouldChangeText(in: r, replacementString: s) {
            replaceCharacters(in: r, with: s)
            didChangeText()
        }
    }

    private func lineInfo() -> (range: NSRange, text: String, atEnd: Bool) {
        let ns = string as NSString
        let sel = selectedRange()
        let r = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let t = ns.substring(with: r).trimmingCharacters(in: .newlines)
        return (r, t, sel.length == 0 && sel.location == r.location + (t as NSString).length)
    }

    override func insertNewline(_ sender: Any?) {
        let li = lineInfo()
        guard li.atEnd,
              let re = try? NSRegularExpression(pattern: "^(\\s*)(- \\[[ xX]\\] |[-*] |(\\d+)\\. |> )(.*)$"),
              let m = re.firstMatch(in: li.text, range: NSRange(location: 0, length: (li.text as NSString).length)) else {
            return super.insertNewline(sender)
        }
        let t = li.text as NSString
        let indent = t.substring(with: m.range(at: 1))
        var marker = t.substring(with: m.range(at: 2))
        let rest = t.substring(with: m.range(at: 4))
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            let r = NSRange(location: li.range.location, length: (li.text as NSString).length)
            replace(r, "")
            return
        }
        if marker.hasPrefix("- [") { marker = "- [ ] " }
        else if m.range(at: 3).location != NSNotFound, let n = Int(t.substring(with: m.range(at: 3))) { marker = "\(n + 1). " }
        super.insertNewline(sender)
        insertText(indent + marker, replacementRange: selectedRange())
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let k = e.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: e) }
        switch k {
        case "b": wrap("**"); return true
        case "i": wrap("*"); return true
        case "e": wrap("`"); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    private func wrap(_ mark: String) {
        let sel = selectedRange()
        let s = (string as NSString).substring(with: sel)
        replace(sel, mark + s + mark)
        if sel.length == 0 { setSelectedRange(NSRange(location: sel.location + mark.count, length: 0)) }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: p)
        let ns = string as NSString
        if idx <= ns.length {
            let lr = ns.lineRange(for: NSRange(location: min(idx, max(ns.length - 1, 0)), length: 0))
            let line = ns.substring(with: lr)
            if let re = try? NSRegularExpression(pattern: "^(\\s*[-*]\\s)\\[( |x|X)\\]"),
               let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let box = NSRange(location: lr.location + m.range(at: 1).length, length: 3)
                if idx >= box.location && idx <= box.location + 3 {
                    let on = (line as NSString).substring(with: m.range(at: 2)) != " "
                    replace(box, on ? "[ ]" : "[x]")
                    return
                }
            }
        }
        super.mouseDown(with: e)
    }

    // MARK: slash menu

    override func shouldChangeText(in r: NSRange, replacementString s: String?) -> Bool {
        typedSlash = (s == "/")
        return super.shouldChangeText(in: r, replacementString: s)
    }

    func maybeShowSlashMenu() {
        guard typedSlash else { return }
        typedSlash = false
        let li = lineInfo()
        guard li.text.trimmingCharacters(in: .whitespaces) == "/", li.atEnd else { return }
        let slash = NSRange(location: selectedRange().location - 1, length: 1)
        let items: [(String, String, String)] = [
            ("Heading 1", "textformat.size.larger", "# "), ("Heading 2", "textformat.size", "## "), ("Heading 3", "textformat.size.smaller", "### "),
            ("Bullet list", "list.bullet", "- "), ("Numbered list", "list.number", "1. "), ("To-do", "checkmark.square", "- [ ] "),
            ("Quote", "text.quote", "> "), ("Divider", "minus", "---\n"), ("Code block", "chevron.left.forwardslash.chevron.right", "```\n\n```"),
        ]
        let menu = NSMenu()
        actions = []
        for (title, icon, snippet) in items {
            let a = MenuAction { [weak self] in
                guard let self else { return }
                self.replace(slash, snippet)
                if snippet.hasPrefix("```") { self.setSelectedRange(NSRange(location: slash.location + 4, length: 0)) }
            }
            actions.append(a)
            let it = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            it.target = a
            it.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            menu.addItem(it)
        }
        guard let lm = layoutManager, let tc = textContainer else { return }
        let g = lm.glyphRange(forCharacterRange: slash, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: g, in: tc)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y + rect.height
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY), in: self) }
    }
}
