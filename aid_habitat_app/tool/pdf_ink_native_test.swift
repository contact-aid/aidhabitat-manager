import Foundation
import PDFKit
import AppKit
import CoreText

@main
enum PdfInkNativeTests {
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PdfInkEditor.failure("TEST: " + message) }
  }

  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aidhabitat-ink-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = root.appendingPathComponent("original.pdf")
    var box = CGRect(x: 0, y: 0, width: 420, height: 600)
    let consumer = CGDataConsumer(url: original as CFURL)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for number in 1...4 {
      context.beginPDFPage(nil)
      context.setFillColor(NSColor.white.cgColor)
      context.fill(box)
      context.setStrokeColor(NSColor.gray.cgColor)
      context.stroke(CGRect(x: 50, y: 50, width: 320, height: 500), width: 1)
      context.textPosition = CGPoint(x: 60, y: 520)
      let text = NSAttributedString(string: "ORIGINAL PAGE \(number)",
        attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
      CTLineDraw(CTLineCreateWithAttributedString(text), context)
      context.endPDFPage()
    }
    context.closePDF()
    let fixture = try PdfInkEditor.open(original.path)
    for index in 0..<4 {
      let page = fixture.page(at: index)!
      page.rotation = index * 90
      if index == 2 {
        page.setBounds(CGRect(x: -10, y: -20, width: 450, height: 650), for: .mediaBox)
        page.setBounds(CGRect(x: 20, y: 40, width: 350, height: 500), for: .cropBox)
      }
      let foreign = PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 30, height: 30), forType: .square, withProperties: nil)
      foreign.color = .blue
      page.addAnnotation(foreign)
    }
    try require(fixture.write(to: original), "fixture write")
    let originalBytes = try Data(contentsOf: original)
    let points: [[Double]] = [[0.2, 0.3], [0.5, 0.3], [0.5, 0.65]]
    let stroke: [String: Any] = ["tool": "pen", "color": 0xFFFF0000,
      "widthFraction": 0.012, "points": points]
    let pages: [String: Any] = ["1": [stroke], "2": [stroke], "3": [stroke], "4": [stroke]]

    let written = try PdfInkEditor.write(original.path, pages: pages, quarterTurns: 1)
    let exported = root.appendingPathComponent("annotated-rotated.pdf")
    try FileManager.default.moveItem(atPath: written, toPath: exported.path)
    let reopened = try PdfInkEditor.open(exported.path)
    try require(reopened.pageCount == 4, "multipage preserved")
    let unchangedBytes = try Data(contentsOf: original)
    try require(unchangedBytes == originalBytes, "original untouched")
    let read = try PdfInkEditor.read(exported.path)["pages"] as! [String: [[String: Any]]]
    for index in 0..<4 {
      let page = reopened.page(at: index)!
      try require(page.string?.contains("ORIGINAL PAGE \(index + 1)") == true, "text not rasterized")
      try require(page.annotations.count == 2, "foreign annotation preserved")
      try require(page.rotation == ((index + 1) * 90) % 360, "rotation saved")
      let recovered = read[String(index + 1)]!.first!
      let recoveredPoints = recovered["points"] as! [[Double]]
      for (before, after) in zip(points, recoveredPoints) {
        try require(abs(after[0] - (1 - before[1])) < 0.00001, "rotated ink X")
        try require(abs(after[1] - before[0]) < 0.00001, "rotated ink Y")
      }
      let rendered = try PdfInkEditor.render(exported.path, pageNumber: index + 1,
        width: 700, omitManagedInk: false)
      let target = root.appendingPathComponent("page-\(index + 1).png")
      try FileManager.default.moveItem(atPath: rendered, toPath: target.path)
      let bitmap = NSBitmapImageRep(data: try Data(contentsOf: target))!
      for point in recoveredPoints {
        let x = Int(point[0] * Double(bitmap.pixelsWide))
        let y = Int(point[1] * Double(bitmap.pixelsHigh))
        var found = false
        for dx in -6...6 {
          for dy in -6...6 where x + dx >= 0 && y + dy >= 0 &&
              x + dx < bitmap.pixelsWide && y + dy < bitmap.pixelsHigh {
            if let color = bitmap.colorAt(x: x + dx, y: y + dy)?.usingColorSpace(.deviceRGB),
                color.redComponent > 0.7 && color.greenComponent < 0.3 && color.blueComponent < 0.3 {
              found = true
            }
          }
        }
        try require(found, "visible ink pixel on page \(index + 1) at \(x),\(y)")
      }
    }

    let cleanPreview = try PdfInkEditor.render(exported.path, pageNumber: 1, width: 700, omitManagedInk: true)
    let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: cleanPreview)))!
    for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
      for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
        let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        try require(!(c.redComponent > 0.7 && c.greenComponent < 0.3 && c.blueComponent < 0.3),
          "editor background excludes managed ink")
      }
    }
    try FileManager.default.removeItem(atPath: cleanPreview)
    // A second save replaces managed strokes; erasing is represented by [].
    let cleared = try PdfInkEditor.write(exported.path, pages: ["1": []], quarterTurns: 0)
    let clearedDoc = try PdfInkEditor.open(cleared)
    try require(clearedDoc.page(at: 0)!.annotations.count == 1, "erase preserves foreign ink")
    try require(clearedDoc.page(at: 1)!.annotations.count == 2, "unmodified page preserved")
    try FileManager.default.removeItem(atPath: cleared)
    let repeated = try PdfInkEditor.write(exported.path, pages: read, quarterTurns: 3)
    let repeatedDoc = try PdfInkEditor.open(repeated)
    for index in 0..<4 {
      try require(repeatedDoc.page(at: index)!.annotations.count == 2, "no duplicate managed ink")
      try require(repeatedDoc.page(at: index)!.rotation == index * 90, "full turn restored")
    }
    try FileManager.default.removeItem(atPath: repeated)
    do {
      _ = try PdfInkEditor.write(original.path, pages: ["9": [stroke]], quarterTurns: 0)
      throw PdfInkEditor.failure("TEST: invalid page accepted")
    } catch { try require((error as NSError).localizedDescription != "TEST: invalid page accepted", "reject invalid page") }
    print("PASS: real PDFKit read/write, 4 orientations, offset boxes, pixel checks, erase, repeated save, original/text preserved.")
    print("Fixtures: \(root.path)")
  }
}
