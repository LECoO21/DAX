import AppKit

guard CommandLine.arguments.count == 2 || (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--clear") else {
    fputs("请提供 DAX.app 安装路径。\n", stderr)
    exit(1)
}
let app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let clearing = CommandLine.arguments.last == "--clear"
let image = NSImage(contentsOf: app.appendingPathComponent("Contents/Resources/DAX.icns"))
guard Bundle(url: app)?.bundleIdentifier == "com.leco.dax", clearing || image != nil else {
    fputs("DAX 应用或图标资源无效。\n", stderr)
    exit(1)
}
// Register the artwork as the file's custom icon so macOS displays its black
// tile directly instead of synthesizing a light container for the legacy ICNS.
guard NSWorkspace.shared.setIcon(clearing ? nil : image, forFile: app.path, options: []) else {
    fputs("无法应用 DAX 图标。\n", stderr)
    exit(1)
}
print(clearing ? "已准备 DAX 图标元数据更新。" : "已应用 DAX 黑底金毛图标。")
