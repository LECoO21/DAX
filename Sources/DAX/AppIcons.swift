import AppKit

enum AppIcons {
    static let status = statusImage(named: "DAXStatus")
    static let attention = statusImage(named: "DAXStatusAttention")

    private static func statusImage(named name: String) -> NSImage {
        let file = Bundle.module.url(forResource: "Resources", withExtension: nil)?
            .appendingPathComponent("Branding/\(name).pdf")
        let image = file.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "dog.fill", accessibilityDescription: "DAX")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "DAX"
        return image
    }
}
