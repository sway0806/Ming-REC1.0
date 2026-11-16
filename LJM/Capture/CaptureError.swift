import Foundation

enum CaptureError: LocalizedError {
    case noDisplay
    case invalidRegion
    case nothingRecorded
    case exportFailed(String)
    case cancelled
    case diskSpaceLow
    case message(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "没有找到可用的显示器。"
        case .invalidRegion:
            return "所选区域无效，请重新选择。"
        case .nothingRecorded:
            return "没有录到画面，文件未保存。"
        case .exportFailed(let detail):
            return "保存 MP4 失败。\(detail)"
        case .cancelled:
            return "已取消。"
        case .diskSpaceLow:
            return "磁盘剩余空间不足，请腾出一些空间再录。"
        case .message(let text):
            return text
        }
    }
}

enum StopResult {
    /// `note` is set when the picture was saved but system audio was not.
    case saved(URL, note: String?)
    case failed(String)
}
