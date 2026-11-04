import CoreGraphics
import CoreText
import CoreImage
import Foundation

@main
struct NativeSmoke {
    static func sample() -> CGImage {
        let context = CGContext(data: nil, width: 1600, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 240))
        let text = NSAttributedString(string: "屏幕文字识别 DAX SCREEN TEXT", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 64, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 40, y: 95)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()!
    }

    static func main() async throws {
        if OCRWorker.runIfRequested() { return }
        let image = sample()
        let recognizer = OCRRecognizer()
        let document = try await recognizer.recognize(image)
        guard document.text.contains("屏幕文字识别"), document.text.contains("DAX SCREEN TEXT"),
              !document.lines.isEmpty, document.lines.allSatisfy({ $0.bounds.minX >= 0 && $0.bounds.maxX <= 1.01 && $0.bounds.minY >= 0 && $0.bounds.maxY <= 1.01 }) else {
            fatalError("OCR text or normalized bounds did not match fixture")
        }
        print("PASS Chinese/English child-process OCR and normalized line bounds")
        let payload = "https://example.com/dax"
        let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(payload.utf8), "inputCorrectionLevel": "M"])!
        let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let qrImage = CIContext().createCGImage(qr, from: qr.extent)!
        let codes = try await recognizer.recognizeCodes(qrImage)
        guard codes == [payload] else { fatalError("QR payload mismatch") }
        let autoCode = try await recognizer.recognize(qrImage)
        guard autoCode.barcodes == [payload], autoCode.text == payload else { fatalError("Automatic QR detection failed") }
        print("PASS explicit and automatic QR recognition")
        let task = Task { try await recognizer.recognize(image, mode: .systemExtended) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            fatalError("Cancelled OCR should not produce a result")
        } catch is CancellationError {
            print("PASS cancellation terminates isolated OCR job")
        }
        let second = try await recognizer.recognize(image)
        guard second.text.contains("DAX SCREEN TEXT") else { fatalError("Post-cancel retry failed") }
        print("PASS fresh OCR succeeds after cancelling another model")
    }
}
