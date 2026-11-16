import AppKit
import Carbon
import os

@main
enum LJMMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    private var modelStorage: AppModel?
    private var panels: PanelController?
    private var statusItem: NSStatusItem?
    private var hotkeys: [EventHotKeyRef] = []
    private let log = Logger(subsystem: "dev.ljm.recorder", category: "app")

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            ProcessInfo.processInfo.processName = "小名"
            self.modelStorage = AppModel()
        }
        NSApp.setActivationPolicy(.regular)
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let model = self.modelStorage!
            let panels = PanelController(model: model)
            self.panels = panels
            model.onMainChromeVisible = { [weak self] visible in
                if visible {
                    self?.panels?.orderFront()
                } else {
                    self?.panels?.hide()
                }
            }
            panels.show()
            self.setupStatusItem()
            self.setupHotkeys()
            if CommandLine.arguments.contains("--self-test-record") {
                // Do not restore a persisted camera/mic session into the default self-test.
                self.modelStorage?.runSelfTest()
            } else if CommandLine.arguments.contains("--self-test-zoom-render") {
                self.modelStorage?.runZoomRenderSelfTest()
            } else if CommandLine.arguments.contains("--self-test-ui-snapshot") {
                self.runUISnapshot()
            } else if CommandLine.arguments.contains("--self-test-reveal") {
                self.modelStorage?.runRevealSelfTest()
            } else if CommandLine.arguments.contains("--self-test-cursor") {
                self.panels?.runCursorSelfTest()
            } else if CommandLine.arguments.contains("--self-test-camera-shape") {
                self.modelStorage?.runCameraShapeSelfTest()
            } else if CommandLine.arguments.contains("--self-test-recording-chrome") {
                self.modelStorage?.runRecordingChromeSelfTest()
            } else {
                self.modelStorage?.restoreDevices()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.modelStorage?.handleBecameActive()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            let model = self.modelStorage
            if model?.phase == .recording || model?.phase == .starting || model?.isCountingDown == true {
                return
            }
            self.panels?.orderFront()
        }
        return true
    }

    @MainActor
    var isCapsuleVisible: Bool { panels?.isVisible ?? false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = MainActor.assumeIsolated {
            let phase = self.modelStorage?.phase
            return phase == .recording || phase == .starting || phase == .stopping
        }
        guard busy else { return .terminateNow }
        Task { @MainActor in
            await self.modelStorage?.prepareToQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { self.modelStorage?.shutdownDevices() }
        hotkeys.forEach { UnregisterEventHotKey($0) }
        hotkeys.removeAll()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Writes 更多 card snapshots (effects off, then all on) to Desktop/LJM/test-output, then quits.
    /// Never persists the preview state.
    @MainActor
    private func runUISnapshot() {
        guard let model = modelStorage, let panels else { return }
        Task { @MainActor in
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/LJM/ui-snapshot")
            var lines: [String] = []
            for (allOn, name) in [(false, "effects-ui-off.png"), (true, "effects-ui-on.png")] {
                model.previewEffectsCard(allOn: allOn)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let result = await panels.snapshotPNG(to: folder.appendingPathComponent(name))
                lines.append("\(name): \(result)")
            }
            model.previewSharingCard()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            lines.append("share-saved-card.png: " + (await panels.snapshotPNG(to: folder.appendingPathComponent("share-saved-card.png"))))
            model.dismissCard()
            model.previewEffectsCard(allOn: false)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            lines.append("share-more-card.png: " + (await panels.snapshotPNG(to: folder.appendingPathComponent("share-more-card.png"))))
            lines.append("recent=" + (model.lastSavedURL?.lastPathComponent ?? "nil") + " versions=" + (model.lastSavedURL.map { model.versions(for: $0).map(\.title).joined(separator: "/") } ?? "-"))
            // 说明书用：控制条单独、录制范围卡片、录制中的样子（只改显示状态，不真正录制）。
            model.lastSavedURL = nil
            model.dismissCard()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            lines.append("manual-bar-idle.png: " + (await panels.snapshotPNG(to: folder.appendingPathComponent("manual-bar-idle.png"))))
            model.showSource()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            lines.append("manual-source-card.png: " + (await panels.snapshotPNG(to: folder.appendingPathComponent("manual-source-card.png"))))
            model.dismissCard()
            model.elapsedSeconds = 12
            model.phase = .recording
            model.bumpLayout()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            lines.append("manual-bar-recording.png: " + (await panels.snapshotPNG(to: folder.appendingPathComponent("manual-bar-recording.png"))))
            model.phase = .idle
            model.elapsedSeconds = 0
            model.bumpLayout()
            let report = lines.joined(separator: "\n") + "\n"
            try? Data(report.utf8).write(to: folder.appendingPathComponent("ui-snapshot-result.txt"), options: .atomic)
            NSApp.terminate(nil)
        }
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "录你选择的显示器或区域，混入系统声音，保存为 MP4。",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "小名",
            .applicationVersion: "1.0",
            .credits: credits
        ])
    }

    @objc func showSettings(_ sender: Any?) {
        MainActor.assumeIsolated {
            self.modelStorage?.showSettings()
            self.panels?.orderFront()
        }
    }

    @objc func toggleRecording(_ sender: Any?) {
        MainActor.assumeIsolated { self.modelStorage?.toggleRecord() }
        refreshStatusItem()
    }

    @objc func togglePause(_ sender: Any?) {
        MainActor.assumeIsolated { self.modelStorage?.togglePause() }
        refreshStatusItem()
    }

    @objc func showCapsule(_ sender: Any?) {
        MainActor.assumeIsolated { self.panels?.orderFront() }
        NSApp.activate()
    }

    @objc func hideCapsule(_ sender: Any?) {
        MainActor.assumeIsolated { self.panels?.hide() }
    }

    @objc func openFolder(_ sender: Any?) {
        MainActor.assumeIsolated { self.modelStorage?.openFolder() }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.title = "小名"
        main.addItem(appItem)
        let appMenu = NSMenu(title: "小名")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于小名", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出小名", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.items.forEach { if $0.target == nil && $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }

        let recordItem = NSMenuItem()
        recordItem.title = "录制"
        main.addItem(recordItem)
        let recordMenu = NSMenu(title: "录制")
        recordItem.submenu = recordMenu
        let toggle = recordMenu.addItem(withTitle: "开始或停止", action: #selector(toggleRecording(_:)), keyEquivalent: "r")
        toggle.target = self
        let pause = recordMenu.addItem(withTitle: "暂停或继续", action: #selector(togglePause(_:)), keyEquivalent: "p")
        pause.keyEquivalentModifierMask = [.command, .shift]
        pause.target = self

        let windowItem = NSMenuItem()
        windowItem.title = "窗口"
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "前置小名", action: #selector(orderFront(_:)), keyEquivalent: "0")
        windowMenu.items.forEach { $0.target = self }

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func orderFront(_ sender: Any?) {
        MainActor.assumeIsolated { self.panels?.orderFront() }
        NSApp.activate()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "小名"
        item.button?.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        item.button?.toolTip = "小名"
        let menu = NSMenu()
        menu.addItem(withTitle: "显示控制条", action: #selector(showCapsule(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "隐藏控制条", action: #selector(hideCapsule(_:)), keyEquivalent: "")
        let rec = menu.addItem(withTitle: "开始或停止录制", action: #selector(toggleRecording(_:)), keyEquivalent: "r")
        rec.keyEquivalentModifierMask = [.command, .shift]
        let pause = menu.addItem(withTitle: "暂停或继续录制", action: #selector(togglePause(_:)), keyEquivalent: "p")
        pause.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开录制文件夹", action: #selector(openFolder(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出小名", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
        refreshStatusItem()
    }

    func refreshStatusItemTitle() {
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        // Title stays 「小名」; a recording mark is enough without renaming the item.
        let recording = MainActor.assumeIsolated {
            let phase = self.modelStorage?.phase
            return phase == .recording || phase == .starting
        }
        let paused = MainActor.assumeIsolated { self.modelStorage?.paused ?? false }
        statusItem?.button?.title = paused ? "‖ 小名" : (recording ? "● 小名" : "小名")
    }

    private func setupHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var ident = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &ident
            )
            let value = ident.id
            Task { @MainActor in
                AppDelegate.shared.handleHotkey(value)
            }
            return noErr
        }, 1, &spec, nil, nil)
        if installed != noErr {
            log.error("hotkey handler was not installed: \(installed)")
            MainActor.assumeIsolated { self.modelStorage?.hotkeyNote = "快捷键未能注册，请使用控制条按钮。" }
            return
        }
        // signature 'XMIN' — distinct from other recorders that may also use ⌘⇧R / ⌘⇧L
        let signature: OSType = 0x584D494E
        var failed = false
        for (key, ident) in [(UInt32(kVK_ANSI_R), UInt32(1)), (UInt32(kVK_ANSI_L), UInt32(2)), (UInt32(kVK_ANSI_P), UInt32(3))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(key, UInt32(cmdKey | shiftKey), EventHotKeyID(signature: signature, id: ident), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference {
                hotkeys.append(reference)
            } else {
                failed = true
                log.error("hotkey \(ident) was not registered: \(result)")
            }
        }
        if failed {
            MainActor.assumeIsolated { self.modelStorage?.hotkeyNote = "部分快捷键被占用，请使用控制条按钮。" }
        }
    }

    @MainActor
    fileprivate func handleHotkey(_ id: UInt32) {
        if id == 1 {
            modelStorage?.toggleRecord()
            refreshStatusItem()
        } else if id == 3 {
            modelStorage?.togglePause()
            refreshStatusItem()
        } else {
            panels?.orderFront()
            NSApp.activate()
        }
    }
}
