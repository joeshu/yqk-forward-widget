import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data) else {
    fatalError("Cannot read simulator screenshot")
}
var cyan = 0, magenta = 0, red = 0
// The fixture is an H.264 colour-bar clip. Count saturated pixels across the
// central video area, avoiding small UI elements and letterboxed edges.
for y in stride(from: bitmap.pixelsHigh / 4, to: bitmap.pixelsHigh * 3 / 4, by: 8) {
    for x in stride(from: bitmap.pixelsWide / 8, to: bitmap.pixelsWide * 7 / 8, by: 8) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
        if r < 0.3 && g > 0.7 && b > 0.7 { cyan += 1 }
        if r > 0.7 && g < 0.3 && b > 0.7 { magenta += 1 }
        if r > 0.7 && g < 0.3 && b < 0.3 { red += 1 }
    }
}
print("MPV fullscreen screenshot colour samples cyan=\(cyan) magenta=\(magenta) red=\(red)")
guard cyan >= 20 && magenta >= 20 && red >= 20 else {
    fatalError("The colour-bar fixture is not visible in the fullscreen screenshot")
}
