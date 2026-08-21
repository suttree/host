// Writes an .iconset for iconutil.
//
//   build/icongen <output-iconset-dir> <artwork.png> [theme-id]
//
// Compiled with Sources/Theme.swift and Sources/IconRenderer.swift, so the icon
// on disk and the one the app draws at runtime come from the same code. See
// `make icon`.
import Cocoa

let arguments = CommandLine.arguments
let outputDir = arguments.count > 1 ? arguments[1] : "build/Host.iconset"
let artworkPath = arguments.count > 2 ? arguments[2] : "Resources/artwork.png"
let theme = Theme.named(arguments.count > 3 ? arguments[3] : nil)

guard let artwork = IconRenderer.prepare(artworkAt: artworkPath) else {
    FileHandle.standardError.write("could not read artwork at \(artworkPath)\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
print("theme \(theme.name), ink bounds \(Int(artwork.crop.width))x\(Int(artwork.crop.height))")

for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                     ("icon_32x32", 32), ("icon_32x32@2x", 64),
                     ("icon_128x128", 128), ("icon_128x128@2x", 256),
                     ("icon_256x256", 256), ("icon_256x256@2x", 512),
                     ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let rep = IconRenderer.render(theme: theme, size: CGFloat(size), artwork: artwork)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}
print("wrote iconset to \(outputDir)")
