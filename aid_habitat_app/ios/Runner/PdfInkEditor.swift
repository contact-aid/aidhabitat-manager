import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
private typealias InkColor = UIColor
private typealias InkPath = UIBezierPath
#else
import AppKit
private typealias InkColor = NSColor
private typealias InkPath = NSBezierPath
#endif

/// Managed ink is carried by the PDF itself. Coordinates in its metadata
/// are PDF page coordinates, independent of the editor viewport/rotation.
enum PdfInkEditor {
  static let inkKey = PDFAnnotationKey(rawValue: "AidHabitatInkV1")

  static func failure(_ message: String) -> NSError {
    NSError(domain: "PdfInk", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  static func open(_ path: String) throws -> PDFDocument {
    guard let pdf = PDFDocument(url: URL(fileURLWithPath: path)),
          !pdf.isLocked, pdf.pageCount > 0 else {
      throw failure("PDF illisible ou verrouille.")
    }
    return pdf
  }

  static func displayTransform(_ page: PDFPage) throws -> (CGAffineTransform, CGSize) {
    guard let ref = page.pageRef else { throw failure("Page PDF illisible.") }
    let box = ref.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { throw failure("Dimensions PDF invalides.") }
    let odd = ((page.rotation % 360 + 360) % 360) % 180 != 0
    let size = odd ? CGSize(width: box.height, height: box.width) : box.size
    let transform = ref.getDrawingTransform(.mediaBox,
      rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
    return (transform, size)
  }

  static func metadata(_ annotation: PDFAnnotation) throws -> [String: Any]? {
    guard let raw = annotation.value(forAnnotationKey: inkKey) else { return nil }
    guard let text = raw as? String, let data = text.data(using: .utf8),
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["version"] as? Int == 1 else {
      throw failure("Annotation App'Ergo illisible : original conserve.")
    }
    return value
  }

  static func read(_ sourcePath: String) throws -> [String: Any] {
    let pdf = try open(sourcePath)
    var pages: [String: [[String: Any]]] = [:]
    for index in 0..<pdf.pageCount {
      guard let page = pdf.page(at: index) else { throw failure("Page PDF absente.") }
      let (transform, size) = try displayTransform(page)
      var strokes: [[String: Any]] = []
      for annotation in page.annotations {
        guard let value = try metadata(annotation) else { continue }
        guard let points = value["points"] as? [[Double]],
              let width = value["width"] as? Double,
              let color = value["color"] as? Int else {
          throw failure("Trait PDF incomplet.")
        }
        let normalized = try points.map { pair -> [Double] in
          guard pair.count == 2, pair.allSatisfy({ $0.isFinite }) else {
            throw failure("Coordonnees PDF invalides.")
          }
          let point = CGPoint(x: pair[0], y: pair[1]).applying(transform)
          return [point.x / size.width, 1 - point.y / size.height]
        }
        strokes.append(["tool": value["tool"] as? String ?? "pen",
          "color": color, "strokeWidth": 2.0, "widthFraction": width / size.width,
          "points": normalized])
      }
      if !strokes.isEmpty { pages[String(index + 1)] = strokes }
    }
    return ["pages": pages]
  }

  static func write(_ sourcePath: String, pages: [String: Any], quarterTurns: Int) throws -> String {
    let pdf = try open(sourcePath)
    guard pdf.allowsCommenting else { throw failure("Ce PDF interdit les annotations.") }
    // Validate every requested page before producing any output.
    for key in pages.keys {
      guard let number = Int(key), number >= 1, number <= pdf.pageCount else {
        throw failure("Numero de page invalide.")
      }
    }
    for index in 0..<pdf.pageCount {
      guard let page = pdf.page(at: index) else { throw failure("Page PDF absente.") }
      if let rawStrokes = pages[String(index + 1)] {
        guard let strokes = rawStrokes as? [[String: Any]] else { throw failure("Traits invalides.") }
        for annotation in page.annotations where try metadata(annotation) != nil {
          page.removeAnnotation(annotation)
        }
        let (transform, size) = try displayTransform(page)
        let inverse = transform.inverted()
        let bounds = page.pageRef!.getBoxRect(.mediaBox)
        for stroke in strokes {
          guard let points = stroke["points"] as? [[Double]], !points.isEmpty,
                let fraction = stroke["widthFraction"] as? Double,
                fraction.isFinite, fraction > 0, fraction <= 1,
                let argb = stroke["color"] as? Int else { throw failure("Trait invalide.") }
          let canonical = try points.map { pair -> [Double] in
            guard pair.count == 2, pair.allSatisfy({ $0.isFinite }) else {
              throw failure("Coordonnees invalides.")
            }
            let point = CGPoint(x: pair[0] * size.width,
              y: (1 - pair[1]) * size.height).applying(inverse)
            return [point.x, point.y]
          }
          let path = InkPath()
          let first = CGPoint(x: canonical[0][0] - bounds.minX, y: canonical[0][1] - bounds.minY)
          path.move(to: first)
          for point in canonical.dropFirst() {
            let next = CGPoint(x: point[0] - bounds.minX, y: point[1] - bounds.minY)
            #if canImport(UIKit)
            path.addLine(to: next)
            #else
            path.line(to: next)
            #endif
          }
          if canonical.count == 1 {
            #if canImport(UIKit)
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            #else
            path.line(to: CGPoint(x: first.x + 0.01, y: first.y))
            #endif
          }
          let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
          let erased = stroke["tool"] as? String == "eraser"
          annotation.color = erased ? .white : InkColor(
            red: Double((argb >> 16) & 255) / 255,
            green: Double((argb >> 8) & 255) / 255,
            blue: Double(argb & 255) / 255, alpha: Double((argb >> 24) & 255) / 255)
          let border = PDFBorder()
          border.lineWidth = fraction * size.width
          annotation.border = border
          annotation.shouldPrint = true
          annotation.shouldDisplay = true
          annotation.add(path)
          let value: [String: Any] = ["version": 1, "points": canonical,
            "width": border.lineWidth, "color": argb, "tool": stroke["tool"] as? String ?? "pen"]
          let json = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
          guard annotation.setValue(String(decoding: json, as: UTF8.self), forAnnotationKey: inkKey) else {
            throw failure("Metadonnees de trait non enregistrees.")
          }
          page.addAnnotation(annotation)
        }
      }
      page.rotation = ((page.rotation + quarterTurns * 90) % 360 + 360) % 360
    }
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("ink-\(UUID().uuidString).pdf")
    do {
      guard pdf.write(to: target) else { throw failure("Ecriture du PDF annote impossible.") }
      #if canImport(UIKit)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
      #endif
      let check = try open(target.path)
      guard check.pageCount == pdf.pageCount else { throw failure("PDF annote incomplet.") }
      _ = try read(target.path)
      return target.path
    } catch {
      try? FileManager.default.removeItem(at: target)
      throw error
    }
  }

  static func render(_ sourcePath: String, pageNumber: Int, width: Double, omitManagedInk: Bool) throws -> String {
    let pdf = try open(sourcePath)
    guard let page = pdf.page(at: pageNumber - 1), width.isFinite, width > 0, width <= 4096 else {
      throw failure("Rendu PDF invalide.")
    }
    if omitManagedInk {
      for annotation in page.annotations where try metadata(annotation) != nil {
        page.removeAnnotation(annotation)
      }
    }
    let (_, size) = try displayTransform(page)
    let scale = min(width / size.width, 4096 / size.height)
    let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
    #if canImport(UIKit)
    let data = image.pngData()
    #else
    let data = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    #endif
    guard let data = data else { throw failure("Rendu PDF indisponible.") }
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("ink-preview-\(UUID().uuidString).png")
    try data.write(to: target, options: .atomic)
    #if canImport(UIKit)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
    #endif
    return target.path
  }
}
