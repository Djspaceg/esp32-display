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
  let usedOnC6: Bool
  let weight: CGFloat?
}

let root = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
let fontDirectory = root.appendingPathComponent("firmware/display_stream/fonts")
let output = root.appendingPathComponent("firmware/display_stream/panel_fonts.h")
let sources = [
  Source(name: "SMALL_9", file: "IBMPlexSans-Variable.ttf", pointSize: 9,
         usedOnC6: false, weight: 500),
  Source(name: "SMALL_13", file: "IBMPlexSans-Variable.ttf", pointSize: 13,
         usedOnC6: false, weight: 500),
  Source(name: "SMALL_18", file: "IBMPlexSans-Variable.ttf", pointSize: 18,
         usedOnC6: false, weight: 500),
  Source(name: "MONO_12", file: "Inconsolata-Medium.ttf", pointSize: 12,
         usedOnC6: false, weight: nil),
  Source(name: "MONO_24", file: "Inconsolata-Medium.ttf", pointSize: 24,
         usedOnC6: false, weight: nil),
  Source(name: "MONO_40", file: "Inconsolata-Medium.ttf", pointSize: 40,
         usedOnC6: false, weight: nil),
  Source(name: "LARGE_16", file: "Nunito-SemiBold.ttf", pointSize: 16,
         usedOnC6: false, weight: 600),
  Source(name: "LARGE_24", file: "Nunito-SemiBold.ttf", pointSize: 24,
         usedOnC6: false, weight: 600),
  Source(name: "LARGE_40", file: "Nunito-SemiBold.ttf", pointSize: 40,
         usedOnC6: false, weight: 600),
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
      lines.append(line.trimmingCharacters(in: .whitespaces))
      line = indent
    }
    line += item + " "
  }
  if line != indent { lines.append(line.trimmingCharacters(in: .whitespaces)) }
  return lines.joined(separator: "\n")
}

func font(named path: URL, size: CGFloat, weight: CGFloat?) -> CTFont {
  guard let provider = CGDataProvider(url: path as CFURL),
        let graphicsFont = CGFont(provider) else {
    fail("cannot read \(path.path)")
  }
  let base = CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil)
  guard let weight else { return base }
  for axis in (CTFontCopyVariationAxes(base) as? [[CFString: Any]] ?? []) {
    guard let identifier = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber,
          let name = axis[kCTFontVariationAxisNameKey] as? String,
          name == "Weight" else {
      continue
    }
    let attributes: [CFString: Any] = [
      kCTFontVariationAttribute: [identifier: NSNumber(value: Double(weight))]
    ]
    let descriptor = CTFontDescriptorCreateWithAttributes(
        attributes as CFDictionary)
    return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
  }
  fail("\(path.lastPathComponent) has no Weight axis")
}

struct Glyph {
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

func packedAlpha(_ alpha: [UInt8], bits: Int) -> [UInt8] {
  let valuesPerByte = 8 / bits
  let maxLevel = (1 << bits) - 1
  var packed = [UInt8](repeating: 0,
                       count: (alpha.count + valuesPerByte - 1) / valuesPerByte)
  for (index, coverage) in alpha.enumerated() {
    let level = min(maxLevel, (Int(coverage) * maxLevel + 127) / 255)
    packed[index / valuesPerByte] |=
      UInt8(level << (8 - bits - (index % valuesPerByte) * bits))
  }
  return packed
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
    return (Glyph(width: 0, height: 0, xOffset: 0, yOffset: 0,
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
  return (Glyph(width: width, height: height, xOffset: left,
                yOffset: ascent - top, advance: advancePx), pixels)
}

func build(_ source: Source) -> Face {
  let ctFont = font(named: fontDirectory.appendingPathComponent(source.file),
                    size: source.pointSize, weight: source.weight)
  var glyphs = [Glyph]()
  var alpha = [UInt8]()
  for code in Array(UInt16(32)...UInt16(126)) + [UInt16(0x00B7)] {
    let (raw, pixels) = rasterize(ctFont, code: code)
    glyphs.append(Glyph(width: raw.width, height: raw.height,
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
    "inline constexpr uint8_t ASCII_COUNT = LAST - FIRST + 1;",
    "inline constexpr uint8_t MIDDLE_DOT = ASCII_COUNT;",
    "inline constexpr uint8_t COUNT = ASCII_COUNT + 1;",
    "",
    "struct Glyph {",
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
    "  uint8_t alphaBits;",
    "};",
    ""
  ]
  for face in faces {
    if !face.source.usedOnC6 {
      result += ["#if !defined(CONFIG_IDF_TARGET_ESP32C6)"]
    }
    result += [
      "inline constexpr Glyph \(face.source.name)_GLYPHS[COUNT] = {",
      wrap(face.glyphs.map {
        "{\($0.width), \($0.height), \($0.xOffset), \($0.yOffset), \($0.advance)}"
      }),
      "};",
      "",
    ]
    if face.source.usedOnC6 {
      result += [
        "#if defined(CONFIG_IDF_TARGET_ESP32C6)",
        "inline constexpr uint8_t \(face.source.name)_ALPHA[\((face.alpha.count + 7) / 8)] = {",
        wrap(packedAlpha(face.alpha, bits: 1).map { String($0) }),
        "};",
        "#else",
        "inline constexpr uint8_t \(face.source.name)_ALPHA[\((face.alpha.count + 3) / 4)] = {",
        wrap(packedAlpha(face.alpha, bits: 2).map { String($0) }),
        "};",
        "#endif",
        "",
        "inline constexpr Face \(face.source.name) = {",
        "    \(face.source.name)_GLYPHS, \(face.source.name)_ALPHA, \(face.ascent), \(face.descent), \(face.leading),",
        "#if defined(CONFIG_IDF_TARGET_ESP32C6)",
        "    1,",
        "#else",
        "    2,",
        "#endif",
        "};",
        ""
      ]
    } else {
      result += [
        "inline constexpr uint8_t \(face.source.name)_ALPHA[\((face.alpha.count + 3) / 4)] = {",
        wrap(packedAlpha(face.alpha, bits: 2).map { String($0) }),
        "};",
        "",
        "inline constexpr Face \(face.source.name) = {",
        "    \(face.source.name)_GLYPHS, \(face.source.name)_ALPHA, \(face.ascent), \(face.descent), \(face.leading), 2,",
        "};",
        ""
      ]
    }
    if !face.source.usedOnC6 {
      result += ["#endif", ""]
    }
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
    print("\(face.source.name): \((face.alpha.count + 3) / 4) packed alpha bytes")
  }
  let bytes = faces.reduce(0) { $0 + ($1.alpha.count + 3) / 4 }
  print("wrote \(output.path): \(bytes) packed alpha bytes")
}
