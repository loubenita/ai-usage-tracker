// Prints the window id of the overlay panel owned by the given process, for `screencapture -l`.
//   window-id <pid>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: window-id <pid>\n".data(using: .utf8)!)
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let overlay = windows.first { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
if let id = overlay?[kCGWindowNumber as String] as? Int {
    print(id)
}
