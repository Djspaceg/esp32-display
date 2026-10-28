#!/usr/bin/swift
// Generate the embedded, anti-aliased glyph atlas for firmware display UI.
//
// Uses only macOS CoreText and the checked-in OFL font assets:
//
//   swift tools/generate_panel_fonts.swift
//   swift tools/generate_panel_fonts.swift --check
//
// The output contains printable ASCII, the character repertoire accepted by
// wifi_selector_model.h. OLED panels deliberately use font5x7.h instead:
// their 72x40 SSD1315 framebuffer has one bit per pixel, so soft coverage
// cannot survive its RGB565-to-monochrome conversion.

import CoreGraphics
import CoreText
import Foundation

struct Source {
  let name: String
  let file: String
  let pointSize: CGFloat
}

let root = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
let fontDirectory = root.appendingPathComponent("firmware/display_stream/fonts")
let output = root.appendingPathComponent("firmware/display_stream/panel_fonts.h")
let sources = [
  Source(name: "SMALL_9", file: "IBMPlexSans-Regular.ttf", pointSize: 9),
  Source(name: "SMALL_13", file: "IBMPlexSans-Regular.ttf", pointSize: 13),
  Source(name: "SMALL_18", file: "IBMPlexSans-Regular.ttf", pointSize: 18),
  Source(name: "MONO_12", file: "Inconsolata-Regular.ttf", pointSize: 12),
  Source(name: "MONO_24", file: "Inconsolata-Regular.ttf", pointSize: 24),
  Source(name: "MONO_40", file: "Inconsolata-Regular.ttf", pointSize: 40),
  Source(name: "LARGE_16", file: "Nunito-Regular.ttf", pointSize: 16),
  Source(name: "LARGE_24", file: "Nunito-Regular.ttf", pointSize: 24),
  Source(name: "LARGE_40", file: "Nunito-Regular.ttf", pointSize: 40),
]

func fail(_ text: String) -> Never {
  fputs("generate_panel_fonts.swift: \(text)\n", stderr)
  exit(1)
}

func wrap(_ values: [String], indent: String = "    ", width: Int = 78) -> String {
  var lines = [String]()
  var line = indent
  for value in values {
    let item = value + ","
    if line.count + item.count + 1 > width && line != indent {
      lines.append(line)
      line = indent
    }
    line += item + " "
  }
  if line != indent { lines.append(line) }
  return lines.joined(separator: "\n")
}

func font(named path: URL, size: CGFloat) -> CTFont {
  guard let provider = CGDataProvider(url: path as CFURL),
        let graphicsFont = CGFont(provider) else {
    fail("cannot read \(path.path)")
  }
  return CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil)
}

struct Glyph {
  let offset: Int
  let width: Int
  let height: Int
  let xOffset: Int
  let yOffset: Int
  let advance: Int
}

struct Face {
  let source: Source
  let ascent: Int
  let descent: Int
  let leading: Int
  let glyphs: [Glyph]
  let alpha: [UInt8]
}

func rasterize(_ ctFont: CTFont, code: UInt16) -> (Glyph, [UInt8]) {
  var character = UniChar(code)
  var glyph: CGGlyph = 0
  guard CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) else {
    fail("font is missing printable ASCII U+\(String(code, radix: 16))")
  }
  var one = glyph
  let bounds = CTFontGetBoundingRectsForGlyphs(ctFont, .default, &one, nil, 1)
  var advance = CGSize.zero
  CTFontGetAdvancesForGlyphs(ctFont, .default, &one, &advance, 1)
  let advancePx = max(1, Int(ceil(advance.width)))
  if bounds.isNull || bounds.width <= 0 || bounds.height <= 0 {
    return (Glyph(offset: 0, width: 0, height: 0, xOffset: 0, yOffset: 0,
                  advance: advancePx), [])
  }

  let left = Int(floor(bounds.minX))
  let bottom = Int(floor(bounds.minY))
  let right = Int(ceil(bounds.maxX))
  let top = Int(ceil(bounds.maxY))
  let width = max(1, right - left)
  let height = max(1, top - bottom)
  var pixels = [UInt8](repeating: 0, count: width * height)
  pixels.withUnsafeMutableBytes { storage in
    guard let context = CGContext(
      data: storage.baseAddress, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else {
      fail("cannot create \(width)x\(height) bitmap context")
    }
    context.setFillColor(gray: 1, alpha: 1)
    var position = CGPoint(x: CGFloat(-left), y: CGFloat(-bottom))
    CTFontDrawGlyphs(ctFont, &one, &position, 1, context)
  }

  let ascent = Int(ceil(CTFontGetAscent(ctFont)))
  return (Glyph(offset: 0, width: width, height: height, xOffset: left,
                yOffset: ascent - top, advance: advancePx), pixels)
}

func build(_ source: Source) -> Face {
  let ctFont = font(named: fontDirectory.appendingPathComponent(source.file),
                    size: source.pointSize)
  var glyphs = [Glyph]()
  var alpha = [UInt8]()
  for code in UInt16(32)...UInt16(126) {
    let (raw, pixels) = rasterize(ctFont, code: code)
    glyphs.append(Glyph(offset: alpha.count, width: raw.width, height: raw.height,
                        xOffset: raw.xOffset, yOffset: raw.yOffset,
                        advance: raw.advance))
    alpha += pixels
  }
  return Face(source: source, ascent: Int(ceil(CTFontGetAscent(ctFont))),
              descent: Int(ceil(CTFontGetDescent(ctFont))),
              leading: Int(ceil(CTFontGetLeading(ctFont))), glyphs: glyphs,
              alpha: alpha)
}

func header(_ faces: [Face]) -> String {
  var result = [
    "// Generated by tools/generate_panel_fonts.swift. Do not edit.",
    "// Printable ASCII only. See firmware/display_stream/fonts/ for the",
    "// checked-in OFL assets and their license texts.",
    "#pragma once",
    "",
    "#include <stdint.h>",
    "",
    "namespace panelfonts {",
    "",
    "inline constexpr uint8_t FIRST = 32;",
    "inline constexpr uint8_t LAST = 126;",
    "inline constexpr uint8_t COUNT = LAST - FIRST + 1;",
    "",
    "struct Glyph {",
    "  uint32_t offset;",
    "  uint8_t width;",
    "  uint8_t height;",
    "  int8_t xOffset;",
    "  int8_t yOffset;",
    "  uint8_t advance;",
    "};",
    "",
    "struct Face {",
    "  const Glyph *glyphs;",
    "  const uint8_t *alpha;",
    "  uint8_t ascent;",
    "  uint8_t descent;",
    "  uint8_t leading;",
    "};",
    ""
  ]
  for face in faces {
    result += [
      "inline constexpr Glyph \(face.source.name)_GLYPHS[COUNT] = {",
      wrap(face.glyphs.map {
        "{\($0.offset), \($0.width), \($0.height), \($0.xOffset), \($0.yOffset), \($0.advance)}"
      }),
      "};",
      "",
      "inline constexpr uint8_t \(face.source.name)_ALPHA[\(face.alpha.count)] = {",
      wrap(face.alpha.map { String($0) }),
      "};",
      "",
      "inline constexpr Face \(face.source.name) = {",
      "    \(face.source.name)_GLYPHS, \(face.source.name)_ALPHA, \(face.ascent), \(face.descent), \(face.leading),",
      "};",
      ""
    ]
  }
  result += [
    "}  // namespace panelfonts",
    ""
  ]
  return result.joined(separator: "\n")
}

let check = CommandLine.arguments.dropFirst().contains("--check")
if CommandLine.arguments.dropFirst().contains(where: { $0 != "--check" }) {
  fail("usage: swift tools/generate_panel_fonts.swift [--check]")
}
let faces = sources.map(build)
let text = header(faces)
if check {
  let current = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
  if current != text {
    fail("\(output.path) is stale; run swift tools/generate_panel_fonts.swift")
  }
  print("\(output.lastPathComponent) matches source fonts")
} else {
  try text.write(to: output, atomically: true, encoding: .utf8)
  for face in faces {
    print("\(face.source.name): \(face.alpha.count) alpha bytes")
  }
  print("wrote \(output.path): \(faces.reduce(0) { $0 + $1.alpha.count }) alpha bytes")
}
