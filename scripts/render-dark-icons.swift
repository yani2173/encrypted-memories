#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Run from the repository root with the selected Xcode toolchain: xcrun swift scripts/render-dark-icons.swift.
// AppKit renders the SVG directly; Quick Look flattens its transparent corners onto white.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Branding/EncryptedMemories-dark.svg")
guard let image = NSImage(contentsOf: source) else {
    fatalError("Cannot read Branding/EncryptedMemories-dark.svg")
}

func render(size: Int, opaque: Bool, destination: URL) throws {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
    guard
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)
    else { fatalError("Cannot create the icon bitmap") }
    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(bounds)
    if opaque {
        // Match the light iOS icon: fill corners with the SVG's bottom background stop (#071A1F).
        context.setFillColor(CGColor(srgbRed: 7 / 255, green: 26 / 255, blue: 31 / 255, alpha: 1))
        context.fill(bounds)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: bounds.size))
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = context.makeImage(),
        let target = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Cannot encode the icon PNG") }
    CGImageDestinationAddImage(target, rendered, nil)
    guard CGImageDestinationFinalize(target) else { fatalError("Cannot write the icon PNG") }
    print("Rendered \(destination.lastPathComponent): \(size)x\(size), alpha=\(!opaque)")
}

// macOS takes the dark artwork from App/AppIcon.icon; only the iOS catalog needs a rendered PNG.
try render(
    size: 1024, opaque: true,
    destination: root.appendingPathComponent("iOSApp/Assets.xcassets/AppIcon.appiconset/icon_dark_1024.png"))
