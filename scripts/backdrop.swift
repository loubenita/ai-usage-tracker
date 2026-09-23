// A striped test backdrop for proving the overlay's glass: bright bands across the right
// edge of the main screen, under the overlay, so a capture shows whether they come through
// the material blurred. It ignores the mouse, never takes focus and quits after N seconds.
// Given an image, it shows that instead, filling the same area: the Paper frames' wallpaper,
// say, so the glass can be compared with the design over the same colours.
//
//   swiftc -O scripts/backdrop.swift -o build/tools/backdrop && build/tools/backdrop 8 [image.png]
import AppKit

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 8
let image = CommandLine.arguments.dropFirst(2).first.flatMap(NSImage.init(contentsOfFile:))

final class Stripes: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
        let band: CGFloat = 60
        var y: CGFloat = 0
        var index = 0
        while y < bounds.height {
            colors[index % colors.count].setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: band).fill()
            y += band
            index += 1
        }
        NSColor.white.setFill()
        var x: CGFloat = 20
        while x < bounds.width {
            NSRect(x: x, y: 0, width: 4, height: bounds.height).fill()
            x += 24
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let frame = NSRect(x: screen.frame.maxX - 440, y: screen.visibleFrame.minY, width: 440, height: screen.visibleFrame.height)
let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
if let image {
    let view = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
    view.image = image
    view.imageScaling = .scaleAxesIndependently
    window.contentView = view
} else {
    window.contentView = Stripes(frame: NSRect(origin: .zero, size: frame.size))
}
// The overlay's own level (its panel floats), ordered in before the copy being captured, so
// that copy is on top and any copy already running is hidden behind the picture.
window.level = .floating
window.ignoresMouseEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
window.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { app.terminate(nil) }
app.run()
