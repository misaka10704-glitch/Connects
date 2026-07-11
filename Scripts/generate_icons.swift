#!/usr/bin/env swift
import AppKit
import Foundation

let cyan = NSColor(red: 0/255, green: 172/255, blue: 193/255, alpha: 1)
let white = NSColor.white
let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Connects/Resources"

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(size: CGFloat, name: String) throws {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
    let fontSize = size * 0.58
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: cyan
    ]
    let text = "A" as NSString
    let textSize = text.size(withAttributes: attrs)
    let rect = NSRect(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2 - size * 0.04,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: rect, withAttributes: attrs)
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    let path = (outDir as NSString).appendingPathComponent(name)
    try png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

try render(size: 76, name: "Icon-76.png")
try render(size: 152, name: "Icon-152.png")
try render(size: 167, name: "Icon-167.png")
try render(size: 1024, name: "Icon-1024.png")
