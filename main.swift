import AppKit
import ServiceManagement

// MARK: - Storage (notes.json; a legacy single-note note.txt is migrated on first run)

struct Note: Codable {
    var id = UUID()
    var text = ""
}

struct NoteDoc: Codable {
    var notes: [Note]
    var selected: Int
}

// Setting FLOATNOTE_PROFILE=<name> runs an isolated instance with its own notes and settings
// (handy for development, demos and screenshots; it never touches your real notes).
let profile = ProcessInfo.processInfo.environment["FLOATNOTE_PROFILE"]

enum Store {
    static let dir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(profile.map { "FloatNote-\($0)" } ?? "FloatNote")
    static let jsonFile = dir.appendingPathComponent("notes.json")
    static let legacyFile = dir.appendingPathComponent("note.txt")

    static func load() -> NoteDoc {
        if let data = try? Data(contentsOf: jsonFile),
           var doc = try? JSONDecoder().decode(NoteDoc.self, from: data), !doc.notes.isEmpty {
            doc.selected = min(max(doc.selected, 0), doc.notes.count - 1)
            return doc
        }
        let legacy = (try? String(contentsOf: legacyFile, encoding: .utf8)) ?? ""
        return NoteDoc(notes: [Note(text: legacy)], selected: 0)
    }

    static func save(_ doc: NoteDoc) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(doc) { try? data.write(to: jsonFile, options: .atomic) }
    }
}

// MARK: - Draggable + clickable area: moving more than 3pt drags the window, otherwise it counts as a click

final class DragClickView: NSView {
    var onClick: (() -> Void)?
    var showsPointingHand = false
    var menuProvider: (() -> NSMenu?)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Subviews (text labels) must not swallow mouse events
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if let b = subviews.compactMap({ $0 as? IconButton }).first(where: { $0.frame.contains(p) }) { return b }
        return self
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func resetCursorRects() {
        if showsPointingHand { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick?() }
    }
}

// Small icon button in the header: handles its own click, never triggers the header's collapse/drag
final class IconButton: NSView {
    var onClick: (() -> Void)?
    let imageView = NSImageView()

    init(symbol: String, tip: String) {
        super.init(frame: .zero)
        toolTip = tip
        imageView.contentTintColor = .secondaryLabelColor
        addSubview(imageView)
        setSymbol(symbol)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String) {
        imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// Side tab: click to switch, right-click for a menu
final class TabButton: NSView {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    let label = NSTextField(labelWithString: "")
    var selected = false {
        didSet {
            label.textColor = selected ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(selected ? 0.14 : 0).cgColor
        }
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

final class NotePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// Shows a placeholder when the note is empty
final class NoteTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        "Write something…".draw(at: NSPoint(x: x, y: textContainerInset.height), withAttributes: attrs)
    }
}

// MARK: - Main controller

final class NoteController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let collapsedDiameter: CGFloat = 36
    static let defaultExpandedSize = NSSize(width: 280, height: 220)
    static let minExpandedSize = NSSize(width: 230, height: 120)
    static let headerHeight: CGFloat = 28
    static let tabStripWidth: CGFloat = 32
    static let tabSize: CGFloat = 24
    static let tabPitch: CGFloat = 28
    static let maxNotes = 8

    let panel: NotePanel
    let root = NSVisualEffectView()
    let collapsedView = DragClickView()
    let collapsedIcon = NSImageView()
    let expandedView = NSView()
    let header = DragClickView()
    let textView = NoteTextView()
    var scroll: NSScrollView!
    let tabStrip = NSView()
    var tabSeparator: NSBox!
    var tabButtons: [TabButton] = []
    var doc = Store.load()
    let defaults = profile.map { UserDefaults(suiteName: "floatnote.\($0)")! } ?? .standard
    var expanded = false
    var applying = false
    var menuProvider: (() -> NSMenu?)?          // right-click menu for the circle / header, provided by AppDelegate
    var anchorTopLeft: NSPoint?                 // top-left of the circle before expanding
    var expandedTopLeft: NSPoint?               // top-left after expanding (once clamped into the screen)

    var expandedSize: NSSize {
        let w = defaults.double(forKey: "w"), h = defaults.double(forKey: "h")
        guard w >= NoteController.minExpandedSize.width, h >= NoteController.minExpandedSize.height else {
            return NSSize(width: NoteController.defaultExpandedSize.width,
                          height: max(NoteController.defaultExpandedSize.height, requiredMinHeight))
        }
        return NSSize(width: w, height: max(h, requiredMinHeight))
    }

    // The side tabs (including "+") must fit completely
    var requiredMinHeight: CGFloat {
        let slots = doc.notes.count + (doc.notes.count < NoteController.maxNotes ? 1 : 0)
        let need = NoteController.headerHeight + 16 + CGFloat(slots) * NoteController.tabPitch
        return max(NoteController.minExpandedSize.height, need)
    }

    override init() {
        panel = NotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: NoteController.collapsedDiameter),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        super.init()
        setupPanel()
        setupCollapsed()
        setupExpanded()
        textView.string = doc.notes[doc.selected].text
        rebuildTabs()
        updateUndoButton()
        restoreFrame()
        applyState(animated: false)
    }

    func setupPanel() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.setExpanded(false) }

        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.masksToBounds = true
        panel.contentView = root
    }

    func setupCollapsed() {
        collapsedView.autoresizingMask = [.width, .height]
        collapsedView.showsPointingHand = true
        collapsedView.onClick = { [weak self] in self?.setExpanded(true) }
        collapsedView.menuProvider = { [weak self] in self?.menuProvider?() }
        collapsedIcon.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        collapsedIcon.contentTintColor = .labelColor
        collapsedView.addSubview(collapsedIcon)
        root.addSubview(collapsedView)
    }

    var headerChevron: NSImageView!
    var copyButton: IconButton!
    var deleteButton: IconButton!
    var addButton: IconButton!
    var cutButton: IconButton!
    var undoButton: IconButton!
    var headerSeparator: NSBox!

    func setupExpanded() {
        expandedView.autoresizingMask = [.width, .height]
        root.addSubview(expandedView)

        header.autoresizingMask = [.width, .minYMargin]
        header.showsPointingHand = true
        header.onClick = { [weak self] in self?.setExpanded(false) }
        header.menuProvider = { [weak self] in self?.menuProvider?() }
        let title = NSTextField(labelWithString: "Notes")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 12, y: 6, width: 100, height: 16)
        header.addSubview(title)

        headerChevron = NSImageView()
        headerChevron.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Collapse")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        headerChevron.contentTintColor = .secondaryLabelColor
        header.addSubview(headerChevron)

        copyButton = IconButton(symbol: "doc.on.doc", tip: "Copy this note")
        copyButton.onClick = { [weak self] in self?.copyCurrentNote() }
        header.addSubview(copyButton)

        cutButton = IconButton(symbol: "scissors", tip: "Cut (copy and clear this note)")
        cutButton.onClick = { [weak self] in self?.cutCurrentNote() }
        header.addSubview(cutButton)

        undoButton = IconButton(symbol: "arrow.uturn.backward", tip: "Undo")
        undoButton.onClick = { [weak self] in self?.undoLast() }
        header.addSubview(undoButton)

        deleteButton = IconButton(symbol: "trash", tip: "Delete this note")
        deleteButton.onClick = { [weak self] in
            guard let self = self else { return }
            self.deleteNote(self.doc.selected)
        }
        header.addSubview(deleteButton)

        addButton = IconButton(symbol: "plus", tip: "New note")
        addButton.onClick = { [weak self] in self?.addNote() }
        header.addSubview(addButton)

        headerSeparator = NSBox()
        headerSeparator.boxType = .separator
        header.addSubview(headerSeparator)
        expandedView.addSubview(header)

        tabSeparator = NSBox()
        tabSeparator.boxType = .separator
        tabStrip.addSubview(tabSeparator)
        expandedView.addSubview(tabStrip)

        let scroll = NSScrollView()
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.defaultParagraphStyle = para
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = self
        scroll.documentView = textView
        expandedView.addSubview(scroll)
        self.scroll = scroll
    }

    // MARK: State

    func topLeft(of f: NSRect) -> NSPoint { NSPoint(x: f.minX, y: f.maxY) }

    func setExpanded(_ on: Bool) {
        if on && !expanded { anchorTopLeft = topLeft(of: panel.frame) }
        expanded = on
        defaults.set(on, forKey: "expanded")
        applyState(animated: true)
        if on {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(textView)
        } else {
            panel.makeFirstResponder(nil)
        }
    }

    // Hide the whole panel (circle or note) and bring it back, e.g. while gaming. The menu bar icon stays.
    func setHidden(_ hidden: Bool) {
        if hidden {
            panel.orderOut(nil)
            return
        }
        panel.orderFrontRegardless()
        if expanded {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(textView)
        }
    }

    func applyState(animated: Bool) {
        applying = true
        defer { applying = false }

        let old = panel.frame
        let size = expanded
            ? expandedSize
            : NSSize(width: NoteController.collapsedDiameter, height: NoteController.collapsedDiameter)
        // Keep the top-left corner fixed
        var frame = NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
        if expanded {
            frame = clampToScreen(frame)
        } else if let a = anchorTopLeft, let e = expandedTopLeft,
                  abs(old.minX - e.x) < 1, abs(old.maxY - e.y) < 1 {
            frame.origin = NSPoint(x: a.x, y: a.y - size.height)   // Not moved by hand: go back to where it was before expanding
        }

        // Lock the size when collapsed; allow edge-resizing when expanded
        panel.minSize = expanded ? NSSize(width: NoteController.minExpandedSize.width, height: requiredMinHeight) : size
        panel.maxSize = expanded ? NSSize(width: 800, height: 1200) : size

        let radius: CGFloat = expanded ? 10 : NoteController.collapsedDiameter / 2
        root.layer?.cornerRadius = radius
        root.maskImage = roundedMask(radius)   // clips the blur itself, so no square corners leak out
        collapsedView.isHidden = expanded
        expandedView.isHidden = !expanded
        panel.setFrame(frame, display: true, animate: animated)
        panel.invalidateShadow()
        layoutContent(size)
        panel.invalidateCursorRects(for: collapsedView)
        if expanded {
            expandedTopLeft = topLeft(of: frame)
        } else {
            anchorTopLeft = nil
            expandedTopLeft = nil
        }
        defaults.set(NSStringFromPoint(topLeft(of: frame)), forKey: "topLeft")
    }

    func roundedMask(_ r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    // Clamp the window into the visible area of its screen (top-left wins)
    func clampToScreen(_ f: NSRect) -> NSRect {
        let probe = NSPoint(x: f.minX + 18, y: f.maxY - 18)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return f }
        var r = f
        r.origin.x = min(r.origin.x, vf.maxX - r.width)
        r.origin.x = max(r.origin.x, vf.minX)
        r.origin.y = max(r.origin.y, vf.minY)
        r.origin.y = min(r.origin.y, vf.maxY - r.height)
        return r
    }

    func layoutContent(_ size: NSSize) {
        collapsedView.frame = NSRect(origin: .zero, size: size)
        collapsedIcon.frame = NSRect(x: (size.width - 20) / 2, y: (size.height - 20) / 2, width: 20, height: 20)
        expandedView.frame = NSRect(origin: .zero, size: size)
        let h = NoteController.headerHeight
        header.frame = NSRect(x: 0, y: size.height - h, width: size.width, height: h)
        headerChevron.frame = NSRect(x: size.width - 28, y: 7, width: 14, height: 14)
        copyButton.frame = NSRect(x: size.width - 56, y: 6, width: 16, height: 16)
        cutButton.frame = NSRect(x: size.width - 80, y: 6, width: 16, height: 16)
        undoButton.frame = NSRect(x: size.width - 104, y: 6, width: 16, height: 16)
        deleteButton.frame = NSRect(x: size.width - 128, y: 6, width: 16, height: 16)
        addButton.frame = NSRect(x: size.width - 152, y: 6, width: 16, height: 16)
        headerSeparator.frame = NSRect(x: 0, y: 0, width: size.width, height: 1)
        let sw = NoteController.tabStripWidth
        tabStrip.frame = NSRect(x: 0, y: 0, width: sw, height: size.height - h)
        tabSeparator.frame = NSRect(x: sw - 1, y: 0, width: 1, height: size.height - h)
        layoutTabs()
        scroll.frame = NSRect(x: sw, y: 0, width: size.width - sw, height: size.height - h)
    }

    func layoutTabs() {
        let top = tabStrip.bounds.height - 8
        let x = (NoteController.tabStripWidth - 1 - NoteController.tabSize) / 2
        for (i, b) in tabButtons.enumerated() {
            b.frame = NSRect(x: x, y: top - NoteController.tabSize - CGFloat(i) * NoteController.tabPitch,
                             width: NoteController.tabSize, height: NoteController.tabSize)
        }
    }

    // MARK: Persistence

    func restoreFrame() {
        expanded = defaults.bool(forKey: "expanded")
        if let s = defaults.string(forKey: "topLeft") {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(p) }) {
                panel.setFrameTopLeftPoint(p)
                return
            }
        }
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - 300, y: vf.maxY - 40))
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !applying else { return }
        defaults.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)), forKey: "topLeft")
    }

    func windowDidResize(_ notification: Notification) {
        guard !applying else { return }
        layoutContent(panel.frame.size)
        guard expanded else { return }
        defaults.set(panel.frame.width, forKey: "w")
        defaults.set(panel.frame.height, forKey: "h")
        defaults.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)), forKey: "topLeft")
    }

    func textDidChange(_ notification: Notification) {
        doc.notes[doc.selected].text = textView.string
        Store.save(doc)
        textView.needsDisplay = true
        tabButtons[doc.selected].label.stringValue = tabTitle(doc.selected)
        tabButtons[doc.selected].toolTip = tabTip(doc.selected)
        DispatchQueue.main.async { [weak self] in self?.updateUndoButton() }
    }

    // MARK: Copy

    func copyCurrentNote() {
        let text = doc.notes[doc.selected].text
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.setSymbol("checkmark")   // briefly show a checkmark as feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.setSymbol("doc.on.doc")
        }
    }

    // MARK: Cut / Undo

    // Cut: copy the whole text to the clipboard and clear the note; clearing goes through the text system, so it can be undone
    func cutCurrentNote() {
        let text = textView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let range = NSRange(location: 0, length: (text as NSString).length)
        if textView.shouldChangeText(in: range, replacementString: "") {
            textView.textStorage?.replaceCharacters(in: range, with: "")
            textView.didChangeText()
        }
        cutButton.setSymbol("checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.cutButton.setSymbol("scissors")
        }
    }

    // Undo: step back the last edit of the current note (including a cut)
    func undoLast() {
        guard let um = textView.undoManager, um.canUndo else { return }
        um.undo()
        updateUndoButton()
    }

    func updateUndoButton() {
        let can = textView.undoManager?.canUndo ?? false
        undoButton.alphaValue = can ? 1 : 0.3
    }

    // MARK: Multiple notes

    func tabTitle(_ i: Int) -> String {
        let t = doc.notes[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.first.map { String($0) } ?? String(i + 1)
    }

    func tabTip(_ i: Int) -> String? {
        doc.notes[i].text.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init)
    }

    func rebuildTabs() {
        let canAdd = doc.notes.count < NoteController.maxNotes
        addButton.alphaValue = canAdd ? 1 : 0.3
        addButton.toolTip = canAdd ? "New note" : "Maximum \(NoteController.maxNotes) notes"
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons = []
        for i in 0..<doc.notes.count {
            let b = TabButton(title: tabTitle(i))
            b.toolTip = tabTip(i)
            b.selected = (i == doc.selected)
            b.onClick = { [weak self] in self?.selectNote(i) }
            b.menuProvider = { [weak self] in
                let m = NSMenu()
                let item = m.addItem(withTitle: "Delete this note", action: #selector(NoteController.deleteNoteFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                return m
            }
            tabStrip.addSubview(b)
            tabButtons.append(b)
        }
        if doc.notes.count < NoteController.maxNotes {
            let plus = TabButton(title: "+")
            plus.toolTip = "New note"
            plus.onClick = { [weak self] in self?.addNote() }
            tabStrip.addSubview(plus)
            tabButtons.append(plus)
        }
        layoutTabs()
    }

    func loadSelected() {
        textView.string = doc.notes[doc.selected].text
        textView.undoManager?.removeAllActions()
        textView.scrollToBeginningOfDocument(nil)
        textView.needsDisplay = true
        for (i, b) in tabButtons.enumerated() where i < doc.notes.count { b.selected = (i == doc.selected) }
        panel.makeFirstResponder(textView)
        updateUndoButton()
    }

    func selectNote(_ i: Int) {
        guard i != doc.selected, i < doc.notes.count else { return }
        doc.selected = i
        Store.save(doc)
        loadSelected()
    }

    func addNote() {
        guard doc.notes.count < NoteController.maxNotes else { return }
        doc.notes.append(Note())
        doc.selected = doc.notes.count - 1
        Store.save(doc)
        tabsChanged()
    }

    @objc func deleteNoteFromMenu(_ sender: NSMenuItem) { deleteNote(sender.tag) }

    func deleteNote(_ i: Int) {
        guard i < doc.notes.count else { return }
        if !doc.notes[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let a = NSAlert()
            a.messageText = "Delete this note?"
            a.informativeText = "Its content cannot be recovered."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        if doc.notes.count == 1 {
            doc.notes[0].text = ""   // always keep at least one note
        } else {
            doc.notes.remove(at: i)
            if doc.selected > i || doc.selected >= doc.notes.count { doc.selected = max(0, doc.selected - 1) }
        }
        Store.save(doc)
        tabsChanged()
    }

    // Tab count changed: rebuild the side strip, update the minimum height (grow the window if needed, top-left stays put)
    func tabsChanged() {
        rebuildTabs()
        panel.minSize = NSSize(width: NoteController.minExpandedSize.width, height: requiredMinHeight)
        if panel.frame.height < requiredMinHeight {
            let f = panel.frame
            let grown = NSRect(x: f.minX, y: f.maxY - requiredMinHeight, width: f.width, height: requiredMinHeight)
            panel.setFrame(clampToScreen(grown), display: true)
        }
        layoutContent(panel.frame.size)
        loadSelected()
    }

}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let note = NoteController()
    var statusItem: NSStatusItem!
    var statusVisibilityItem: NSMenuItem!
    var statusLoginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        setupMainMenu()
        setupStatusItem()
        note.menuProvider = { [weak self] in self?.makeContextMenu() }
        enableAutostartOnFirstRun()
        note.panel.orderFrontRegardless()
        if note.expanded {
            NSApp.activate(ignoringOtherApps: true)
            note.panel.makeKey()
        }
    }

    // Hide / show the notes. Also reachable from the menu bar, which is the only way back while hidden.
    @objc func toggleVisibility() {
        note.setHidden(note.panel.isVisible)
    }

    // MARK: Menu bar icon

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "note.text", accessibilityDescription: "FloatNote")
        icon?.isTemplate = true   // follows the menu bar's light/dark appearance
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "FloatNote"

        let menu = NSMenu()
        menu.delegate = self
        statusVisibilityItem = menu.addItem(withTitle: "Hide Notes", action: #selector(toggleVisibility), keyEquivalent: "")
        statusVisibilityItem.target = self
        menu.addItem(.separator())
        statusLoginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleAutostart), keyEquivalent: "")
        statusLoginItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    // Refresh the titles and checkmarks each time the menu bar menu opens
    func menuNeedsUpdate(_ menu: NSMenu) {
        statusVisibilityItem.title = note.panel.isVisible ? "Hide Notes" : "Show Notes"
        statusLoginItem.state = autostartOn ? .on : .off
    }

    // MARK: Launch at login (SMAppService; enabled on first run, afterwards the menu checkmark rules)

    var autostartOn: Bool {
        let s = SMAppService.mainApp.status
        return s == .enabled || s == .requiresApproval
    }

    func enableAutostartOnFirstRun() {
        guard profile == nil else { return }   // isolated profiles never touch login items
        let key = "autostartInitialized"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    @objc func toggleAutostart() {
        do {
            if autostartOn { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Could not change the launch-at-login setting"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    // MARK: Menu

    // Pops up on right-click of the circle / header
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let hide = menu.addItem(withTitle: "Hide Notes", action: #selector(toggleVisibility), keyEquivalent: "")
        hide.target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleAutostart), keyEquivalent: "")
        login.target = self
        login.state = autostartOn ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    // An app without a Dock icon has no default Edit menu; build one so ⌘C/⌘V/⌘Z work
    func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
