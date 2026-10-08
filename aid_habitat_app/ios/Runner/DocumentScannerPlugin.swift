import Flutter
import AVFoundation
import UIKit
import VisionKit

class DocumentScannerPlugin: NSObject, FlutterPlugin, VNDocumentCameraViewControllerDelegate,
  UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private static let channelName = "aidhabitat/document_scanner"

  private let channel: FlutterMethodChannel
  private weak var captureController: UIViewController?
  private var pendingResult: FlutterResult?

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = DocumentScannerPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "scanDocument":
      presentScanner(result: result)
    case "capturePhoto":
      presentPhotoCamera(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentScanner(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "busy",
          message: "Un scan de document est déjà en cours.",
          details: nil
        )
      )
      return
    }

    guard VNDocumentCameraViewController.isSupported else {
      result(
        FlutterError(
          code: "unsupported",
          message: "Le scanner de documents n'est pas disponible sur cet iPad.",
          details: nil
        )
      )
      return
    }

    guard let presenter = Self.activePresenter() else {
      result(
        FlutterError(
          code: "no_presenter",
          message: "Impossible d'ouvrir le scanner de documents.",
          details: nil
        )
      )
      return
    }

    pendingResult = result

    let controller = VNDocumentCameraViewController()
    controller.delegate = self
    // A full-screen capture controller participates in UIKit's own rotation
    // handling instead of inheriting the presenting sheet/context orientation.
    controller.modalPresentationStyle = .fullScreen
    captureController = controller

    DispatchQueue.main.async {
      presenter.present(controller, animated: true)
    }
  }

  private func presentPhotoCamera(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(FlutterError(code: "busy", message: "Une capture est déjà en cours.", details: nil))
      return
    }
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      result(FlutterError(code: "unsupported", message: "Caméra indisponible.", details: nil))
      return
    }
    pendingResult = result
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      showPhotoCamera()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted {
            self.showPhotoCamera()
          } else {
            self.completePhotoCapture(FlutterError(
              code: "camera_access_denied", message: "Accès à la caméra refusé.", details: nil
            ))
          }
        }
      }
    case .restricted, .denied:
      completePhotoCapture(FlutterError(
        code: "camera_access_denied", message: "Accès à la caméra refusé.", details: nil
      ))
    @unknown default:
      completePhotoCapture(FlutterError(
        code: "camera_access_restricted", message: "Caméra indisponible.", details: nil
      ))
    }
  }

  private func showPhotoCamera() {
    guard let presenter = Self.activePresenter(), presenter.viewIfLoaded?.window != nil else {
      completePhotoCapture(FlutterError(
        code: "no_presenter", message: "Impossible d'ouvrir l'appareil photo.", details: nil
      ))
      return
    }
    let controller = UIImagePickerController()
    controller.sourceType = .camera
    controller.mediaTypes = ["public.image"]
    controller.allowsEditing = false
    controller.delegate = self
    // image_picker uses currentContext. For Documents, use Apple's recommended
    // full-screen camera presentation, leaving portrait/landscape to the system.
    controller.modalPresentationStyle = .fullScreen
    captureController = controller
    presenter.present(controller, animated: true)
  }

  private func completePhotoCapture(_ value: Any?) {
    let flutterResult = pendingResult
    finish {
      self.pendingResult = nil
      flutterResult?(value)
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    completePhotoCapture(nil)
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    guard let image = info[.originalImage] as? UIImage else {
      completePhotoCapture(FlutterError(
        code: "capture_failed", message: "Photo illisible.", details: nil
      ))
      return
    }
    do {
      // UIImage.draw applies the camera orientation before saving, so portrait
      // remains portrait even in viewers that ignore EXIF orientation metadata.
      let ratio = min(1, 1600 / image.size.width)
      let bounds = CGRect(origin: .zero, size: CGSize(
        width: image.size.width * ratio, height: image.size.height * ratio
      ))
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let upright = UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
        image.draw(in: bounds)
      }
      guard let data = upright.jpegData(compressionQuality: 0.8) else {
        throw NSError(domain: "DocumentCapture", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Impossible d'enregistrer la photo."])
      }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("photo-\(UUID().uuidString).jpg")
      try data.write(to: url, options: [.atomic, .completeFileProtection])
      completePhotoCapture(url.path)
    } catch {
      completePhotoCapture(FlutterError(
        code: "photo_write_failed", message: error.localizedDescription, details: nil
      ))
    }
  }

  private static func activePresenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    let root =
      activeScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? activeScene?.windows.first?.rootViewController
    return topMostViewController(from: root)
  }

  private static func topMostViewController(from root: UIViewController?) -> UIViewController? {
    var current = root
    while let presented = current?.presentedViewController {
      current = presented
    }
    return current
  }

  private func finish(result: @escaping () -> Void) {
    let controller = captureController
    captureController = nil
    if let controller {
      controller.dismiss(animated: true, completion: result)
    } else {
      result()
    }
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    let flutterResult = pendingResult
    pendingResult = nil
    finish {
      flutterResult?(
        FlutterError(
          code: "cancelled",
          message: "Scan annulé.",
          details: nil
        )
      )
    }
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFailWithError error: Error
  ) {
    let flutterResult = pendingResult
    pendingResult = nil
    finish {
      flutterResult?(
        FlutterError(
          code: "scan_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFinishWith scan: VNDocumentCameraScan
  ) {
    let flutterResult = pendingResult
    pendingResult = nil

    finish {
      guard scan.pageCount > 0 else {
        flutterResult?(
          FlutterError(
            code: "empty_scan",
            message: "Aucune page détectée.",
            details: nil
          )
        )
        return
      }

      do {
        let output = try self.writeScanAsPdf(scan)
        flutterResult?(
          [
            "path": output.path,
            "fileName": output.lastPathComponent,
            "mimeType": "application/pdf",
            "pageCount": scan.pageCount,
          ]
        )
      } catch {
        flutterResult?(
          FlutterError(
            code: "pdf_write_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }

  private func writeScanAsPdf(_ scan: VNDocumentCameraScan) throws -> URL {
    let timestamp = Int(Date().timeIntervalSince1970)
    let fileName = "scan_document_\(timestamp).pdf"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }

    let firstImage = scan.imageOfPage(at: 0)
    let firstBounds = CGRect(origin: .zero, size: firstImage.size)
    let renderer = UIGraphicsPDFRenderer(bounds: firstBounds)

    try renderer.writePDF(to: url) { context in
      for index in 0 ..< scan.pageCount {
        autoreleasepool {
          let image = scan.imageOfPage(at: index)
          let bounds = CGRect(origin: .zero, size: image.size)
          context.beginPage(withBounds: bounds, pageInfo: [:])
          image.draw(in: bounds)
        }
      }
    }

    return url
  }
}
