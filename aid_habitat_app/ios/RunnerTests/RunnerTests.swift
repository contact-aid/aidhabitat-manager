import Flutter
import UIKit
import XCTest
@testable import Runner

@MainActor
class RunnerTests: XCTestCase {
  private var window: UIWindow!

  override func setUp() {
    super.setUp()
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
    window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    window.makeKeyAndVisible()
  }

  override func tearDown() {
    window.rootViewController?.dismiss(animated: false)
    window.isHidden = true
    window.rootViewController = nil
    window = nil
    super.tearDown()
  }

  private func settle(_ seconds: TimeInterval = 0.15) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  func testPortraitLayoutOpensCameraOnce() async {
    var creations = 0
    let camera = UIViewController()
    let host = PortraitDocumentScannerController(makeScanner: {
      creations += 1
      return camera
    }, cancel: { XCTFail("Unexpected cancellation") })
    window.rootViewController = host
    await settle()
    // Use the rendered layout, even if scene orientation metadata differs.
    host.view.bounds = CGRect(x: 0, y: 0, width: 834, height: 1194)
    host.viewDidLayoutSubviews()
    await settle(0.8)
    XCTAssertTrue(host.presentedViewController === camera)
    XCTAssertEqual(camera.modalPresentationStyle, .fullScreen)
    host.viewDidLayoutSubviews()
    await settle()
    XCTAssertEqual(creations, 1)
    XCTAssertEqual(host.supportedInterfaceOrientations, .portrait)
    XCTAssertTrue(host.prefersInterfaceOrientationLocked)
  }

  func testAnimatedModalOpensAfterPresentationTransition() async {
    let camera = UIViewController()
    let host = PortraitDocumentScannerController(makeScanner: { camera }, cancel: {})
    window.rootViewController!.present(host, animated: true)
    await settle(3)
    XCTAssertTrue(host.presentedViewController === camera)
  }

  func testRefusedOrUnfinishedRotationDoesNotWaitForever() async {
    var creations = 0
    let camera = UIViewController()
    let host = PortraitDocumentScannerController(makeScanner: {
      creations += 1
      return camera
    }, cancel: {})
    // Keep the host in a wide window to exercise the bounded adaptive path.
    window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
    window.rootViewController = host
    host.view.frame = window.bounds
    await settle(3)
    XCTAssertTrue(host.presentedViewController === camera)
    XCTAssertEqual(creations, 1)
  }

  func testClosingCaptureRequestsLandscapeAndCompletesOnce() async {
    let messenger = SilentMessenger()
    let plugin = DocumentScannerPlugin(channel: FlutterMethodChannel(name: "scanner-regression", binaryMessenger: messenger))
    var requestedOrientation: UIInterfaceOrientationMask?
    plugin.requestSceneOrientation = { _, mask in requestedOrientation = mask }
    plugin.showPortraitCapture(from: window.rootViewController!) { UIViewController() }
    await settle(3)
    XCTAssertEqual(DocumentScannerPlugin.scannerOrientationMask, .portrait)
    XCTAssertNotNil(window.rootViewController!.presentedViewController)
    var completions = 0
    plugin.finish { completions += 1 }
    plugin.finish { completions += 1 }
    await settle(2)
    XCTAssertNil(window.rootViewController!.presentedViewController)
    XCTAssertNil(DocumentScannerPlugin.scannerOrientationMask)
    XCTAssertEqual(completions, 1)
    XCTAssertNotNil(requestedOrientation)
    XCTAssertTrue(requestedOrientation.map { !$0.intersection(.landscape).isEmpty } ?? false)
  }

  func testImmediateCancellationPreventsDelayedCamera() async {
    var creations = 0
    var cancellations = 0
    let host = PortraitDocumentScannerController(makeScanner: {
      creations += 1
      return UIViewController()
    }, cancel: { cancellations += 1 })
    window.rootViewController = host
    host.loadViewIfNeeded()
    let button = host.view.subviews.compactMap { $0 as? UIButton }.first!
    button.sendActions(for: .touchUpInside)
    button.sendActions(for: .touchUpInside)
    await settle(2.5)
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(creations, 0)
    XCTAssertNil(host.presentedViewController)
  }

  func testDismissalPreventsQueuedCamera() async {
    var creations = 0
    let host = PortraitDocumentScannerController(makeScanner: {
      creations += 1
      return UIViewController()
    }, cancel: {})
    window.rootViewController = host
    window.rootViewController = UIViewController()
    await settle(2.5)
    XCTAssertEqual(creations, 0)
  }
}

private class SilentMessenger: NSObject, FlutterBinaryMessenger {
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {}
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { 0 }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}
