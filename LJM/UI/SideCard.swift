import AppKit
import SwiftUI

struct SideCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.card {
            case .permission(let kind):
                permission(kind)
            case .settings:
                settings
            case .source:
                source
            case .more:
                more
            case .saved(let url, let note):
                saved(url: url, note: note)
            case .error(let message):
                error(message)
            case nil:
                EmptyView()
            }
        }
        .padding(16)
        .frame(width: Metrics.cardWidth, alignment: .leading)
        // Press-drag anywhere on the card except its buttons and fields (t230).
        .background(WindowDragArea(stadium: false).contentShape(Rectangle()))
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            // Same rim light as the bar: brighter on top, fading downward.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Theme.rimTop.opacity(0.8), Theme.edge, Color.white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func permission(_ kind: AppModel.PermissionKind) -> some View {
        switch kind {
        case .screen:
            screenPermission
        case .microphone:
            devicePermission(
                title: "需要麦克风权限",
                body: "打开麦克风后，小名会把你的声音和系统声音混进同一条音轨。请在「系统设置 → 隐私与安全性 → 麦克风」中允许小名。允许之后回到这里再打开一次，不会自动开始录制。"
            )
        case .camera:
            devicePermission(
                title: "需要摄像头权限",
                body: "打开摄像头后，屏幕上会出现一个可拖动的小窗，录制时会一起录进画面。请在「系统设置 → 隐私与安全性 → 摄像头」中允许小名。允许之后回到这里再打开一次，不会自动开始录制。"
            )
        }
    }

    private var screenPermission: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("需要屏幕录制权限")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("小名录你选择的显示器或区域，并用 ScreenCaptureKit 采集系统声音。这两件事都走系统的「屏幕录制」权限，不会安装虚拟声卡。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Text("打开「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」，打开小名。允许之后回到这里，不会自动开始录制。如果开关已经打开却还是不能录，退出应用再打开一次。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            cardButton("请求授权", prominent: true, action: model.requestPermission)
            cardButton("打开系统设置", prominent: false, action: model.openPermissionSettings)
            cardButton("我已经允许，再试一次", prominent: false, action: model.recheckPermission)
        }
    }

    private func devicePermission(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            cardButton("打开系统设置", prominent: true, action: model.openPermissionSettings)
            cardButton("我已经允许，再试一次", prominent: false, action: model.recheckPermission)
            cardButton("关闭", prominent: false, action: model.dismissCard)
        }
    }

    /// Keep the card short enough that the bar stays on-screen even on a
    /// 14-inch laptop. Close / 退出 stay outside the scroll so they are always
    /// reachable.
    private var settingsScrollMaxHeight: CGFloat {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        let reserved = Metrics.thickness + Metrics.cardGap + 160
        return min(520, max(240, visible - reserved))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("录制设置")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
            Text("画质")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
            optionRow(
                options: [(1920, "1080p"), (2560, "1440p"), (3840, "4K")],
                selection: model.qualityCap,
                enabled: model.phase == .idle && !model.powerSaver
            ) { model.setQualityCap($0) }
            .accessibilityLabel("画质")

            Text("帧率")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
            optionRow(
                options: [(30, "30 帧"), (60, "60 帧")],
                selection: model.frameRate,
                enabled: model.phase == .idle && !model.powerSaver
            ) { model.setFrameRate($0) }
            .accessibilityLabel("帧率")

            cardButton(model.powerSaver ? "省电：开" : "省电：关", prominent: model.powerSaver) {
                guard model.phase == .idle else { return }
                model.togglePowerSaver()
            }
            .disabled(model.phase != .idle)
            .accessibilityLabel(model.powerSaver ? "关闭省电" : "打开省电")

            Text(settingsQualityNote)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            behaviourSection

            Text("保存位置")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(model.folderPath)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.phase == .idle
                 ? "下一次录制会写到这里。默认是「影片」里的 LJM 文件夹。"
                 : "正在录制，画质、帧率和文件夹要等这次结束后才会换。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            cardButton("更改文件夹…", prominent: true) {
                guard model.phase == .idle else { return }
                model.chooseFolder()
            }
            .disabled(model.phase != .idle)
            cardButton("恢复默认（影片/LJM）", prominent: false) {
                guard model.phase == .idle else { return }
                model.resetFolder()
            }
            .disabled(model.phase != .idle)
            cardButton("在 Finder 中打开", prominent: false, action: model.revealFolder)
                }
            }
            .frame(maxHeight: settingsScrollMaxHeight)

            cardButton("关闭", prominent: false, action: model.dismissCard)
            Button(action: model.quit) {
                Text("退出小名")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(PressButtonStyle())
            .focusEffectDisabled()
            .accessibilityLabel("退出小名")
        }
    }

    /// 开录前后的习惯：倒计时、提示音、边框、录完动作、自动停止、恢复默认。
    private var behaviourSection: some View {
        let idle = model.phase == .idle && !model.isCountingDown
        return VStack(alignment: .leading, spacing: 8) {
            Text("录制习惯")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("开录时会隐藏控制条并倒数，录完会打开刚录好的文件。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                cardButton(model.countdownEnabled ? "倒计时 3 秒：开" : "倒计时 3 秒：关", prominent: model.countdownEnabled) {
                    model.toggleCountdown()
                }
                .accessibilityLabel(model.countdownEnabled ? "关闭开录倒计时" : "打开开录倒计时")
                cardButton(model.startSound ? "提示音：开" : "提示音：关", prominent: model.startSound) {
                    model.toggleStartSound()
                }
                .accessibilityLabel(model.startSound ? "关闭开录提示音" : "打开开录提示音")
            }
            HStack(spacing: 8) {
                cardButton(model.showBorder ? "录制边框：开" : "录制边框：关", prominent: model.showBorder) {
                    model.toggleBorder()
                }
                .accessibilityLabel(model.showBorder ? "关闭录制边框" : "打开录制边框")
                cardButton(model.playAfterRecording ? "另用播放器打开：开" : "另用播放器打开：关", prominent: model.playAfterRecording) {
                    model.togglePlayAfter()
                }
                .accessibilityLabel(model.playAfterRecording ? "关闭另用系统播放器打开" : "打开另用系统播放器打开")
            }
            cardButton(model.revealAfterRecording ? "录完在访达中显示：开" : "录完在访达中显示：关", prominent: model.revealAfterRecording) {
                model.toggleRevealAfter()
            }
            .accessibilityLabel(model.revealAfterRecording ? "关闭录完在访达中显示" : "打开录完在访达中显示")
            Text("自动停止")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
            optionRow(
                options: [(0, "关"), (15, "15 分"), (30, "30 分"), (60, "60 分")],
                selection: model.autoStopMinutes,
                enabled: idle
            ) { model.setAutoStop($0) }
            .accessibilityLabel("自动停止")
            Text("暂停/继续：⌘⇧P。倒计时中再按录制可取消。边框和倒计时都不会录进视频；暂停的时间也不会计入自动停止。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            cardButton("恢复默认设置", prominent: false) {
                model.restoreDefaultSettings()
            }
            .disabled(!idle)
            .opacity(idle ? 1 : 0.55)
            .accessibilityLabel("恢复默认设置（不改保存位置）")
        }
    }

    private var settingsQualityNote: String {
        if model.phase != .idle {
            return "正在录制，这些选项已锁定。"
        }
        if model.powerSaver {
            return "省电已开启：长边 1920、15 帧。关闭后会回到上面选中的画质和帧率。默认是 4K、30 帧，不会放大小画面。"
        }
        return "按原始比例缩放，长边不超过所选画质，不会放大小画面。默认是 4K、30 帧。"
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("录制范围")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if model.isSourceLocked {
                Text("正在录制，不能更换显示器或区域。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                let selected = model.isSelected(screen: screen) && model.region == nil
                cardButton(displayTitle(index: index, screen: screen), prominent: selected) {
                    guard model.phase == .idle else { return }
                    model.selectDisplay(model.displayID(of: screen))
                }
                .disabled(model.phase != .idle)
                .accessibilityLabel(displayTitle(index: index, screen: screen))
                .accessibilityValue(selected ? "已选择全屏" : "未选择")
            }
            if let region = model.region {
                Text("已选区域 · \(Int(region.width.rounded())) × \(Int(region.height.rounded()))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                cardButton("改为全屏", prominent: false) {
                    guard model.phase == .idle else { return }
                    model.clearRegion()
                }
                .disabled(model.phase != .idle)
            }
            cardButton("拖动选择区域", prominent: model.region != nil) {
                guard model.phase == .idle else { return }
                model.beginRegionSelection()
            }
            .disabled(model.phase != .idle)
            .accessibilityLabel("拖动选择区域")
            Text("拖出矩形后松开鼠标或按回车确认，Esc 取消。控制条不会录进画面。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            cardButton("关闭", prominent: false, action: model.dismissCard)
        }
    }

    private var more: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("更多")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if model.phase == .recording {
                Text(model.paused ? "已暂停" : "正在录制 \(model.elapsedLabel)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.paused ? Theme.orange : Theme.ink)
                if !model.liveStorageNote.isEmpty {
                    Text(model.liveStorageNote)
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.inkSoft)
                }
                cardButton(model.pauseLabel, prominent: !model.paused, action: model.togglePause)
                    .accessibilityLabel(model.pauseLabel)
            }
            cameraShapeSection
            cardButton("打开录制文件夹", prominent: true, action: model.openFolder)
            if let last = model.lastSavedURL {
                cardButton("播放最近的视频", prominent: false, action: model.playLastVideo)
                ShareActions(versions: model.versions(for: last))
                    .id(last)
            }
            effectsSection
            Text(moreTips)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
            cardButton("关闭", prominent: false, action: model.dismissCard)
            Button(action: model.quit) {
                Text("退出小名")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(PressButtonStyle())
            .focusEffectDisabled()
            .accessibilityLabel("退出小名")
        }
    }

    private var cameraShapeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("画面形状")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            optionRow(
                options: [(CameraShape.circle, CameraShape.circle.title), (CameraShape.rectangle, CameraShape.rectangle.title)],
                selection: model.cameraShape,
                enabled: true
            ) { model.setCameraShape($0) }
            .accessibilityLabel("画面形状")
            Text(model.cameraOn
                 ? "当前小窗会马上换成这个形状，拖动右下角可以调整大小。也可在小窗上右键切换。"
                 : "打开摄像头后会按这个形状显示小窗。也可在小窗上右键切换。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectsSection: some View {
        let idle = model.phase == .idle
        return VStack(alignment: .leading, spacing: 10) {
            Text("画面效果")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            cardButton(model.cursorHighlight ? "光标高亮：开" : "光标高亮：关", prominent: model.cursorHighlight) {
                model.toggleCursorHighlight()
            }
            .disabled(!idle)
            .opacity(idle ? 1 : 0.55)
            .accessibilityLabel(model.cursorHighlight ? "关闭光标高亮" : "打开光标高亮")
            cardButton(model.clickRipples ? "点击涟漪：开" : "点击涟漪：关", prominent: model.clickRipples) {
                model.toggleClickRipples()
            }
            .disabled(!idle)
            .opacity(idle ? 1 : 0.55)
            .accessibilityLabel(model.clickRipples ? "关闭点击涟漪" : "打开点击涟漪")
            cardButton(model.watermarkEnabled ? "水印：开" : "水印：关", prominent: model.watermarkEnabled) {
                model.toggleWatermark()
            }
            .disabled(!idle)
            .opacity(idle ? 1 : 0.55)
            .accessibilityLabel(model.watermarkEnabled ? "关闭水印" : "打开水印")
            if model.watermarkEnabled {
                TextField(EffectsConfig.defaultWatermarkText, text: Binding(
                    get: { model.watermarkText },
                    set: { model.setWatermarkText($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.beige))
                .overlay(Capsule().strokeBorder(Theme.edge, lineWidth: 1))
                .disabled(!idle)
                .accessibilityLabel("水印文字")
                optionRow(
                    options: [(WatermarkCorner.topLeft, WatermarkCorner.topLeft.title), (WatermarkCorner.topRight, WatermarkCorner.topRight.title)],
                    selection: model.watermarkCorner,
                    enabled: idle
                ) { model.setWatermarkCorner($0) }
                optionRow(
                    options: [(WatermarkCorner.bottomLeft, WatermarkCorner.bottomLeft.title), (WatermarkCorner.bottomRight, WatermarkCorner.bottomRight.title)],
                    selection: model.watermarkCorner,
                    enabled: idle
                ) { model.setWatermarkCorner($0) }
            }
            cardButton(model.autoZoom ? "自动缩放：开" : "自动缩放：关", prominent: model.autoZoom) {
                model.toggleAutoZoom()
            }
            .disabled(!idle || model.zoomProgress != nil)
            .opacity(idle && model.zoomProgress == nil ? 1 : 0.55)
            .accessibilityLabel(model.autoZoom ? "关闭自动缩放" : "打开自动缩放")
            if model.autoZoom {
                optionRow(
                    options: [(1.5, "1.5×"), (1.8, "1.8×"), (2.0, "2.0×")],
                    selection: model.zoomFactor,
                    enabled: idle && model.zoomProgress == nil
                ) { model.setZoomFactor($0) }
                .accessibilityLabel("缩放倍数")
                Text(model.zoomProgress != nil
                     ? "正在生成自动缩放版 \(model.zoomProgressLabel)"
                     : "录完后在点击处平滑放大、跟随光标，停下后缩回，另存为 -zoom.mp4，原片保留。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(idle
                 ? "开启的效果会叠在画面上一起录进去，屏幕上看到的就是录到的。左键点击是橙色涟漪，右键是天青色虚线涟漪。不需要额外的系统权限。"
                 : "正在录制，画面效果要等这次结束后才能更改。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var moreTips: String {
        var lines = [
            "⌘⇧R 开始或停止录制",
            "⌘⇧L 显示控制条"
        ]
        if let note = model.hotkeyNote {
            lines.append(note)
        }
        return lines.joined(separator: "\n")
    }

    private func saved(url: URL, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已保存")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(SaveLocation.abbreviate(url.deletingLastPathComponent()))
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(2)
                .truncationMode(.middle)
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ShareActions(versions: model.versions(for: url))
                .id(url)
            cardButton("好", prominent: false, action: model.dismissCard)
        }
    }

    private func error(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("无法完成录制")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            cardButton("好", prominent: true, action: model.dismissCard)
        }
    }

    private func displayTitle(index: Int, screen: NSScreen) -> String {
        let name = screen.localizedName
        let suffix = name.isEmpty ? "显示器 \(index + 1)" : name
        return "\(suffix) · 全屏"
    }

    private func optionRow<T: Hashable>(
        options: [(T, String)],
        selection: T,
        enabled: Bool,
        action: @escaping (T) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.1) { value, title in
                Button {
                    guard enabled else { return }
                    action(value)
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == value ? Color.white : Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(selection == value ? Theme.orange : Theme.peach))
                        .opacity(enabled ? 1 : 0.55)
                }
                .buttonStyle(PressButtonStyle())
                .focusEffectDisabled()
                .disabled(!enabled)
                .accessibilityLabel(title)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
    }

    private func cardButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Capsule().fill(prominent ? Theme.orange : Theme.peach))
        }
        .buttonStyle(PressButtonStyle())
        .focusEffectDisabled()
    }
}

/// 访达 / 分享 / 拷贝 for one take. With an 自动缩放 version, a 原片 | 缩放版
/// switch picks which file the three actions use. 分享 is the system share
/// sheet (AirDrop、信息、邮件… whatever macOS offers); nothing is sent until
/// the user picks a service and confirms there.
/// Selection state for `ShareActions` (an ObservableObject: this toolchain
/// builds with swiftc + Command Line Tools, where the `@State` macro plugin is
/// unavailable).
final class ShareSelection: ObservableObject {
    @Published var index = 0
    @Published var copied = false
}

struct ShareActions: View {
    @EnvironmentObject private var model: AppModel
    let versions: [AppModel.RecordingVersion]
    @StateObject private var state = ShareSelection()

    private var current: AppModel.RecordingVersion {
        versions[min(state.index, max(versions.count - 1, 0))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if versions.count > 1 {
                versionRow
            }
            actionRow
        }
    }

    private var versionRow: some View {
        HStack(spacing: 8) {
            ForEach(0..<versions.count, id: \.self) { index in
                versionButton(index)
            }
        }
    }

    private func versionButton(_ index: Int) -> some View {
        let version = versions[index]
        let selected = state.index == index
        return Button {
            state.index = index
            state.copied = false
            model.holdSavedCard()
        } label: {
            Text(version.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Theme.orange : Theme.peach))
        }
        .buttonStyle(PressButtonStyle())
        .focusEffectDisabled()
        .accessibilityLabel("选择" + version.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var actionRow: some View {
        let item = current
        return HStack(spacing: 8) {
            Button {
                model.holdSavedCard()
                model.revealInFinder(item.url)
            } label: {
                pill("访达", systemName: "folder", prominent: false)
            }
            .buttonStyle(PressButtonStyle())
            .focusEffectDisabled()
            .accessibilityLabel("在访达中显示" + item.title)

            ShareLink(item: item.url) {
                pill("分享", systemName: "square.and.arrow.up", prominent: true)
            }
            .buttonStyle(PressButtonStyle())
            .focusEffectDisabled()
            .simultaneousGesture(TapGesture().onEnded { model.holdSavedCard() })
            .accessibilityLabel("分享" + item.title)

            Button {
                model.holdSavedCard()
                model.copyFile(item.url)
                state.copied = true
            } label: {
                pill(state.copied ? "已拷贝" : "拷贝", systemName: state.copied ? "checkmark" : "doc.on.doc", prominent: false)
            }
            .buttonStyle(PressButtonStyle())
            .focusEffectDisabled()
            .accessibilityLabel("把" + item.title + "拷贝到剪贴板")
        }
    }

    private func pill(_ title: String, systemName: String, prominent: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(prominent ? Color.white : Theme.ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Capsule().fill(prominent ? Theme.orange : Theme.peach))
    }
}
