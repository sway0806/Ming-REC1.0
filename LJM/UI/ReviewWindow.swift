import AppKit
import AVFoundation
import AVKit

/// After a take is saved, a 小名-styled review window plays the file and lists recent recordings.
/// This is not a full editor — play/pause, reveal, and share only.
@MainActor
final class ReviewWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private var playerView: AVPlayerView?
    private var player: AVPlayer?
    private var table: NSTableView?
    private var titleLabel: NSTextField?
    private var metaLabel: NSTextField?
    private var files: [SaveLocation.RecordingFile] = []
    private var current: URL?
    private var access: SaveLocation.Access?
    private var endObserver: NSObjectProtocol?

    var isVisible: Bool { window?.isVisible == true }
    var currentURL: URL? { current }
    var listedCount: Int { files.count }

    func show(file url: URL) {
        access = access ?? (try? SaveLocation.beginAccess())
        current = url
        files = listFiles(including: url)
        if !files.contains(where: { $0.url.path == url.path }) {
            files.insert(SaveLocation.RecordingFile(url: url, name: url.deletingPathExtension().lastPathComponent, size: SaveLocation.fileSize(url), modified: fileDate(url), duration: nil), at: 0)
        }
        if window == nil { buildWindow() }
        reloadList()
        play(url)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hide() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerView?.player = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        playerView = nil
        table = nil
        titleLabel = nil
        metaLabel = nil
        access = nil
        current = nil
        files = []
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "录制完成"
        window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 31 / 255, alpha: 1)
        window.toolbarStyle = .unifiedCompact
        window.center()
        window.sharingType = .none

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 540))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 31 / 255, alpha: 1).cgColor

        let playerView = AVPlayerView(frame: .zero)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect
        root.addSubview(playerView)

        let title = label("", size: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        let meta = label("", size: 12, weight: .regular)
        meta.textColor = NSColor(srgbRed: 236 / 255, green: 237 / 255, blue: 241 / 255, alpha: 0.62)
        meta.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(meta)

        let reveal = textButton("在访达中显示", action: #selector(revealCurrent))
        let share = textButton("分享", action: #selector(shareCurrent))
        let close = textButton("关闭", action: #selector(closeWindow))
        let buttons = NSStackView(views: [reveal, share, close])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        let scroll = NSScrollView(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let table = NSTableView(frame: .zero)
        table.headerView = nil
        table.backgroundColor = NSColor(srgbRed: 36 / 255, green: 37 / 255, blue: 41 / 255, alpha: 1)
        table.selectionHighlightStyle = .regular
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(selectRow)
        table.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.width = 240
        table.addTableColumn(column)
        scroll.documentView = table
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.backgroundColor = NSColor(srgbRed: 36 / 255, green: 37 / 255, blue: 41 / 255, alpha: 1).cgColor
        root.addSubview(scroll)

        let sideTitle = label("最近的录像", size: 12, weight: .semibold)
        sideTitle.textColor = NSColor(srgbRed: 236 / 255, green: 237 / 255, blue: 241 / 255, alpha: 0.62)
        sideTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sideTitle)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            playerView.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            playerView.trailingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: -16),
            playerView.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.68),

            title.leadingAnchor.constraint(equalTo: playerView.leadingAnchor, constant: 2),
            title.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),

            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            meta.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),

            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 14),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),

            sideTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            sideTitle.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 4),

            scroll.topAnchor.constraint(equalTo: sideTitle.bottomAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalToConstant: 248)
        ])

        window.contentView = root
        self.window = window
        self.playerView = playerView
        self.table = table
        self.titleLabel = title
        self.metaLabel = meta
    }

    private func play(_ url: URL) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        current = url
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playerView?.player = player
        player.play()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.player?.seek(to: .zero) }
        }
        titleLabel?.stringValue = url.deletingPathExtension().lastPathComponent
        let size = ByteCountFormatter.string(fromByteCount: SaveLocation.fileSize(url), countStyle: .file)
        let duration = ReviewWindowController.durationString(for: url)
        metaLabel?.stringValue = [duration, size].compactMap { $0 }.joined(separator: "  ·  ")
        reloadList()
        if let index = files.firstIndex(where: { $0.url.path == url.path }) {
            table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table?.scrollRowToVisible(index)
        }
    }

    private func reloadList() {
        if let current {
            files = listFiles(including: current)
        }
        table?.reloadData()
    }

    private func listFiles(including url: URL) -> [SaveLocation.RecordingFile] {
        let access = self.access ?? (try? SaveLocation.beginAccess())
        self.access = access
        var listed: [SaveLocation.RecordingFile] = []
        if let directory = access?.directory {
            listed = SaveLocation.listRecordings(in: directory, limit: 24)
        }
        if !listed.contains(where: { $0.url.path == url.path }) {
            listed.insert(
                SaveLocation.RecordingFile(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    size: SaveLocation.fileSize(url),
                    modified: fileDate(url),
                    duration: nil
                ),
                at: 0
            )
        }
        return listed
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = files[row]
        let cell = NSView()
        let name = label(file.name, size: 12, weight: .medium)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingMiddle
        let duration = ReviewWindowController.durationString(for: file.url) ?? "—"
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        let detail = label("\(duration)  ·  \(size)", size: 10, weight: .regular)
        detail.textColor = NSColor(srgbRed: 236 / 255, green: 237 / 255, blue: 241 / 255, alpha: 0.55)
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(name)
        cell.addSubview(detail)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2)
        ])
        if file.url.path == current?.path {
            name.textColor = NSColor(srgbRed: 252 / 255, green: 107 / 255, blue: 16 / 255, alpha: 1)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ReviewRowView()
        rowView.highlight = files[row].url.path == current?.path
        return rowView
    }

    @objc private func selectRow() {
        guard let table, table.selectedRow >= 0, table.selectedRow < files.count else { return }
        play(files[table.selectedRow].url)
    }

    @objc private func revealCurrent() {
        guard let current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current])
    }

    @objc private func shareCurrent(_ sender: NSButton) {
        guard let current else { return }
        let picker = NSSharingServicePicker(items: [current])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func closeWindow() {
        hide()
    }

    func windowWillClose(_ notification: Notification) {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerView?.player = nil
        access = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = NSColor(srgbRed: 236 / 255, green: 237 / 255, blue: 241 / 255, alpha: 1)
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func textButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return button
    }

    private func fileDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
    }

    private static func durationString(for url: URL) -> String? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return CaptureGeometry.elapsedHMS(Int(seconds.rounded()))
    }
}

private final class ReviewRowView: NSTableRowView {
    var highlight = false

    override func drawBackground(in dirtyRect: NSRect) {
        let color = highlight
            ? NSColor(srgbRed: 70 / 255, green: 71 / 255, blue: 77 / 255, alpha: 1)
            : NSColor(srgbRed: 36 / 255, green: 37 / 255, blue: 41 / 255, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(srgbRed: 70 / 255, green: 71 / 255, blue: 77 / 255, alpha: 1).setFill()
        dirtyRect.fill()
    }
}
