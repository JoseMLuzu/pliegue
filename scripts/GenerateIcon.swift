import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Could not create the icon context") }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setFillColor(CGColor(red: 0.83, green: 0.96, blue: 0.43, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 52, y: 52, width: 920, height: 920), cornerWidth: 208, cornerHeight: 208, transform: nil))
        context.fillPath()
        context.setStrokeColor(CGColor(red: 0.16, green: 0.19, blue: 0.14, alpha: 1))
        context.setLineWidth(52); context.setLineCap(.round); context.setLineJoin(.round)
        for y in [680.0, 500.0, 320.0] {
            context.move(to: CGPoint(x: 280, y: y)); context.addLine(to: CGPoint(x: 512, y: y - 128)); context.addLine(to: CGPoint(x: 744, y: y)); context.strokePath()
        }
        guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Could not render the icon") }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: destination.appendingPathComponent(name))
    }
}

// Modern ICNS elements contain PNG images with big-endian container lengths.
let elements = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png"),
]
func bigEndianData(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var body = Data()
for (type, filename) in elements {
    let image = try Data(contentsOf: destination.appendingPathComponent(filename))
    body.append(Data(type.utf8)); body.append(bigEndianData(UInt32(image.count + 8))); body.append(image)
}
var icon = Data("icns".utf8)
icon.append(bigEndianData(UInt32(body.count + 8))); icon.append(body)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
