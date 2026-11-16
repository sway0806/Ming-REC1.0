import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

@MainActor
final class AppModel: ObservableObject {
    enum PermissionKind: Equatable {
        case screen
        case microphone
        case camera
    }

    enum Card: Equatable {
        case permission(PermissionKind)
        case settings
        case source
        case more
        case saved(URL, note: String?)
        case error(String)
    }

    enum RecorderPhase: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    @Published var phase: RecorderPhase = .idle
    @Published var systemAudioEnabled: Bool
    @Published var microphoneEnabled: Bool
    @Published var cameraOn: Bool = false
    @Published var cameraBusy: Bool = false
    @Published var cameraShape: CameraShape
    @Published var edge: DockEdge
    /// t194: free placement (not docked). Orientation still comes from `edge`.
    @Published var floating: Bool = false
    /// Mini (50%) docking is disabled: docked bars stay full size.
    @Published var miniDock: Bool = false
    /// Double-click 横线 move mode (bar follows the mouse until the next click).
    @Published var moveMode: Bool = false

    func applyDockScale(mini: Bool) {
        Metrics.dockFactor = mini ? 0.5 : 1
        if miniDock != mini { miniDock = mini }
    }
    @Published var card: Card?
    @Published var folderPath: String = ""
    @Published var qualityCap: Int
    @Published var frameRate: Int
    @Published var powerSaver: Bool
    @Published var displayID: CGDirectDisplayID
    @Published var region: CGRect?
    @Published var elapsedSeconds: Int = 0
    @Published var lastSavedURL: URL?
    @Published var hotkeyNote: String?
    /// 画面效果. All default off; persisted.
    @Published var cursorHighlight: Bool
    @Published var clickRipples: Bool
    @Published var watermarkEnabled: Bool
    @Published var watermarkText: String
    @Published var watermarkCorner: WatermarkCorner
    /// 自动缩放: post-render a `-zoom.mp4` after the take. Default off.
    @Published var autoZoom: Bool
    @Published var zoomFactor: Double
    /// Non-nil while the zoom version renders (0…1).
    @Published var zoomProgress: Double?
    @Published private(set) var layoutTick: Int = 0
    @Published private(set) var chromeSize: CGSize = .zero

    // Round-1 recording behaviour (all off by default; existing behaviour unchanged).
    @Published private(set) var paused: Bool = false
    @Published var countdownEnabled: Bool
    @Published var startSound: Bool
    @Published var showBorder: Bool
    @Published var playAfterRecording: Bool
    @Published var revealAfterRecording: Bool
    /// 0 = off; otherwise minutes of recorded (not paused) time.
    @Published var autoStopMinutes: Int
    @Published private(set) var countdownRemaining: Int?
    /// 「当前文件 · 剩余空间」 while recording, refreshed once a second.
    @Published private(set) var liveStorageNote: String = ""

    let recorder = ScreenRecorder()
    let camera = CameraController()
    let effects = EffectsOverlay()
    let cursorTracker = CursorTracker()
    private let selfTestBackdrop = SelfTestBackdrop()
    /// Long-lived read access to the save folder so 分享 / 拷贝 / 访达 work on
    /// files in a user-picked folder (sandbox). Opened on first use.
    private var shareAccess: SaveLocation.Access?
    /// Snapshot-only: show both 原片 and 缩放版 even if the files are not there.
    @Published private(set) var previewBothVersions = false
    private var trackedFPS = 30
    private let regionSelector = RegionSelector()

    private var delivered = false
    private var quitting = false
    private var chain: Task<Void, Never>?
    private var cardToken = 0
    /// First permission failure this session: the system already shows its
    /// own prompt, so we do not stack our help card on top of it.
    private var permissionHelpShownThisSession = false
    private var elapsedTimer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var skipCountdownOnce = false
    let recordingBorder = RecordingBorder()
    let countdownOverlay = CountdownOverlay()
    let recordingBar = RecordingBarController()
    let reviewWindow = ReviewWindowController()
    var onMainChromeVisible: ((Bool) -> Void)?
    /// Set when the current take was paused at least once (自动缩放 is skipped then:
    /// its cursor timeline is in wall-clock time).
    private var takeWasPaused = false
    private var autoStopped = false

    static var isRunningForPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    static var isRunningSelfTest: Bool {
        CommandLine.arguments.contains(where: { $0.hasPrefix("--self-test") })
    }

    /// Hide the main bar, show the compact recording bar, and open the review
    /// window. Other self-tests keep the previous chrome so their layout and
    /// pause timing stay the same.
    var shouldUseNewRecordingFlow: Bool {
        if CommandLine.arguments.contains("--self-test-recording-chrome") {
            return true
        }
        return !Self.isRunningSelfTest
    }

    /// 省电 is opt-in. Defaults stay near-native, cap 3840, 30 fps.
    var effectiveMaxSide: Int { powerSaver ? 1920 : qualityCap }
    var effectiveFPS: Int { powerSaver ? 15 : frameRate }

    var elapsedLabel: String { CaptureGeometry.elapsedLabel(elapsedSeconds) }

    var isCountingDown: Bool { countdownRemaining != nil }

    var showsElapsed: Bool {
        phase == .starting || phase == .recording || phase == .stopping
    }

    var isSourceLocked: Bool { phase != .idle }

    var sourceHelp: String {
        if let region {
            return "区域 \(Int(region.width.rounded())) × \(Int(region.height.rounded()))"
        }
        return "选择显示器或区域"
    }

    var sourceLabel: String {
        if region != nil { return "已选择区域，打开范围设置" }
        return "选择录制范围"
    }

    var microphoneHelp: String {
        if phase != .idle { return "录制结束后可开关麦克风" }
        return microphoneEnabled ? "麦克风：开" : "麦克风：关"
    }

    var microphoneLabel: String {
        if phase != .idle { return "录制中，麦克风已锁定" }
        return microphoneEnabled ? "关闭麦克风" : "打开麦克风"
    }

    var cameraHelp: String {
        if phase != .idle { return "录制结束后可开关摄像头" }
        return cameraOn ? "摄像头：开" : "摄像头：关"
    }

    var cameraLabel: String {
        if phase != .idle { return "录制中，摄像头已锁定" }
        return cameraOn ? "关闭摄像头" : "打开摄像头"
    }


    init() {
        let storedEdge = UserDefaults.standard.string(forKey: Keys.edge) ?? DockEdge.right.rawValue
        edge = DockEdge(rawValue: storedEdge) ?? .right
        let storedFloating = UserDefaults.standard.bool(forKey: "ljm.floating")
        floating = storedFloating
        miniDock = false
        Metrics.dockFactor = 1
        if UserDefaults.standard.object(forKey: Keys.audio) == nil {
            systemAudioEnabled = true
        } else {
            systemAudioEnabled = UserDefaults.standard.bool(forKey: Keys.audio)
        }
        microphoneEnabled = false
        cameraShape = camera.shape
        let cap = UserDefaults.standard.object(forKey: Keys.qualityCap) as? Int
        qualityCap = [1920, 2560, 3840].contains(cap ?? -1) ? cap! : 3840
        let fps = UserDefaults.standard.object(forKey: Keys.frameRate) as? Int
        frameRate = (fps == 30 || fps == 60) ? fps! : 30
        powerSaver = UserDefaults.standard.bool(forKey: Keys.powerSaver)
        cursorHighlight = UserDefaults.standard.bool(forKey: Keys.cursorHighlight)
        clickRipples = UserDefaults.standard.bool(forKey: Keys.clickRipples)
        watermarkEnabled = UserDefaults.standard.bool(forKey: Keys.watermark)
        watermarkText = UserDefaults.standard.string(forKey: Keys.watermarkText) ?? EffectsConfig.defaultWatermarkText
        watermarkCorner = WatermarkCorner(rawValue: UserDefaults.standard.string(forKey: Keys.watermarkCorner) ?? "") ?? .bottomRight
        autoZoom = UserDefaults.standard.bool(forKey: Keys.autoZoom)
        let storedZoom = UserDefaults.standard.double(forKey: Keys.zoomFactor)
        zoomFactor = [1.5, 1.8, 2.0].contains(storedZoom) ? storedZoom : 1.8
        if let stored = UserDefaults.standard.object(forKey: Keys.countdown) as? Bool {
            countdownEnabled = stored
        } else {
            countdownEnabled = true
        }
        startSound = UserDefaults.standard.bool(forKey: Keys.startSound)
        showBorder = UserDefaults.standard.bool(forKey: Keys.border)
        playAfterRecording = UserDefaults.standard.bool(forKey: Keys.playAfter)
        revealAfterRecording = UserDefaults.standard.bool(forKey: Keys.revealAfter)
        let storedStop = UserDefaults.standard.integer(forKey: Keys.autoStop)
        autoStopMinutes = Self.autoStopChoices.contains(storedStop) ? storedStop : 0
        if let storedID = UserDefaults.standard.object(forKey: Keys.displayID) as? Int, storedID != 0 {
            displayID = CGDirectDisplayID(storedID)
        } else {
            displayID = CGMainDisplayID()
        }
        if let stored = UserDefaults.standard.string(forKey: Keys.region), !stored.isEmpty {
            let rect = NSRectFromString(stored)
            if rect.width >= 64, rect.height >= 64 {
                region = rect
            }
        }
        if let path = UserDefaults.standard.string(forKey: Keys.lastFile) {
            let url = URL(fileURLWithPath: path)
            if let access = try? SaveLocation.beginAccess() {
                defer { access.stop() }
                if FileManager.default.fileExists(atPath: url.path) {
                    lastSavedURL = url
                }
            } else if FileManager.default.fileExists(atPath: url.path) {
                lastSavedURL = url
            }
        }
        recorder.onInterrupted = { [weak self] result in
            Task { @MainActor in
                self?.deliver(result)
            }
        }
        camera.onShapeChange = { [weak self] shape in
            self?.cameraShape = shape
        }
        refreshFolderPath()
        recordingBar.attach(model: self)
    }

    /// Restore persisted mic/camera only if already authorized. Never prompt at launch.
    func restoreDevices() {
        if UserDefaults.standard.bool(forKey: Keys.microphone), Permissions.microphoneAuthorized() {
            microphoneEnabled = true
        }
        guard UserDefaults.standard.bool(forKey: Keys.camera), Permissions.cameraAuthorized() else { return }
        guard let screen = NSScreen.screens.first(where: { displayID(of: $0) == displayID }) ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        cameraBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.cameraBusy = false }
            do {
                try await self.camera.start(on: screen, region: self.region, requestAccess: false)
                self.cameraOn = true
                self.cameraShape = self.camera.shape
            } catch {
                self.cameraOn = false
                UserDefaults.standard.set(false, forKey: Keys.camera)
            }
        }
    }

    func bumpLayout() {
        layoutTick += 1
    }

    func noteChromeSize(_ size: CGSize) {
        guard size.width > 40, size.height > 40 else { return }
        // Ignore sub-point hover-shadow jitter so a lift/sink cannot refit the
        // window out from under the cursor as the user presses to drag.
        guard abs(size.width - chromeSize.width) > 4 || abs(size.height - chromeSize.height) > 4 else { return }
        chromeSize = size
    }

    func toggleRecord() {
        regionSelector.cancel()
        if isCountingDown {
            cancelCountdown()
            return
        }
        switch phase {
        case .idle:
            startRecording()
        case .recording, .starting:
            stopRecording()
        case .stopping:
            break
        }
    }

    // MARK: - Round 1: pause, countdown, border, after-take, auto stop, defaults

    static let autoStopChoices = [0, 15, 30, 60]

    func togglePause() {
        guard phase == .recording else { return }
        if paused {
            recorder.resume()
            paused = false
        } else {
            recorder.pause()
            paused = true
            takeWasPaused = true
        }
        recordingBorder.setPaused(paused)
        recordingBar.reload()
        AppDelegate.shared?.refreshStatusItemTitle()
        bumpLayout()
    }

    var pauseLabel: String { paused ? "继续录制" : "暂停录制" }

    func toggleCountdown() {
        countdownEnabled.toggle()
        UserDefaults.standard.set(countdownEnabled, forKey: Keys.countdown)
    }

    func toggleStartSound() {
        startSound.toggle()
        UserDefaults.standard.set(startSound, forKey: Keys.startSound)
    }

    func toggleBorder() {
        showBorder.toggle()
        UserDefaults.standard.set(showBorder, forKey: Keys.border)
        if phase == .recording {
            if showBorder { showRecordingBorder() } else { recordingBorder.hide() }
        }
    }

    func togglePlayAfter() {
        playAfterRecording.toggle()
        UserDefaults.standard.set(playAfterRecording, forKey: Keys.playAfter)
    }

    func toggleRevealAfter() {
        revealAfterRecording.toggle()
        UserDefaults.standard.set(revealAfterRecording, forKey: Keys.revealAfter)
    }

    func setAutoStop(_ minutes: Int) {
        guard Self.autoStopChoices.contains(minutes) else { return }
        autoStopMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: Keys.autoStop)
    }

    /// Settings back to defaults. Keeps the save-folder bookmark, recent file,
    /// bar placement, chosen display/region, and mic/camera device state.
    func setCameraShape(_ value: CameraShape) {
        camera.setShape(value)
        cameraShape = camera.shape
        bumpLayout()
    }

    func restoreDefaultSettings() {
        guard phase == .idle, !isCountingDown else { return }
        let keys = [
            Keys.audio, Keys.qualityCap, Keys.frameRate, Keys.powerSaver,
            Keys.cursorHighlight, Keys.clickRipples, Keys.watermark, Keys.watermarkText,
            Keys.watermarkCorner, Keys.autoZoom, Keys.zoomFactor,
            Keys.countdown, Keys.startSound, Keys.border, Keys.playAfter, Keys.revealAfter, Keys.autoStop,
        ]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        systemAudioEnabled = true
        qualityCap = 3840
        frameRate = 30
        powerSaver = false
        cursorHighlight = false
        clickRipples = false
        watermarkEnabled = false
        watermarkText = EffectsConfig.defaultWatermarkText
        watermarkCorner = .bottomRight
        autoZoom = false
        zoomFactor = 1.8
        countdownEnabled = true
        startSound = false
        showBorder = false
        playAfterRecording = false
        revealAfterRecording = false
        autoStopMinutes = 0
        camera.setShape(.circle)
        cameraShape = .circle
        bumpLayout()
    }

    private func beginCountdown() {
        guard let screen = recordingScreen else {
            skipCountdownOnce = true
            startRecording()
            return
        }
        reviewWindow.hide()
        hideMainChromeForRecording()
        let region = region
        countdownRemaining = 3
        countdownOverlay.show(3, on: screen, region: region)
        bumpLayout()
        countdownTask = Task { @MainActor [weak self] in
            for value in [3, 2, 1] {
                guard let self, !Task.isCancelled else { return }
                self.countdownRemaining = value
                self.countdownOverlay.show(value, on: screen, region: region)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.countdownOverlay.hide()
            self.countdownRemaining = nil
            self.countdownTask = nil
            self.skipCountdownOnce = true
            self.startRecording()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownOverlay.hide()
        countdownRemaining = nil
        if phase == .idle {
            restoreMainChrome()
        }
        bumpLayout()
    }

    private var recordingScreen: NSScreen? {
        NSScreen.screens.first(where: { displayID(of: $0) == displayID }) ?? NSScreen.main
    }

    private func showRecordingBorder() {
        guard let screen = recordingScreen else { return }
        recordingBorder.show(on: screen, region: region)
        recordingBorder.setPaused(paused)
    }

    private func refreshLiveStorage() {
        guard phase == .recording else {
            if !liveStorageNote.isEmpty { liveStorageNote = "" }
            return
        }
        var parts: [String] = []
        if let url = recorder.currentPartialURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
            parts.append("当前文件 " + ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file))
        }
        if let folder = recorder.currentFolderURL,
           let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            parts.append("剩余 " + ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
        }
        let note = parts.joined(separator: " · ")
        if note != liveStorageNote { liveStorageNote = note }
    }

    /// After-take actions on the final file (the zoom version when one was made).
    private func runAfterTakeActions(_ url: URL) {
        guard !quitting else { return }
        if revealAfterRecording {
            revealInFinder(url)
        }
        // Review already plays the file. Only open a system player when the
        // user turned that extra option on and the review window is not used
        // (self-tests), or they explicitly still want both.
        if playAfterRecording, !shouldUseNewRecordingFlow {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleSystemAudio() {
        guard phase == .idle else { return }
        systemAudioEnabled.toggle()
        UserDefaults.standard.set(systemAudioEnabled, forKey: Keys.audio)
    }

    func showSettings() {
        if case .settings = card {
            card = nil
        } else {
            refreshFolderPath()
            card = .settings
        }
        bumpLayout()
    }

    func showSource() {
        if case .source = card {
            card = nil
        } else {
            card = .source
        }
        bumpLayout()
    }

    func showMore() {
        if case .more = card {
            card = nil
        } else {
            card = .more
        }
        bumpLayout()
    }

    func dismissCard() {
        cardToken += 1
        card = nil
        bumpLayout()
    }

    func requestPermission() {
        if Permissions.request() {
            card = nil
            bumpLayout()
        }
    }

    func openPermissionSettings() {
        NSApp.activate()
        switch card {
        case .permission(.microphone):
            Permissions.openMicrophoneSettings()
        case .permission(.camera):
            Permissions.openCameraSettings()
        default:
            Permissions.openScreenRecordingSettings()
        }
    }

    func recheckPermission() {
        guard phase == .idle else { return }
        switch card {
        case .permission(.microphone):
            if Permissions.microphoneAuthorized() {
                card = nil
                bumpLayout()
            }
        case .permission(.camera):
            if Permissions.cameraAuthorized() {
                card = nil
                bumpLayout()
            }
        default:
            enqueue { [weak self] in
                guard let self else { return }
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    if case .permission(.screen) = self.card {
                        self.card = nil
                        self.bumpLayout()
                    }
                } catch {
                    self.card = .permission(.screen)
                    self.bumpLayout()
                }
            }
        }
    }

    /// Re-check after the user returns from System Settings. Never auto-starts a take, and never auto-enables mic or camera.
    func handleBecameActive() {
        guard phase == .idle else { return }
        if case .permission = card {
            recheckPermission()
        }
    }

    func toggleMicrophone() {
        guard phase == .idle else { return }
        if microphoneEnabled {
            microphoneEnabled = false
            UserDefaults.standard.set(false, forKey: Keys.microphone)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .authorized:
                self.microphoneEnabled = true
                UserDefaults.standard.set(true, forKey: Keys.microphone)
            case .notDetermined:
                if await AVCaptureDevice.requestAccess(for: .audio) {
                    self.microphoneEnabled = true
                    UserDefaults.standard.set(true, forKey: Keys.microphone)
                } else {
                    self.microphoneEnabled = false
                    UserDefaults.standard.set(false, forKey: Keys.microphone)
                    self.presentPermission(.microphone)
                }
            default:
                self.microphoneEnabled = false
                UserDefaults.standard.set(false, forKey: Keys.microphone)
                self.presentPermission(.microphone)
            }
        }
    }

    func toggleCamera() {
        guard phase == .idle, !cameraBusy else { return }
        if cameraOn {
            camera.stop()
            cameraOn = false
            UserDefaults.standard.set(false, forKey: Keys.camera)
            return
        }
        guard let screen = NSScreen.screens.first(where: { displayID(of: $0) == displayID }) ?? NSScreen.main ?? NSScreen.screens.first else {
            card = .error("请先选择可用显示器。")
            bumpLayout()
            return
        }
        cameraBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.cameraBusy = false }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            do {
                switch status {
                case .authorized:
                    try await self.camera.start(on: screen, region: self.region, requestAccess: false)
                    self.cameraOn = true
                    self.cameraShape = self.camera.shape
                    UserDefaults.standard.set(true, forKey: Keys.camera)
                case .notDetermined:
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    if granted {
                        try await self.camera.start(on: screen, region: self.region, requestAccess: false)
                        self.cameraOn = true
                        self.cameraShape = self.camera.shape
                        UserDefaults.standard.set(true, forKey: Keys.camera)
                    } else {
                        self.cameraOn = false
                        UserDefaults.standard.set(false, forKey: Keys.camera)
                        self.presentPermission(.camera)
                    }
                default:
                    self.cameraOn = false
                    UserDefaults.standard.set(false, forKey: Keys.camera)
                    self.presentPermission(.camera)
                }
            } catch {
                self.camera.stop()
                self.cameraOn = false
                UserDefaults.standard.set(false, forKey: Keys.camera)
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if !Permissions.cameraAuthorized() {
                    self.presentPermission(.camera)
                } else {
                    self.card = .error(message)
                    self.bumpLayout()
                }
            }
        }
    }

    private func presentPermission(_ kind: PermissionKind) {
        card = .permission(kind)
        bumpLayout()
    }

    func chooseFolder() {
        guard phase == .idle else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "新的录制会保存到这个文件夹。"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SaveLocation.storeBookmark(for: url)
            refreshFolderPath()
        } catch {
            card = .error("没能记住这个文件夹。\(error.localizedDescription)")
        }
    }

    func resetFolder() {
        guard phase == .idle else { return }
        SaveLocation.clearBookmark()
        refreshFolderPath()
    }

    func revealFolder() {
        guard let folder = accessibleSaveFolder() else {
            card = .error("打不开这个文件夹。")
            bumpLayout()
            return
        }
        revealURLInFinder(folder)
    }

    func openFolder() {
        revealFolder()
    }

    func reveal(_ url: URL) {
        revealInFinder(url)
    }

    func playLastVideo() {
        guard let url = lastSavedURL else { return }
        if let access = try? SaveLocation.beginAccess() {
            defer { access.stop() }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            NSWorkspace.shared.open(url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }

    func setQualityCap(_ value: Int) {
        guard phase == .idle, [1920, 2560, 3840].contains(value) else { return }
        qualityCap = value
        UserDefaults.standard.set(value, forKey: Keys.qualityCap)
    }

    func setFrameRate(_ value: Int) {
        guard phase == .idle, value == 30 || value == 60 else { return }
        frameRate = value
        UserDefaults.standard.set(value, forKey: Keys.frameRate)
    }

    func togglePowerSaver() {
        guard phase == .idle else { return }
        powerSaver.toggle()
        UserDefaults.standard.set(powerSaver, forKey: Keys.powerSaver)
    }

    // MARK: - 画面效果

    var effectsConfig: EffectsConfig {
        EffectsConfig(
            cursorHighlight: cursorHighlight,
            clickRipples: clickRipples,
            watermark: watermarkEnabled,
            watermarkText: watermarkText,
            watermarkCorner: watermarkCorner
        )
    }

    func toggleCursorHighlight() {
        guard phase == .idle else { return }
        cursorHighlight.toggle()
        UserDefaults.standard.set(cursorHighlight, forKey: Keys.cursorHighlight)
    }

    func toggleClickRipples() {
        guard phase == .idle else { return }
        clickRipples.toggle()
        UserDefaults.standard.set(clickRipples, forKey: Keys.clickRipples)
    }

    func toggleWatermark() {
        guard phase == .idle else { return }
        watermarkEnabled.toggle()
        UserDefaults.standard.set(watermarkEnabled, forKey: Keys.watermark)
        bumpLayout()
    }

    func setWatermarkText(_ value: String) {
        guard phase == .idle else { return }
        let clipped = String(value.prefix(24))
        watermarkText = clipped
        UserDefaults.standard.set(clipped, forKey: Keys.watermarkText)
    }

    func toggleAutoZoom() {
        guard phase == .idle, zoomProgress == nil else { return }
        autoZoom.toggle()
        UserDefaults.standard.set(autoZoom, forKey: Keys.autoZoom)
        bumpLayout()
    }

    func setZoomFactor(_ value: Double) {
        guard phase == .idle, zoomProgress == nil, [1.5, 1.8, 2.0].contains(value) else { return }
        zoomFactor = value
        UserDefaults.standard.set(value, forKey: Keys.zoomFactor)
    }

    var zoomProgressLabel: String {
        "\(Int(((zoomProgress ?? 0) * 100).rounded()))%"
    }

    private func startCursorTracking(displayID: CGDirectDisplayID, region: CGRect?, fps: Int) {
        guard let screen = NSScreen.screens.first(where: { self.displayID(of: $0) == displayID }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        trackedFPS = fps
        cursorTracker.start(screen: screen, region: region)
    }

    /// Writes `LJM-…-cursor.json` next to the take and renders `LJM-…-zoom.mp4`.
    /// The original file is never touched.
    private func makeZoomVersion(of url: URL, samples: [CursorTrack.Sample], sessionStart: Double, fps: Int, areaSize: CGSize, zoom: Double) async -> (url: URL?, note: String, result: ZoomRenderer.Result?) {
        guard sessionStart > 0 else { return (nil, "没有拿到画面起点，这次没有生成自动缩放版。", nil) }
        let track = CursorTrack(
            sessionStart: sessionStart,
            fps: fps,
            areaWidth: Double(areaSize.width),
            areaHeight: Double(areaSize.height),
            samples: samples
        )
        let access = try? SaveLocation.beginAccess()
        defer { access?.stop() }
        let base = url.deletingPathExtension()
        let sidecar = URL(fileURLWithPath: base.path + "-cursor.json")
        if let data = try? JSONEncoder().encode(track) {
            try? data.write(to: sidecar, options: .atomic)
        }
        guard track.clickCount > 0 else {
            return (nil, "这次录制里没有点击，没有生成自动缩放版。", nil)
        }
        let partial = URL(fileURLWithPath: base.path + "-zoom.partial.mp4")
        let final = URL(fileURLWithPath: base.path + "-zoom.mp4")
        zoomProgress = 0
        bumpLayout()
        defer {
            zoomProgress = nil
            bumpLayout()
        }
        do {
            let result = try await ZoomRenderer.render(source: url, output: partial, track: track, zoom: zoom) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.zoomProgress != nil else { return }
                    self.zoomProgress = fraction
                }
            }
            if FileManager.default.fileExists(atPath: final.path) {
                try FileManager.default.removeItem(at: final)
            }
            try FileManager.default.moveItem(at: partial, to: final)
            return (final, "已生成自动缩放版，原片也保留了。", result)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (nil, "自动缩放版没能生成：\(message) 原片不受影响。", nil)
        }
    }

    func setWatermarkCorner(_ value: WatermarkCorner) {
        guard phase == .idle else { return }
        watermarkCorner = value
        UserDefaults.standard.set(value.rawValue, forKey: Keys.watermarkCorner)
    }

    /// Test hook for the UI snapshot: opens 更多 and shows the switches in the
    /// given state for this launch only. Nothing is written to UserDefaults.
    /// --self-test-zoom-render <source.mp4> <cursor.json> <output.mp4>
    /// Re-renders an existing take (e.g. a deliberately sparse VFR copy) so the
    /// in-between-frame path can be checked. Writes zoom-render-result.txt and
    /// zoom-trace.csv into ~/Movies/LJM (app container), then quits.
    func runZoomRenderSelfTest() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--self-test-zoom-render"), args.count > flag + 3 else {
            NSApp.terminate(nil)
            return
        }
        let source = URL(fileURLWithPath: args[flag + 1])
        let json = URL(fileURLWithPath: args[flag + 2])
        let output = URL(fileURLWithPath: args[flag + 3])
        Task { @MainActor in
            self.ensureShareAccess()
            var report = "source=\(source.path)\n"
            do {
                let track = try JSONDecoder().decode(CursorTrack.self, from: Data(contentsOf: json))
                let started = Date()
                let r = try await ZoomRenderer.render(source: source, output: output, track: track, zoom: 1.8) { _ in }
                report += String(format: "OK frames=%d filled=%d bitRate=%d sourceBitRate=%d segments=%@ renderSeconds=%.2f\n", r.frames, r.filledFrames, r.bitRate, r.sourceBitRate, r.segments, Date().timeIntervalSince(started))
                report += "output=\(output.path)\n"
                if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
                    try? Data(("pts,scale,cx,cy,filled\n" + r.trace.joined(separator: "\n") + "\n").utf8)
                        .write(to: movies.appendingPathComponent("LJM/zoom-trace.csv"), options: .atomic)
                }
            } catch {
                report += "FAILED \(error.localizedDescription)\n"
            }
            if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
                try? Data(report.utf8).write(to: movies.appendingPathComponent("LJM/zoom-render-result.txt"), options: .atomic)
            }
            NSApp.terminate(nil)
        }
    }

    /// Test hook for the share snapshot: a 已保存 card with both versions.
    func previewSharingCard() {
        previewBothVersions = true
        let folder = (try? SaveLocation.beginAccess())?.directory ?? URL(fileURLWithPath: NSHomeDirectory())
        let sample = folder.appendingPathComponent("LJM-2026-11-13-12-00-00-zoom.mp4")
        card = .saved(sample, note: "已生成自动缩放版，原片也保留了。")
        // In-memory only (not written to defaults), so 更多 shows its
        // 「最近的视频」 share row in the snapshot too.
        lastSavedURL = sample
        bumpLayout()
    }

    // MARK: - 分享

    struct RecordingVersion: Hashable {
        let title: String
        let url: URL
    }

    private func ensureShareAccess() {
        if shareAccess == nil {
            shareAccess = try? SaveLocation.beginAccess()
        }
    }

    /// 原片 and, if it exists, the 自动缩放 version of the same take.
    func versions(for url: URL) -> [RecordingVersion] {
        ensureShareAccess()
        let directory = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let originalName = name.hasSuffix("-zoom") ? String(name.dropLast(5)) : name
        let original = directory.appendingPathComponent(originalName + ".mp4")
        let zoomed = directory.appendingPathComponent(originalName + "-zoom.mp4")
        var list: [RecordingVersion] = []
        if previewBothVersions || FileManager.default.fileExists(atPath: original.path) {
            list.append(RecordingVersion(title: "原片", url: original))
        }
        if previewBothVersions || FileManager.default.fileExists(atPath: zoomed.path) {
            list.append(RecordingVersion(title: "缩放版", url: zoomed))
        }
        return list.isEmpty ? [RecordingVersion(title: "原片", url: url)] : list
    }

    func revealInFinder(_ url: URL) {
        revealURLInFinder(url)
    }

    /// Holds the security-scoped save-folder access for as long as the process
    /// needs to hand a file to Finder or the share picker.
    private func accessibleSaveFolder() -> URL? {
        ensureShareAccess()
        return shareAccess?.directory
    }

    /// Opens Finder on `url` from a nonactivating panel. Keeps the save-folder
    /// bookmark access alive, activates this app first, then brings Finder forward.
    @discardableResult
    private func revealURLInFinder(_ url: URL) -> Bool {
        ensureShareAccess()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let parent = url.deletingLastPathComponent()
        let parentExists = fileManager.fileExists(atPath: parent.path)
        if !exists, !parentExists {
            card = .error("找不到这个文件。")
            bumpLayout()
            return false
        }
        let folder = (exists && isDirectory.boolValue) ? url : parent
        let file = (exists && !isDirectory.boolValue) ? url : nil

        NSApp.activate()

        var shown = false
        if let file {
            shown = NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: folder.path)
        }
        if !shown {
            NSWorkspace.shared.activateFileViewerSelecting([file ?? folder])
        }
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            finder.activate(options: [.activateIgnoringOtherApps])
        } else if !shown {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(folder, configuration: configuration) { [weak self] _, error in
                if error != nil {
                    Task { @MainActor in
                        self?.card = .error("打不开访达。")
                        self?.bumpLayout()
                    }
                }
            }
        }
        if !exists {
            card = .error("找不到这个文件，已打开它所在的文件夹。")
            bumpLayout()
        }
        return shown || parentExists || exists
    }

    /// Hidden hook for --self-test-reveal. Writes a tiny text file (not a recording),
    /// asks Finder to show it, then records whether Finder came forward.
    func runCameraShapeSelfTest() {
        var report = "started \(ISO8601DateFormatter().string(from: Date()))\n"
        report += CameraShapeSelfTest.run()
        if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            let dir = movies.appendingPathComponent("LJM", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(report.utf8).write(to: dir.appendingPathComponent("camera-shape-self-test-result.txt"), options: .atomic)
        }
        writeSelfTestReport(report)
        NSApp.terminate(nil)
    }

    /// --self-test-recording-chrome: hide the main bar, show a countdown 3,
    /// place the compact recording bar at bottom-right, drag from chrome,
    /// shrink after leave, expand only after a 1.5s chrome dwell, and open
    /// review on a fixture file. Does not start a capture or the camera.
    func runRecordingChromeSelfTest() {
        Task { @MainActor in
            var checks: [(String, Bool)] = []
            func mark(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
            func nearly(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 2) -> Bool { abs(a - b) <= tol }

            hideMainChromeForRecording()
            try? await Task.sleep(nanoseconds: 80_000_000)
            mark("hideMainBar", AppDelegate.shared?.isCapsuleVisible == false)

            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                mark("screen", false)
                self.finishRecordingChromeSelfTest(checks)
                return
            }

            countdownOverlay.show(3, on: screen, region: nil)
            try? await Task.sleep(nanoseconds: 80_000_000)
            mark("countdownShown", countdownOverlay.isVisible)
            countdownOverlay.hide()
            mark("countdownHidden", !countdownOverlay.isVisible)

            recordingBar.shrinkDelay = 0.25
            recordingBar.expandDelay = 1.5
            let margin = recordingBar.edgeMargin

            // Region placement: bottom-right of the recorded region, not centered.
            let region = CGRect(x: 180, y: 120, width: 860, height: 520)
            recordingBar.show(on: screen, region: region)
            recordingBar.reload()
            try? await Task.sleep(nanoseconds: 80_000_000)
            let recordedRegion = RecordingChromeGeometry.area(on: screen, region: region)
            let regionFrame = recordingBar.windowFrame ?? .zero
            mark("regionBottomRightX", nearly(regionFrame.maxX, recordedRegion.maxX - margin))
            mark("regionBottomRightY", nearly(regionFrame.minY, recordedRegion.minY + margin))
            mark("regionNotCentered", abs(regionFrame.midX - recordedRegion.midX) > 20)
            recordingBar.hide()

            recordingBar.show(on: screen, region: nil)
            recordingBar.reload()
            try? await Task.sleep(nanoseconds: 80_000_000)
            mark("compactVisible", recordingBar.isVisible)
            mark("compactExpanded", recordingBar.isExpanded)
            let fullWidth = recordingBar.windowFrame?.width ?? 0
            mark("compactWide", fullWidth >= 300)

            let visible = screen.visibleFrame
            let startFrame = recordingBar.windowFrame ?? .zero
            mark("defaultBottomRightX", nearly(startFrame.maxX, visible.maxX - margin))
            mark("defaultBottomRightY", nearly(startFrame.minY, visible.minY + margin))
            mark("defaultNotCentered", abs(startFrame.midX - visible.midX) > 20)

            if let chrome = recordingBar.chromeTestPoint(), let button = recordingBar.buttonTestPoint() {
                mark("chromeHit", recordingBar.zone(atViewPoint: chrome) == .chrome)
                mark("buttonHit", recordingBar.zone(atViewPoint: button) == .button)
            } else {
                mark("chromeHit", false)
                mark("buttonHit", false)
            }

            let beforeDrag = recordingBar.windowFrame ?? .zero
            let delta = CGPoint(x: -120, y: 80)
            let afterChromeDrag = recordingBar.performTestDrag(from: .chrome, delta: delta) ?? .zero
            mark("chromeDragMovedX", nearly(afterChromeDrag.origin.x, beforeDrag.origin.x + delta.x, 3))
            mark("chromeDragMovedY", nearly(afterChromeDrag.origin.y, beforeDrag.origin.y + delta.y, 3))

            let beforeButton = recordingBar.windowFrame ?? .zero
            let afterButtonDrag = recordingBar.performTestDrag(from: .button, delta: CGPoint(x: -60, y: 40)) ?? .zero
            mark("buttonDoesNotDrag", nearly(afterButtonDrag.origin.x, beforeButton.origin.x) && nearly(afterButtonDrag.origin.y, beforeButton.origin.y))

            recordingBar.setExpanded(false, animated: false)
            try? await Task.sleep(nanoseconds: 80_000_000)
            mark("forcedShrink", recordingBar.isExpanded == false)
            let miniWidth = recordingBar.windowFrame?.width ?? 0
            mark("miniNarrow", miniWidth > 40 && miniWidth < 160)
            let afterShrink = recordingBar.windowFrame ?? .zero
            mark("shrinkKeepsRight", nearly(afterShrink.maxX, beforeButton.maxX, 3))
            mark("shrinkKeepsBottom", nearly(afterShrink.minY, beforeButton.minY, 3))

            if let chrome = recordingBar.chromeTestPoint(), let button = recordingBar.buttonTestPoint() {
                mark("shrunkChromeHit", recordingBar.zone(atViewPoint: chrome) == .chrome)
                mark("shrunkButtonHit", recordingBar.zone(atViewPoint: button) == .button)
                mark("shrunkHasChrome", chrome.x < button.x - 8)
            } else {
                mark("shrunkChromeHit", false)
                mark("shrunkButtonHit", false)
                mark("shrunkHasChrome", false)
            }

            recordingBar.setExpanded(true, animated: false)
            try? await Task.sleep(nanoseconds: 80_000_000)
            mark("forcedExpand", recordingBar.isExpanded)
            let afterExpand = recordingBar.windowFrame ?? .zero
            mark("expandKeepsRight", nearly(afterExpand.maxX, afterShrink.maxX, 3))
            mark("expandKeepsBottom", nearly(afterExpand.minY, afterShrink.minY, 3))

            recordingBar.simulateZone(.outside)
            try? await Task.sleep(nanoseconds: 450_000_000)
            mark("autoShrink", recordingBar.isExpanded == false)
            let afterAutoShrink = recordingBar.windowFrame ?? .zero
            mark("autoShrinkStays", nearly(afterAutoShrink.maxX, afterExpand.maxX, 3) && nearly(afterAutoShrink.minY, afterExpand.minY, 3))

            recordingBar.simulateZone(.chrome)
            try? await Task.sleep(nanoseconds: 80_000_000)
            mark("noImmediateExpand", recordingBar.isExpanded == false)

            try? await Task.sleep(nanoseconds: 400_000_000)
            mark("dwellStillPending", recordingBar.isExpanded == false)
            recordingBar.simulateZone(.outside)
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            mark("earlyLeaveNoExpand", recordingBar.isExpanded == false)

            recordingBar.simulateZone(.button)
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            mark("buttonHoverNoExpand", recordingBar.isExpanded == false)

            recordingBar.simulateZone(.chrome)
            try? await Task.sleep(nanoseconds: 400_000_000)
            mark("dwellNotYet", recordingBar.isExpanded == false)
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            mark("chromeDwellExpands", recordingBar.isExpanded)

            // A new show (new take) returns to bottom-right, not the dragged spot.
            recordingBar.hide()
            recordingBar.show(on: screen, region: nil)
            recordingBar.reload()
            try? await Task.sleep(nanoseconds: 80_000_000)
            let reshow = recordingBar.windowFrame ?? .zero
            mark("reshowBottomRightX", nearly(reshow.maxX, visible.maxX - margin))
            mark("reshowBottomRightY", nearly(reshow.minY, visible.minY + margin))

            recordingBar.hide()
            mark("barHidden", recordingBar.isVisible == false)

            restoreMainChrome()
            try? await Task.sleep(nanoseconds: 80_000_000)
            mark("showMainBar", AppDelegate.shared?.isCapsuleVisible == true)

            if let fixture = reviewFixtureURL() {
                reviewWindow.show(file: fixture)
                try? await Task.sleep(nanoseconds: 200_000_000)
                mark("reviewVisible", reviewWindow.isVisible)
                mark("reviewCurrent", reviewWindow.currentURL?.path == fixture.path)
                mark("reviewList", reviewWindow.listedCount >= 1)
                reviewWindow.hide()
                try? await Task.sleep(nanoseconds: 80_000_000)
                mark("reviewHidden", reviewWindow.isVisible == false)
            } else {
                mark("reviewFixture", false)
            }

            finishRecordingChromeSelfTest(checks)
        }
    }

    private func reviewFixtureURL() -> URL? {
        if let last = lastSavedURL, FileManager.default.fileExists(atPath: last.path) {
            return last
        }
        if let path = UserDefaults.standard.string(forKey: Keys.lastFile) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let access = try? SaveLocation.beginAccess() {
            defer { access.stop() }
            if let first = SaveLocation.listRecordings(in: access.directory, limit: 1).first {
                return first.url
            }
        }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/录屏档案区")
        return SaveLocation.listRecordings(in: desktop, limit: 1).first?.url
    }

    private func finishRecordingChromeSelfTest(_ checks: [(String, Bool)]) {
        let failed = checks.filter { !$0.1 }.map(\.0)
        var report = "started \(ISO8601DateFormatter().string(from: Date()))\n"
        report += "ok=\(failed.isEmpty)\n"
        for (name, ok) in checks {
            report += "\(name)=\(ok ? "pass" : "FAIL")\n"
        }
        if failed.isEmpty {
            report += "all recording-chrome checks passed\n"
        } else {
            report += "failed: \(failed.joined(separator: ","))\n"
        }
        if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            let dir = movies.appendingPathComponent("LJM", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(report.utf8).write(to: dir.appendingPathComponent("recording-chrome-self-test-result.txt"), options: .atomic)
        }
        writeSelfTestReport(report)
        NSApp.terminate(nil)
    }

    func runRevealSelfTest() {
        Task { @MainActor in
            ensureShareAccess()
            let folder = accessibleSaveFolder() ?? FileManager.default.temporaryDirectory
            let file = folder.appendingPathComponent("LJM-reveal-self-test.txt")
            try? "reveal-self-test\n".write(to: file, atomically: true, encoding: .utf8)
            let shown = revealURLInFinder(file)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            let exists = FileManager.default.fileExists(atPath: file.path)
            let lines = [
                "shown=\(shown)",
                "front=\(front)",
                "exists=\(exists)",
                "path=\(file.path)"
            ]
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("LJM", isDirectory: true)
            if let movies {
                try? FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
                try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?
                    .write(to: movies.appendingPathComponent("reveal-self-test-result.txt"), options: .atomic)
            }
            NSApp.terminate(nil)
        }
    }

    /// Puts the file itself on the clipboard (paste in Finder, 信息, 邮件…).
    func copyFile(_ url: URL) {
        ensureShareAccess()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    /// Keep the 已保存 card up while the user is choosing how to share.
    func holdSavedCard() {
        cardToken += 1
    }

    func previewEffectsCard(allOn: Bool) {
        cursorHighlight = allOn
        clickRipples = allOn
        watermarkEnabled = allOn
        autoZoom = allOn
        card = .more
        bumpLayout()
    }

    /// Puts the recordable effects layer on the take's display. Returns its
    /// window number so ScreenCaptureKit keeps it in the recording.
    private func showEffects(displayID: CGDirectDisplayID, region: CGRect?, config: EffectsConfig) -> [Int] {
        guard config.isActive,
              let screen = NSScreen.screens.first(where: { self.displayID(of: $0) == displayID }) ?? NSScreen.main ?? NSScreen.screens.first
        else {
            effects.hide()
            return []
        }
        effects.show(on: screen, region: region, config: config)
        return effects.windowID.map { [$0] } ?? []
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        guard phase == .idle else { return }
        displayID = id
        region = nil
        persistSource()
        card = nil
        bumpLayout()
    }

    func beginRegionSelection() {
        guard phase == .idle else { return }
        card = nil
        bumpLayout()
        regionSelector.begin { [weak self] id, rect in
            guard let self else { return }
            // Overlay is already torn down before this callback runs.
            self.displayID = id
            self.region = rect
            self.persistSource()
            self.bumpLayout()
        }
    }

    func clearRegion() {
        guard phase == .idle else { return }
        region = nil
        persistSource()
        bumpLayout()
    }

    func quit() {
        regionSelector.cancel()
        shutdownDevices()
        NSApp.terminate(nil)
    }

    func shutdownDevices() {
        effects.hide()
        camera.stop()
        cameraOn = false
        cameraBusy = false
    }

    func prepareToQuit() async {
        quitting = true
        regionSelector.cancel()
        shutdownDevices()
        recordingBar.hide()
        reviewWindow.hide()
        stopElapsedTimer()
        guard phase != .idle else { return }
        phase = .stopping
        enqueue { [weak self] in
            guard let self else { return }
            if self.recorderIsActive {
                _ = await self.recorder.stop()
            }
            self.phase = .idle
            self.stopElapsedTimer()
        }
        await chain?.value
    }

    /// Records a few seconds (or a 30s max-settings stress take), writes a result file, then quits.
    /// Triggered by --self-test-record. Add --self-test-stress for 3840 cap, 60 fps, 省电 off,
    /// system audio on, and camera/mic on if already authorized (never prompts).
    func runSelfTest() {
        enqueue { [weak self] in
            guard let self else { return }
            let stress = CommandLine.arguments.contains("--self-test-stress")
            var report = "started \(ISO8601DateFormatter().string(from: Date()))\n"
            let fps = stress ? 60 : 30
            let testZoom = CommandLine.arguments.contains("--self-test-zoom")
            let testStatic = CommandLine.arguments.contains("--self-test-static")
            let testPause = CommandLine.arguments.contains("--self-test-pause")
            let durationNs: UInt64 = stress ? 30_500_000_000 : (testZoom ? 6_500_000_000 : 3_500_000_000)
            if stress {
                report += "mode=stress quality=3840@60 powerSaver=off duration=30.5s\n"
            } else {
                report += "quality=3840@30 powerSaver=off (self-test forced defaults)\n"
            }
            let testEffects = CommandLine.arguments.contains("--self-test-effects")
            // --self-test-no-system-audio: microphone-only (or silent) take.
            let useSystemAudio = !CommandLine.arguments.contains("--self-test-no-system-audio")
            var useMic = CommandLine.arguments.contains("--self-test-mic") || stress
            var useCam = CommandLine.arguments.contains("--self-test-camera") || stress
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
            report += "tcc microphone=\(Self.tccName(micStatus)) camera=\(Self.tccName(camStatus))\n"
            if useMic && micStatus != .authorized {
                report += "MIC_SKIPPED not authorized (will not prompt)\n"
                useMic = false
            }
            if useCam && camStatus != .authorized {
                report += "CAMERA_SKIPPED not authorized (will not prompt)\n"
                useCam = false
            }
            report += "mic=\(useMic) camera=\(useCam) systemAudio=\(useSystemAudio) fps=\(fps)\n"
            var cursorNudge: Timer?
            let cursorOrigin = NSEvent.mouseLocation
            do {
                if useCam, let screen = NSScreen.main ?? NSScreen.screens.first {
                    try await self.camera.start(on: screen, region: nil, requestAccess: false)
                    self.cameraOn = true
                    report += "cameraWindowID=\(self.camera.windowID.map(String.init) ?? "nil")\n"
                }
                var overlayIDs: [Int] = []
                if testEffects {
                    // Self-test only: never touches the persisted 画面效果 switches.
                    let config = EffectsConfig(
                        cursorHighlight: true,
                        clickRipples: true,
                        watermark: true,
                        watermarkText: EffectsConfig.defaultWatermarkText,
                        watermarkCorner: .bottomRight
                    )
                    overlayIDs = self.showEffects(displayID: CGMainDisplayID(), region: nil, config: config)
                    report += "effects=on overlayWindowID=\(overlayIDs.first.map(String.init) ?? "nil")\n"
                }
                if testStatic, let screen = NSScreen.screens.first(where: { self.displayID(of: $0) == CGMainDisplayID() }) ?? NSScreen.main {
                    // A fully still picture: only the pointer moves.
                    self.selfTestBackdrop.show(on: screen)
                    if let id = self.selfTestBackdrop.windowID { overlayIDs.append(id) }
                    report += "static=on backdropWindowID=\(self.selfTestBackdrop.windowID.map(String.init) ?? "nil")\n"
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
                try await self.recorder.start(
                    systemAudio: useSystemAudio,
                    microphone: useMic,
                    displayID: CGMainDisplayID(),
                    region: nil,
                    maxSide: 3840,
                    framesPerSecond: fps,
                    cameraWindowID: useCam ? self.camera.windowID : nil,
                    overlayWindowIDs: overlayIDs
                )
                if testZoom {
                    self.startCursorTracking(displayID: CGMainDisplayID(), region: nil, fps: fps)
                    report += "zoomTest=on factor=1.8\n"
                }
                if stress, !useCam, !testEffects, !testZoom {
                    cursorNudge = self.startStressCursorNudge(origin: cursorOrigin)
                }
                if testZoom {
                    try await self.driveZoomSelfTest(durationNs: durationNs)
                    self.restoreCursor(cursorOrigin)
                } else if testEffects {
                    try await self.driveEffectsSelfTest(durationNs: durationNs)
                    self.restoreCursor(cursorOrigin)
                } else if testPause {
                    // 2.5 s recorded, 3 s paused (dropped), 2.5 s recorded -> ~5 s file.
                    if let screen = NSScreen.screens.first(where: { self.displayID(of: $0) == CGMainDisplayID() }) ?? NSScreen.main {
                        self.recordingBorder.show(on: screen, region: nil)
                        report += "border.visible=\(self.recordingBorder.isVisible)\n"
                        self.countdownOverlay.show(3, on: screen, region: nil)
                        report += "countdown.shown=\(self.countdownOverlay.isVisible) value=\(self.countdownOverlay.shownValue ?? "nil")\n"
                        self.countdownOverlay.hide()
                    }
                    try await Task.sleep(nanoseconds: 2_500_000_000)
                    self.recorder.pause()
                    self.recordingBorder.setPaused(true)
                    report += "pause.isPaused=\(self.recorder.isPaused)\n"
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    self.recorder.resume()
                    self.recordingBorder.setPaused(false)
                    report += String(format: "pause.resumed=%@ pausedSeconds=%.2f count=%d\n", self.recorder.isPaused ? "false" : "true", self.recorder.pausedSeconds, self.recorder.pauseCount)
                    try await Task.sleep(nanoseconds: 2_500_000_000)
                    self.recordingBorder.hide()
                } else {
                    try await Task.sleep(nanoseconds: durationNs)
                }
                cursorNudge?.invalidate()
                if cursorNudge != nil {
                    self.restoreCursor(cursorOrigin)
                }
                let result = await self.recorder.stop()
                self.effects.hide()
                self.selfTestBackdrop.hide()
                let zoomSamples = self.cursorTracker.stop()
                if useCam {
                    self.camera.stop()
                    self.cameraOn = false
                }
                self.phase = .idle
                if let stats = self.recorder.lastStats {
                    report += "videoFrames=\(stats.videoFrames) audioFrames=\(stats.audioFrames) droppedVideo=\(stats.droppedVideo) droppedAudio=\(stats.droppedAudio)\n"
                    report += "audioDiag \(stats.audioNote)\n"
                }
                switch result {
                case .saved(let url, let note):
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                    report += "OK\npath=\(url.path)\nsize=\(size)\nnote=\(note ?? "")\n"
                    if testPause {
                        let asset = AVURLAsset(url: url)
                        let total = (try? await asset.load(.duration))?.seconds ?? -1
                        var trackLine = ""
                        for track in (try? await asset.load(.tracks)) ?? [] {
                            let range = try? await track.load(.timeRange)
                            trackLine += String(format: "%@=%.3f ", track.mediaType.rawValue, range?.duration.seconds ?? -1)
                        }
                        report += String(format: "pause.fileDuration=%.3f (expect ~5, not ~8) %@\n", total, trackLine)
                        report += "pause.droppedWhilePaused=\(self.recorder.lastStats?.pausedDropped ?? -1)\n"
                    }
                    if testZoom {
                        let started = Date()
                        let outcome = await self.makeZoomVersion(
                            of: url,
                            samples: zoomSamples,
                            sessionStart: self.recorder.lastStats?.sessionStartSeconds ?? 0,
                            fps: fps,
                            areaSize: self.cursorTracker.areaSize,
                            zoom: 1.8
                        )
                        report += "zoomSamples=\(zoomSamples.count) clicks=\(zoomSamples.filter { $0.c != 0 }.count)\n"
                        report += "zoomPath=\(outcome.url?.path ?? "nil")\nzoomNote=\(outcome.note)\n"
                        if let r = outcome.result {
                            report += String(format: "zoomFrames=%d filled=%d bitRate=%d sourceBitRate=%d segments=%@ renderSeconds=%.2f\n", r.frames, r.filledFrames, r.bitRate, r.sourceBitRate, r.segments, Date().timeIntervalSince(started))
                            if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
                                let traceURL = movies.appendingPathComponent("LJM/zoom-trace.csv")
                                try? Data(("pts,scale,cx,cy,filled\n" + r.trace.joined(separator: "\n") + "\n").utf8).write(to: traceURL, options: .atomic)
                                report += "zoomTrace=\(traceURL.path)\n"
                            }
                        }
                    }
                case .failed(let message):
                    report += "STOP_FAILED \(message)\n"
                }
            } catch {
                cursorNudge?.invalidate()
                _ = self.cursorTracker.stop()
                if cursorNudge != nil || testEffects || testZoom {
                    self.restoreCursor(cursorOrigin)
                }
                self.effects.hide()
                self.selfTestBackdrop.hide()
                let ns = error as NSError
                report += "START_FAILED \(error.localizedDescription)\n"
                report += "domain=\(ns.domain) code=\(ns.code)\n"
                report += "userInfo=\(ns.userInfo)\n"
            }
            self.writeSelfTestReport(report)
            NSApp.terminate(nil)
        }
    }

    /// Moves the pointer in a small loop near the main screen's centre and fires
    /// alternating left/right ripples straight into the overlay. No synthetic
    /// clicks are posted, so nothing underneath can be pressed by accident.
    private func driveEffectsSelfTest(durationNs: UInt64) async throws {
        guard let screen = NSScreen.screens.first(where: { displayID(of: $0) == CGMainDisplayID() }) ?? NSScreen.main else {
            try await Task.sleep(nanoseconds: durationNs)
            return
        }
        let center = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        let stepNs: UInt64 = 250_000_000
        let steps = max(1, Int(durationNs / stepNs))
        for index in 0..<steps {
            let angle = Double(index) * 0.6
            let point = NSPoint(x: center.x + CGFloat(cos(angle)) * 140, y: center.y + CGFloat(sin(angle)) * 90)
            AppModel.warpCursor(point)
            effects.pointerMoved(to: point)
            if index % 2 == 1 {
                effects.ripple(at: point, secondary: (index / 2) % 2 == 1)
            }
            try await Task.sleep(nanoseconds: stepNs)
        }
    }

    /// Zoom self-test path (main screen, bottom-left global points):
    /// 0–1.25 s rest near the left, left click at 1.5 s, glide right, right
    /// click at 2.25 s, glide until 3 s, then idle so the camera eases back.
    /// Clicks are fed to the tracker only; no real click is posted.
    private func driveZoomSelfTest(durationNs: UInt64) async throws {
        guard let screen = NSScreen.screens.first(where: { displayID(of: $0) == CGMainDisplayID() }) ?? NSScreen.main else {
            try await Task.sleep(nanoseconds: durationNs)
            return
        }
        let f = screen.frame
        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: f.minX + f.width * x, y: f.minY + f.height * y) }
        let rest = at(0.28, 0.58)
        let p1 = at(0.32, 0.55)
        let p2 = at(0.62, 0.45)
        let stepNs: UInt64 = 250_000_000
        let steps = max(1, Int(durationNs / stepNs))
        for index in 0..<steps {
            let point: NSPoint
            switch index {
            case 0..<5:
                point = NSPoint(x: rest.x + CGFloat(index) * 4, y: rest.y)
            case 5..<12:
                let k = CGFloat(index - 5) / 6
                point = NSPoint(x: p1.x + (p2.x - p1.x) * k, y: p1.y + (p2.y - p1.y) * k)
            default:
                point = p2
            }
            AppModel.warpCursor(point)
            cursorTracker.record(point, kind: 0)
            if index == 6 { cursorTracker.record(point, kind: 1) }
            if index == 9 { cursorTracker.record(point, kind: 2) }
            try await Task.sleep(nanoseconds: stepNs)
        }
    }

    private func startStressCursorNudge(origin: NSPoint) -> Timer {
        var tick = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            tick += 1
            let offset = CGFloat((tick % 2 == 0) ? 6 : -6)
            AppModel.warpCursor(NSPoint(x: origin.x + offset, y: origin.y))
        }
        timer.tolerance = 0.05
        return timer
    }

    private func restoreCursor(_ origin: NSPoint) {
        AppModel.warpCursor(origin)
    }

    private static func warpCursor(_ point: NSPoint) {
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? point.y
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: maxY - point.y))
    }

    private static func tccName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func writeSelfTestReport(_ report: String) {
        NSLog("LJM self-test report:\n\(report)")
        let data = Data(report.utf8)
        var destinations: [URL] = []
        if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            destinations.append(movies.appendingPathComponent("LJM/self-test-result.txt"))
        }
        destinations.append(FileManager.default.temporaryDirectory.appendingPathComponent("ljm-self-test-result.txt"))
        destinations.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/LJM/test-output/self-test-result.txt"))
        for url in destinations {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                NSLog("LJM self-test wrote \(url.path)")
            } catch {
                NSLog("LJM self-test could not write \(url.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Recording

    private var recorderIsActive: Bool {
        phase == .starting || phase == .recording || phase == .stopping
    }

    private func startRecording() {
        guard phase == .idle, !quitting else { return }
        if zoomProgress != nil {
            card = .error("正在生成自动缩放版（\(zoomProgressLabel)），完成后再开始录制。")
            bumpLayout()
            return
        }
        if countdownEnabled && !skipCountdownOnce && !Self.isRunningForPreview {
            beginCountdown()
            return
        }
        skipCountdownOnce = false
        paused = false
        takeWasPaused = false
        autoStopped = false
        reviewWindow.hide()
        hideMainChromeForRecording()
        if Self.isRunningForPreview {
            phase = .recording
            startElapsedTimer()
            bumpLayout()
            return
        }
        phase = .starting
        elapsedSeconds = 0
        delivered = false
        bumpLayout()
        enqueue { [weak self] in
            await self?.performStart()
        }
    }

    private func stopRecording() {
        if Self.isRunningForPreview {
            phase = .idle
            stopElapsedTimer()
            bumpLayout()
            return
        }
        guard phase == .starting || phase == .recording else { return }
        recordingBorder.hide()
        recordingBar.hide()
        phase = .stopping
        enqueue { [weak self] in
            await self?.performStop()
        }
    }

    private func performStart() async {
        guard !quitting else {
            phase = .idle
            stopElapsedTimer()
            restoreMainChrome()
            bumpLayout()
            return
        }
        regionSelector.cancel()
        updateTerminationAssertion()
        if microphoneEnabled && !Permissions.microphoneAuthorized() {
            microphoneEnabled = false
            UserDefaults.standard.set(false, forKey: Keys.microphone)
            phase = .idle
            stopElapsedTimer()
            delivered = true
            updateTerminationAssertion()
            restoreMainChrome()
            presentPermission(.microphone)
            return
        }
        if cameraOn, let screen = NSScreen.screens.first(where: { displayID(of: $0) == displayID }) ?? NSScreen.main {
            camera.place(on: screen, region: region)
        }
        let overlayIDs = showEffects(displayID: displayID, region: region, config: effectsConfig)
        if autoZoom {
            startCursorTracking(displayID: displayID, region: region, fps: effectiveFPS)
        }
        if startSound {
            // Own-process audio is excluded from the capture, so this is not recorded.
            NSSound(named: NSSound.Name("Tink"))?.play()
        }
        do {
            try await recorder.start(
                systemAudio: systemAudioEnabled,
                microphone: microphoneEnabled,
                displayID: displayID,
                region: region,
                maxSide: effectiveMaxSide,
                framesPerSecond: effectiveFPS,
                cameraWindowID: cameraOn ? camera.windowID : nil,
                overlayWindowIDs: overlayIDs
            )
            if quitting || phase == .stopping {
                let result = await recorder.stop()
                deliver(result)
                return
            }
            phase = .recording
            startElapsedTimer()
            if showBorder { showRecordingBorder() }
            refreshLiveStorage()
            showRecordingBarIfNeeded()
            bumpLayout()
            updateTerminationAssertion()
        } catch {
            effects.hide()
            _ = cursorTracker.stop()
            phase = .idle
            stopElapsedTimer()
            delivered = true
            updateTerminationAssertion()
            restoreMainChrome()
            if Permissions.isPermissionError(error) {
                if permissionHelpShownThisSession {
                    card = .permission(.screen)
                    bumpLayout()
                } else {
                    permissionHelpShownThisSession = true
                }
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                card = .error(message)
                bumpLayout()
            }
        }
    }

    private func performStop() async {
        let result = await recorder.stop()
        deliver(result)
    }

    private func deliver(_ result: StopResult) {
        effects.hide()
        recordingBorder.hide()
        recordingBar.hide()
        paused = false
        liveStorageNote = ""
        let tracked = cursorTracker.isRunning
        let samples = cursorTracker.stop()
        guard !delivered else { return }
        delivered = true
        phase = .idle
        stopElapsedTimer()
        updateTerminationAssertion()
        restoreMainChrome()
        switch result {
        case .saved(let url, let note):
            rememberLastFile(url)
            var savedNote = note
            if autoStopped {
                savedNote = [note, "已按设定时长自动停止。"].compactMap { $0 }.joined(separator: " ")
            }
            presentFinishedTake(url, note: savedNote)
            if tracked, autoZoom, !quitting, takeWasPaused {
                presentFinishedTake(url, note: [savedNote, "这次录制中有暂停，没有生成自动缩放版。"].compactMap { $0 }.joined(separator: " "))
                runAfterTakeActions(url)
            } else if tracked, autoZoom, !quitting {
                let sessionStart = recorder.lastStats?.sessionStartSeconds ?? 0
                let fps = trackedFPS
                let area = cursorTracker.areaSize
                let zoom = zoomFactor
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let outcome = await self.makeZoomVersion(of: url, samples: samples, sessionStart: sessionStart, fps: fps, areaSize: area, zoom: zoom)
                    if let zoomURL = outcome.url {
                        self.rememberLastFile(zoomURL)
                        self.presentFinishedTake(zoomURL, note: outcome.note)
                        self.runAfterTakeActions(zoomURL)
                    } else {
                        self.presentFinishedTake(url, note: outcome.note)
                        self.runAfterTakeActions(url)
                    }
                }
            } else {
                runAfterTakeActions(url)
            }
        case .failed(let message):
            card = .error(message)
            bumpLayout()
        }
    }

    private func presentSaved(_ url: URL, note: String?) {
        cardToken += 1
        let token = cardToken
        card = .saved(url, note: note)
        bumpLayout()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, self.cardToken == token else { return }
            self.card = nil
            self.bumpLayout()
        }
    }

    /// Default post-record UI: open the 小名 review window right away.
    private func presentFinishedTake(_ url: URL, note: String?) {
        if shouldUseNewRecordingFlow, !quitting {
            reviewWindow.show(file: url)
            return
        }
        presentSaved(url, note: note)
    }

    private func hideMainChromeForRecording() {
        guard shouldUseNewRecordingFlow else { return }
        onMainChromeVisible?(false)
    }

    private func restoreMainChrome() {
        guard shouldUseNewRecordingFlow else { return }
        onMainChromeVisible?(true)
    }

    private func showRecordingBarIfNeeded() {
        guard shouldUseNewRecordingFlow, phase == .recording, let screen = recordingScreen else { return }
        recordingBar.show(on: screen, region: region)
        recordingBar.reload()
    }

    private func rememberLastFile(_ url: URL) {
        lastSavedURL = url
        UserDefaults.standard.set(url.path, forKey: Keys.lastFile)
    }

    private func refreshFolderPath() {
        if let access = try? SaveLocation.beginAccess() {
            folderPath = access.abbreviatedPath
            access.stop()
        } else {
            folderPath = "~/Movies/LJM"
        }
    }

    private func persistSource() {
        UserDefaults.standard.set(Int(displayID), forKey: Keys.displayID)
        if let region {
            UserDefaults.standard.set(NSStringFromRect(region), forKey: Keys.region)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.region)
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        if phase == .starting {
            elapsedSeconds = 0
        }
        // 1 Hz only. Do not use a display-link or SwiftUI Timeline.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.refreshLiveStorage()
                self.recordingBar.reload()
                guard !self.paused else { return }
                self.elapsedSeconds += 1
                self.recordingBar.reload()
                if self.autoStopMinutes > 0, self.elapsedSeconds >= self.autoStopMinutes * 60 {
                    self.autoStopped = true
                    self.stopRecording()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if phase == .idle {
            elapsedSeconds = 0
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func updateTerminationAssertion() {
        if phase == .recording || phase == .starting || phase == .stopping {
            ProcessInfo.processInfo.disableSuddenTermination()
        } else {
            ProcessInfo.processInfo.enableSuddenTermination()
        }
    }

    func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    func isSelected(screen: NSScreen) -> Bool {
        displayID(of: screen) == displayID
    }

    private enum Keys {
        static let audio = "ljm.systemAudio"
        static let microphone = "ljm.microphone"
        static let camera = "ljm.camera"
        static let edge = "ljm.edge"
        static let qualityCap = "ljm.qualityCap"
        static let frameRate = "ljm.frameRate"
        static let powerSaver = "ljm.powerSaver"
        static let displayID = "ljm.displayID"
        static let region = "ljm.region"
        static let lastFile = "ljm.lastFile"
        static let cursorHighlight = "ljm.cursorHighlight"
        static let clickRipples = "ljm.clickRipples"
        static let watermark = "ljm.watermark"
        static let watermarkText = "ljm.watermarkText"
        static let watermarkCorner = "ljm.watermarkCorner"
        static let autoZoom = "ljm.autoZoom"
        static let zoomFactor = "ljm.zoomFactor"
        static let countdown = "ljm.countdown"
        static let startSound = "ljm.startSound"
        static let border = "ljm.recordingBorder"
        static let playAfter = "ljm.playAfterRecording"
        static let revealAfter = "ljm.revealAfterRecording"
        static let autoStop = "ljm.autoStopMinutes"
    }
}
