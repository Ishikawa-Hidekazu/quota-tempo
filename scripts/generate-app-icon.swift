#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("Usage: generate-app-icon.swift OUTPUT.icns\n".utf8))
  exit(2)
}

let fileManager = FileManager.default
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
  "quota-tempo-icon-\(UUID().uuidString)",
  isDirectory: true
)
let iconset = temporaryRoot.appendingPathComponent("QuotaTempo.iconset", isDirectory: true)

defer { try? fileManager.removeItem(at: temporaryRoot) }
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
try fileManager.createDirectory(
  at: output.deletingLastPathComponent(),
  withIntermediateDirectories: true
)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func renderIcon(pixelSize: Int) throws -> Data {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelSize,
      pixelsHigh: pixelSize,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else {
    throw CocoaError(.fileWriteUnknown)
  }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.cgContext.setShouldAntialias(true)
  context.cgContext.scaleBy(x: CGFloat(pixelSize) / 1024, y: CGFloat(pixelSize) / 1024)

  NSColor.clear.setFill()
  NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()

  let tile = NSBezierPath(
    roundedRect: NSRect(x: 36, y: 36, width: 952, height: 952),
    xRadius: 218,
    yRadius: 218
  )
  let background = NSGradient(
    starting: color(22, 27, 62),
    ending: color(92, 71, 218)
  )
  background?.draw(in: tile, angle: 42)

  let innerGlow = NSBezierPath(
    roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880),
    xRadius: 188,
    yRadius: 188
  )
  color(255, 255, 255, 0.07).setStroke()
  innerGlow.lineWidth = 10
  innerGlow.stroke()

  let weeklyRing = NSBezierPath(ovalIn: NSRect(x: 242, y: 256, width: 540, height: 540))
  weeklyRing.lineWidth = 72
  weeklyRing.lineCapStyle = .round
  color(250, 251, 255).setStroke()
  weeklyRing.stroke()

  let qTail = NSBezierPath()
  qTail.move(to: NSPoint(x: 646, y: 398))
  qTail.line(to: NSPoint(x: 792, y: 236))
  qTail.lineWidth = 72
  qTail.lineCapStyle = .round
  color(250, 251, 255).setStroke()
  qTail.stroke()

  let tempoNeedle = NSBezierPath()
  tempoNeedle.move(to: NSPoint(x: 470, y: 390))
  tempoNeedle.line(to: NSPoint(x: 614, y: 694))
  tempoNeedle.lineWidth = 42
  tempoNeedle.lineCapStyle = .round
  color(84, 238, 183).setStroke()
  tempoNeedle.stroke()

  let pivot = NSBezierPath(ovalIn: NSRect(x: 428, y: 350, width: 84, height: 84))
  color(84, 238, 183).setFill()
  pivot.fill()

  for angle in stride(from: 110.0, through: 430.0, by: 53.3333333333) {
    let radians = angle * .pi / 180
    let center = NSPoint(
      x: 512 + cos(radians) * 350,
      y: 526 + sin(radians) * 350
    )
    let marker = NSBezierPath(
      ovalIn: NSRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)
    )
    color(255, 255, 255, 0.82).setFill()
    marker.fill()
  }

  context.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()

  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
  }
  return png
}

let variants: [(String, Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
  try renderIcon(pixelSize: size).write(
    to: iconset.appendingPathComponent(name),
    options: .atomic
  )
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
