import AppKit
@main struct CompositeCheck {
    static func tile(_ color: NSColor, scale: Int) -> CGImage {
        let context = CGContext(data: nil, width: 100 * scale, height: 100 * scale, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100 * scale, height: 100 * scale))
        return context.makeImage()!
    }
    @MainActor static func main() throws {
        let screens = [ScreenSnapshot(frame: CGRect(x: -100, y: 0, width: 100, height: 100), scale: 1, image: tile(.red, scale: 1)), ScreenSnapshot(frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, image: tile(.blue, scale: 2))]
        let image = try CaptureController.compose(rect: CGRect(x: -50, y: 25, width: 100, height: 50), snapshots: screens)
        assert(image.width == 200 && image.height == 100)
        let bitmap = NSBitmapImageRep(cgImage: image)
        assert(bitmap.colorAt(x: 25, y: 50)!.redComponent > 0.9)
        assert(bitmap.colorAt(x: 175, y: 50)!.blueComponent > 0.9)
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
        let sample = ScreenSnapshot(frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1, image: context.makeImage()!)
        let top = try CaptureController.compose(rect: CGRect(x: 0, y: 50, width: 100, height: 50), snapshots: [sample])
        assert(NSBitmapImageRep(cgImage: top).colorAt(x: 20, y: 20)!.blueComponent > 0.9)
        print("PASS frozen capture cropping: mixed Retina scale, negative screen origin, cross-screen composition and vertical coordinates")
    }
}
