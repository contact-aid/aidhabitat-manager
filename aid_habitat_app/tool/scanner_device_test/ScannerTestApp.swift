import UIKit
import PDFKit
import Flutter

@main
final class ScannerTestDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    DocumentScannerPlugin.scannerOrientationMask ?? .landscape
  }
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: "Scan Test", sessionRole: session.role)
    config.delegateClass = ScannerTestScene.self
    return config
  }
}

final class ScannerTestScene: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = ScannerTestScreen()
    window.makeKeyAndVisible()
    self.window = window
  }
}

private final class LocalMessenger: NSObject, FlutterBinaryMessenger {
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {}
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { 0 }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}

final class ScannerTestScreen: UIViewController {
  private let messenger = LocalMessenger()
  private lazy var scanner = DocumentScannerPlugin(channel: FlutterMethodChannel(name: "scanner-device-test", binaryMessenger: messenger))
  private let status = UILabel()
  private let pdf = PDFView()
  private let photo = UIImageView()
  private var buttons: [UIButton] = []
  private var outputPath: String?

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
  override var prefersInterfaceOrientationLocked: Bool { true }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let title = UILabel()
    title.text = "Scan Test"
    title.font = .boldSystemFont(ofSize: 28)
    let instructions = UILabel()
    instructions.text = "Test local : scannez deux pages ou prenez une photo, puis enregistrez. Vérifiez le retour en paysage et l’aperçu ci-dessous."
    instructions.numberOfLines = 0
    instructions.font = .systemFont(ofSize: 17)
    status.text = "Prêt. Aucun document envoyé au serveur."
    status.numberOfLines = 0
    status.font = .systemFont(ofSize: 17, weight: .medium)
    let scan = makeButton("Scanner un document", action: #selector(scanDocument))
    let capture = makeButton("Prendre une photo", action: #selector(capturePhoto))
    let share = makeButton("Exporter le résultat", action: #selector(exportResult))
    buttons = [scan, capture]
    let actions = UIStackView(arrangedSubviews: [scan, capture, share])
    actions.axis = .horizontal
    actions.spacing = 16
    actions.distribution = .fillEqually
    let stack = UIStackView(arrangedSubviews: [title, instructions, actions, status])
    stack.axis = .vertical
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    pdf.autoScales = true
    pdf.backgroundColor = .secondarySystemBackground
    pdf.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pdf)
    photo.contentMode = .scaleAspectFit
    photo.backgroundColor = .secondarySystemBackground
    photo.translatesAutoresizingMaskIntoConstraints = false
    photo.isHidden = true
    view.addSubview(photo)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      actions.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
      pdf.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
      pdf.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
      pdf.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
      pdf.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      photo.topAnchor.constraint(equalTo: pdf.topAnchor),
      photo.leadingAnchor.constraint(equalTo: pdf.leadingAnchor),
      photo.trailingAnchor.constraint(equalTo: pdf.trailingAnchor),
      photo.bottomAnchor.constraint(equalTo: pdf.bottomAnchor),
    ])
  }

  private func makeButton(_ title: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    button.configuration = configuration
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }
  @objc private func scanDocument() { capture("scanDocument") }
  @objc private func capturePhoto() { capture("capturePhoto") }
  private func capture(_ method: String) {
    buttons.forEach { $0.isEnabled = false }
    status.text = "Ouverture de l’appareil photo…"
    scanner.handle(FlutterMethodCall(methodName: method, arguments: nil)) { [weak self] value in
      guard let self else { return }
      self.buttons.forEach { $0.isEnabled = true }
      if let error = value as? FlutterError {
        self.status.text = error.code == "cancelled" ? "Capture annulée. Vous pouvez recommencer." : "Erreur : \(error.message ?? error.code)"
        return
      }
      guard let value else {
        self.status.text = "Capture annulée. Vous pouvez recommencer."
        return
      }
      if let result = value as? [String: Any], let path = result["path"] as? String {
        self.outputPath = path
        self.pdf.document = PDFDocument(url: URL(fileURLWithPath: path))
        self.pdf.isHidden = false
        self.photo.isHidden = true
        self.status.text = "PDF enregistré : \(self.pdf.document?.pageCount ?? 0) page(s). Vérifiez le cadrage et le retour en paysage."
      } else if let path = value as? String {
        self.outputPath = path
        self.photo.image = UIImage(contentsOfFile: path)
        self.photo.isHidden = false
        self.pdf.isHidden = true
        self.status.text = "Photo enregistrée. Vérifiez le sens de l’image et le retour en paysage."
      }
    }
  }
  @objc private func exportResult(_ sender: UIButton) {
    guard let outputPath else {
      status.text = "Scannez un document ou prenez une photo avant d’exporter."
      return
    }
    let sheet = UIActivityViewController(activityItems: [URL(fileURLWithPath: outputPath)], applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = sender
    sheet.popoverPresentationController?.sourceRect = sender.bounds
    present(sheet, animated: true)
  }
}
