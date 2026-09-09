#!/usr/bin/swift
// Генерирует Assets/AppIcon.png (1024x1024): скруглённый квадрат с тёмно-синим
// градиентом и белыми буквами "XC" по центру. Запуск: swift Assets/make-icon.swift
import AppKit

let size = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write("Failed to create bitmap\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let cornerRadius = CGFloat(size) * 0.22
let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
path.addClip()

let gradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.05, green: 0.13, blue: 0.35, alpha: 1.0),
        NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.65, alpha: 1.0),
    ]
)
gradient?.draw(in: rect, angle: -45)

let text = "XC"
let font = NSFont.systemFont(ofSize: CGFloat(size) * 0.42, weight: .bold)
let paragraphStyle = NSMutableParagraphStyle()
paragraphStyle.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraphStyle,
]
let attributedText = NSAttributedString(string: text, attributes: attributes)
let textSize = attributedText.size()
let textRect = NSRect(
    x: (CGFloat(size) - textSize.width) / 2,
    y: (CGFloat(size) - textSize.height) / 2,
    width: textSize.width,
    height: textSize.height
)
attributedText.draw(in: textRect)

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to render icon PNG\n".data(using: .utf8)!)
    exit(1)
}

let outputURL = URL(fileURLWithPath: "Assets/AppIcon.png")
try pngData.write(to: outputURL)
print("Wrote \(outputURL.path)")
