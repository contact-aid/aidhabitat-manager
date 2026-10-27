import Flutter
import AVFoundation
import UIKit
import VisionKit

// Rotate the full-screen scene first, then PRESENT VisionKit. Embedding its
// view as a child bypasses the native camera's modal layout and can crop controls.
final class PortraitDocumentScannerController: UIViewController {
  private let makeScanner: () -> UIViewController
  private let cancel: () -> Void
  private var didAppear = false
  private var scannerPresented = false
  private var presentationScheduled = false

  init(makeScanner: @escaping () -> UIViewController, cancel: @escaping () -> Void) {
    self.makeScanner = makeScanner
    self.cancel = cancel
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { fatalError("Use init(makeScanner:cancel:)") }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
  override var shouldAutorotate: Bool { true }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let instructions = UILabel()
    instructions.text = "Tournez l’iPad en portrait pour scanner le document."
    instructions.numberOfLines = 0
    instructions.textAlignment = .center
    instructions.font = .preferredFont(forTextStyle: .title2)
    instructions.adjustsFontForContentSizeCategory = true
    instructions.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(instructions)

    let cancelButton = UIButton(type: .system)
    cancelButton.setTitle("Annuler", for: .normal)
    cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    cancelButton.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(cancelButton)
    NSLayoutConstraint.activate([
      instructions.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
      instructions.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      instructions.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      instructions.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      cancelButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
  }

  @objc private func cancelScan() { cancel() }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    didAppear = true
    guard !scannerPresented, let scene = view.window?.windowScene else { return }
    setNeedsUpdateOfSupportedInterfaceOrientations()
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
      // Stay on the cancellable rotation screen, never open a cropped camera.
      NSLog("Rotation portrait du scanner refusée : %@", error as NSError)
    }
    presentScannerWhenReady()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    presentScannerWhenReady()
  }

  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: nil) { [weak self] _ in
      self?.presentScannerWhenReady()
    }
  }

  private func isPortrait(_ scene: UIWindowScene) -> Bool {
    if #available(iOS 26.0, *) {
      return scene.effectiveGeometry.interfaceOrientation == .portrait
    }
    return scene.interfaceOrientation == .portrait
  }

  private func presentScannerWhenReady() {
    guard didAppear, !scannerPresented, !presentationScheduled else { return }
    presentationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.presentationScheduled = false
      guard self.presentedViewController == nil, !self.isBeingDismissed,
        let scene = self.view.window?.windowScene,
        self.isPortrait(scene),
        self.view.bounds.height > self.view.bounds.width,
        self.transitionCoordinator == nil else { return }
      self.scannerPresented = true
      let scanner = self.makeScanner()
      scanner.modalPresentationStyle = .fullScreen
      self.present(scanner, animated: true)
    }
  }
}

class DocumentScannerPlugin: NSObject, FlutterPlugin, VNDocumentCameraViewControllerDelegate,
  UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private static let channelName = "aidhabitat/document_scanner"

  private let channel: FlutterMethodChannel
  private weak var captureController: UIViewController?
  private var pendingResult: FlutterResult?
  private weak var scannerScene: UIWindowScene?
  private var previousScannerOrientation: UIInterfaceOrientation?
  // AppDelegate must agree with the modal even when Flutter requests landscape.
  private(set) static var scannerOrientationMask: UIInterfaceOrientationMask?

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

    scannerScene = presenter.view.window?.windowScene
    if #available(iOS 26.0, *) {
      previousScannerOrientation = scannerScene?.effectiveGeometry.interfaceOrientation
    } else {
      previousScannerOrientation = scannerScene?.interfaceOrientation
    }
    // This iPad workflow always returns to the landscape workspace, even if
    // the user entered it while the device was still held in portrait.
    if UIDevice.current.userInterfaceIdiom == .pad,
      previousScannerOrientation?.isLandscape != true {
      previousScannerOrientation = .landscapeRight
    }
    Self.scannerOrientationMask = .portrait
    let controller = PortraitDocumentScannerController(makeScanner: { [weak self] in
      let scanner = VNDocumentCameraViewController()
      scanner.delegate = self
      return scanner
    }, cancel: { [weak self] in
      guard let self, let flutterResult = self.pendingResult else { return }
      self.finish { flutterResult(nil) }
    })
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
    let scene = scannerScene
    let previousOrientation = previousScannerOrientation
    scannerScene = nil
    previousScannerOrientation = nil
    let presenter = controller?.presentingViewController
    let complete = {
      Self.scannerOrientationMask = nil
      self.pendingResult = nil
      if let scene, let previousOrientation {
        presenter?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if #available(iOS 26.0, *) { presenter?.setNeedsUpdateOfPrefersInterfaceOrientationLocked() }
        let mask: UIInterfaceOrientationMask
        switch previousOrientation {
        case .portrait: mask = .portrait
        case .portraitUpsideDown: mask = .portraitUpsideDown
        case .landscapeLeft: mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        default: mask = .all
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
      }
      result()
    }
    if let presenter {
      // Dismiss from BELOW the portrait host so UIKit removes both the host
      // and its presented VisionKit camera, rather than only the camera.
      presenter.dismiss(animated: true, completion: complete)
    } else if let controller {
      controller.dismiss(animated: true, completion: complete)
    } else {
      complete()
    }
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    let flutterResult = pendingResult
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
