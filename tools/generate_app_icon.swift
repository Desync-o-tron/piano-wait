#!/usr/bin/env swift
// Draws the app icon: swift tools/generate_app_icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit

let size = 1024
let path = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    // App Store icons must not have an alpha channel.
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: 1)
}

context.setFillColor(color(0.05, 0.06, 0.1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Keys along the bottom.
let keyboardHeight: CGFloat = 340
let whiteKeys = 7
let keyWidth = CGFloat(size) / CGFloat(whiteKeys)
for index in 0..<whiteKeys {
    context.setFillColor(color(0.96, 0.96, 0.96))
    context.fill(CGRect(x: CGFloat(index) * keyWidth + 4, y: 0, width: keyWidth - 8, height: keyboardHeight))
}
for index in [1, 2, 4, 5, 6] {
    context.setFillColor(color(0.08, 0.08, 0.1))
    let blackWidth = keyWidth * 0.6
    context.fill(CGRect(x: CGFloat(index) * keyWidth - blackWidth / 2, y: keyboardHeight * 0.38, width: blackWidth, height: keyboardHeight * 0.62))
}

// Falling note bars: blue left hand and emerald right hand.
let bars: [(key: Int, bottom: CGFloat, height: CGFloat, fill: CGColor)] = [
    (1, 360, 300, color(0.23, 0.51, 0.96)),
    (3, 540, 240, color(0.06, 0.73, 0.51)),
    (5, 360, 420, color(0.06, 0.73, 0.51)),
]
for bar in bars {
    let rect = CGRect(x: CGFloat(bar.key) * keyWidth + 12, y: bar.bottom, width: keyWidth - 24, height: bar.height)
    context.setFillColor(bar.fill)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24, transform: nil))
    context.fillPath()
}

let image = context.makeImage()!
let representation = NSBitmapImageRep(cgImage: image)
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
