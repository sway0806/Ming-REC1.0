# 任务：「小名」第一轮功能（按 docs/录屏设置蒸馏分析.md）

你在 /Users/shuilixiaoming/Desktop/LJM 工作。这是一个 macOS 14+ 的 Swift/SwiftUI/AppKit 录屏应用（ScreenCaptureKit + AVAssetWriter），用 `./build.sh`（swiftc + Command Line Tools，Swift 5 模式）构建，**没有 Xcode，没有 `@State` 宏可用**——需要视图状态时用 ObservableObject + @StateObject/@ObservedObject。

## 硬性规则（必须遵守）
- 只改 LJM/ 下的 Swift 源码（以及必要时 build.sh 的源文件列表）。不要动 *.bak-* 文件，不要删除任何文件。
- 不要运行应用、不要运行 build.sh 以外的命令去启动应用，不要开始录制，不要退出任何应用，不要 tccutil，不要 git push，不要联网安装依赖。
- 默认画质不变：长边 3840、30fps（60 可选）。不要降低任何默认值。
- **不要改动控制条拖动/移动相关代码**：FloatingPanel.swift 里的 PanelController 拖动、move mode、drop/dock/float、hitTest；ControlBar.swift 里的 HandleDragView、ChromePointer、HoverLiftModifier、PointingHandView。控制条按钮数量保持 7 个（自检要求 bar 7 / more 18 / settings 18 个按钮——如果你在 more/settings 卡片里新增可点按钮，请在最终说明里列出新的按钮数，以便我更新自检期望值）。
- 视觉沿用现有 Theme / SideCard 的暗色卡片风格；不要模仿任何其他商业软件的名称、图标、文案。
- 所有新设置用 UserDefaults 持久化，键名前缀 `ljm.`，**默认值保持现有行为（全部默认关闭）**。
- 每次改完运行 `./build.sh` 直到 0 错误；尽量不引入新的 warning。

## 要实现（按优先级，做不完就停在完整可编译的一项上）
1. **暂停/继续**：AppModel 增加 `paused` 状态与 `togglePause()`；ScreenRecorder/MovieWriter 在暂停期间丢弃视频与音频样本，继续后把之后的时间戳整体前移暂停时长，保证音画同步、文件连续。计时器暂停时不走。全局快捷键 ⌘⇧P（沿用 LJMApp.swift 现有 RegisterEventHotKey 机制，新 id=3）。菜单栏菜单加「暂停/继续」项。控制条上录制中时在已有计时文字旁显示「已暂停」状态即可（不要新增控制条按钮）。
2. **倒计时 + 开始提示音**：设置项「开始前倒计时 3 秒」（默认关）、「开始提示音」（默认关，用 NSSound(named: "Tink") 之类系统声音）。倒计时期间在屏幕中央显示一个不入画的大数字浮层（独立 NSPanel，录制开始前就关闭），倒计时中再按录制可取消。
3. **录制边框**：设置项「录制时显示边框」（默认关）。录制中在被录区域（整屏或选区）外缘画 2pt 细框（可用 Theme 的强调色），窗口 ignoresMouseEvents，且**不能被录进视频**（确保它属于本应用且不在 overlayWindowIDs/exceptingWindows 里）。
4. **录制中状态**：录制中在 more 卡片顶部显示「当前文件大小 · 剩余空间」（每秒刷新；文件大小可从 MovieWriter 的输出 URL 读取文件属性，剩余空间用 volumeAvailableCapacityForImportantUsage）。
5. **录完行为**：设置项「录完自动播放」「录完在访达中显示」（默认都关）；在 deliver(.saved) 后执行（自动缩放版生成完成的话用最终文件）。
6. **自动停止**：设置项「自动停止」：关 / 15 / 30 / 60 分钟（默认关）；按暂停后不计入时长。
7. **恢复默认设置**：settings 卡片底部一个按钮，清除本轮及已有的 `ljm.` 偏好设置中属于「设置」的项（**不要清除保存文件夹书签、最近文件、控制条位置 ljm.edge/ljm.along/ljm.floating/ljm.freeX/ljm.freeY**），然后把 AppModel 的已发布属性恢复默认。

## 交付
最后输出：改了哪些文件、每项功能是否完成、新增的 UserDefaults 键、more/settings 卡片中可点按钮的新数量、已知限制。
