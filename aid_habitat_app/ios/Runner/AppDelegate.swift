import Flutter
import AVFoundation
import PDFKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let fileProtectionChannelName = "aidhabitat/file_protection"
  private let pdfRotationChannelName = "aidhabitat/pdf_rotation"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "VisitRecorder") {
      VisitRecorder.register(with: registrar)
    }
    if let pencilRegistrar = registrar(forPlugin: "PencilDoubleTapPlugin") {
      PencilDoubleTapPlugin.register(with: pencilRegistrar)
    }
    if let scannerRegistrar = registrar(forPlugin: "DocumentScannerPlugin") {
      DocumentScannerPlugin.register(with: scannerRegistrar)
    }
    if let rewriteRegistrar = registrar(forPlugin: "AppleIntelligenceRewritePlugin") {
      AppleIntelligenceRewritePlugin.register(with: rewriteRegistrar)
    }
    if let registrar = registrar(forPlugin: "PdfRotationChannel") {
      let channel = FlutterMethodChannel(
        name: pdfRotationChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler(handlePdfRotationCall)
    }
    if let registrar = registrar(forPlugin: "LocalFileProtectionChannel") {
      let channel = FlutterMethodChannel(
        name: fileProtectionChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler(handleFileProtectionCall)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    DocumentScannerPlugin.scannerOrientationMask
      ?? super.application(application, supportedInterfaceOrientationsFor: window)
  }

  private func handlePdfRotationCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if ["readPdfInk", "writePdfInk", "renderPdfInkPreview"].contains(call.method) {
      guard let args = call.arguments as? [String: Any],
            let source = args["sourcePath"] as? String else {
        result(FlutterError(code: "invalid_args", message: "PDF manquant.", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let value: Any
          switch call.method {
          case "readPdfInk":
            value = try PdfInkEditor.read(source)
          case "writePdfInk":
            guard let pages = args["pages"] as? [String: Any] else {
              throw PdfInkEditor.failure("Traits manquants.")
            }
            value = try PdfInkEditor.write(source, pages: pages, quarterTurns: args["quarterTurns"] as? Int ?? 0)
          default:
            value = try PdfInkEditor.render(source, pageNumber: args["page"] as? Int ?? 1,
              width: args["width"] as? Double ?? 800, omitManagedInk: args["omitManagedInk"] as? Bool ?? false)
          }
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "pdf_ink_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
      return
    }
    guard call.method == "rotatePdfFile" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let sourcePath = args["sourcePath"] as? String
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "Le PDF à pivoter est manquant.",
          details: nil
        )
      )
      return
    }
    let quarterTurns = args["quarterTurns"] as? Int ?? 0

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let outputPath = try self.rotatePdfFile(
          sourcePath: sourcePath,
          quarterTurns: quarterTurns
        )
        DispatchQueue.main.async {
          result(outputPath)
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "pdf_rotation_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  private func rotatePdfFile(sourcePath: String, quarterTurns: Int) throws -> String {
    let normalizedTurns = ((quarterTurns % 4) + 4) % 4
    guard normalizedTurns != 0 else { return sourcePath }

    let sourceUrl = URL(fileURLWithPath: sourcePath)
    guard FileManager.default.fileExists(atPath: sourceUrl.path) else {
      throw NSError(
        domain: "PdfRotation",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Fichier PDF introuvable."]
      )
    }
    guard let document = PDFDocument(url: sourceUrl), document.pageCount > 0 else {
      throw NSError(
        domain: "PdfRotation",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "PDF illisible ou vide."]
      )
    }

    let degrees = normalizedTurns * 90
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      page.rotation = normalizedPdfRotation(page.rotation + degrees)
    }

    let outputUrl = FileManager.default.temporaryDirectory
      .appendingPathComponent("rotated-\(UUID().uuidString).pdf")
    if FileManager.default.fileExists(atPath: outputUrl.path) {
      try FileManager.default.removeItem(at: outputUrl)
    }
    guard document.write(to: outputUrl) else {
      throw NSError(
        domain: "PdfRotation",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Écriture du PDF pivoté impossible."]
      )
    }
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: outputUrl.path
    )
    return outputUrl.path
  }

  private func normalizedPdfRotation(_ degrees: Int) -> Int {
    let normalized = degrees % 360
    return normalized >= 0 ? normalized : normalized + 360
  }

  private func handleFileProtectionCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "protectPath" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "Le chemin à protéger est manquant.",
          details: nil
        )
      )
      return
    }

    let recursive = args["recursive"] as? Bool ?? false
    let excludeFromBackup = args["excludeFromBackup"] as? Bool ?? false

    do {
      try protectPath(path, recursive: recursive, excludeFromBackup: excludeFromBackup)
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "file_protection_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func protectPath(
    _ path: String,
    recursive: Bool,
    excludeFromBackup: Bool
  ) throws {
    guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard FileManager.default.fileExists(atPath: path) else { return }

    let url = URL(fileURLWithPath: path)
    try applyProtection(to: url, excludeFromBackup: excludeFromBackup)

    guard recursive else { return }
    let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: nil
    )
    while let child = enumerator?.nextObject() as? URL {
      try applyProtection(to: child, excludeFromBackup: excludeFromBackup)
    }
  }

  private func applyProtection(to url: URL, excludeFromBackup: Bool) throws {
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: url.path
    )
    guard excludeFromBackup else { return }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableUrl = url
    try mutableUrl.setResourceValues(values)
  }
}

/// Keeps capture alive when Flutter switches screens or iPad locks. Audio is
/// committed in one-minute M4A segments; no speech model runs on the device.
final class VisitRecorder: NSObject, FlutterPlugin, AVAudioRecorderDelegate {
  private var recorder: AVAudioRecorder?
  private var sessionID: String?
  private var active = false
  private var interrupted = false
  private var segments: [[String: Any]] = []
  private var segmentIndex = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VisitRecorder()
    let channel = FlutterMethodChannel(name: "aidhabitat/visit_recorder", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    NotificationCenter.default.addObserver(instance, selector: #selector(instance.audioInterrupted),
      name: AVAudioSession.interruptionNotification, object: nil)
  }

  private func folder(_ id: String) throws -> URL {
    guard id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
      throw NSError(domain: "VisitRecorder", code: 1)
    }
    let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    return root.appendingPathComponent("visit-recordings").appendingPathComponent(id)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      guard !active, let id = args["id"] as? String else {
        result(FlutterError(code: "busy", message: "Un enregistrement est déjà actif.", details: nil)); return
      }
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async {
          guard granted else {
            result(FlutterError(code: "permission", message: "Autorise le microphone dans les réglages de l’iPad.", details: nil)); return
          }
          do {
            let dir = try self.folder(id)
            // A recording ID can never silently replace a recovered capture.
            guard !FileManager.default.fileExists(atPath: dir.path) else { throw NSError(domain: "VisitRecorder", code: 2) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
              attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var protectedDir = dir; try protectedDir.setResourceValues(values)
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true)
            self.sessionID = id; self.segmentIndex = 0; self.segments = []
            self.active = true; self.interrupted = false
            try self.recordNext()
            result(self.snapshot())
          } catch {
            self.active = false
            try? AVAudioSession.sharedInstance().setActive(false)
            result(FlutterError(code: "start_failed", message: "L’enregistrement n’a pas pu démarrer. Vérifie l’espace disponible.", details: nil))
          }
        }
      }
    case "status":
      recorder?.updateMeters()
      result(snapshot())
    case "stop":
      active = false
      if let recording = recorder {
        let duration = recording.currentTime
        recording.stop()
        finishSegment(recording.url, duration: duration)
      }
      recorder = nil
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      result(snapshot())
    case "recover":
      do {
        guard let id = args["id"] as? String else { throw NSError(domain: "VisitRecorder", code: 3) }
        if id == sessionID && active { result(snapshot()); return }
        let dir = try folder(id)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
          .filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var recovered: [[String: Any]] = []
        for file in files {
          // Retain unreadable files for recovery; never silently delete audio.
          let audio = try AVAudioPlayer(contentsOf: file)
          if audio.duration > 0 { recovered.append(["name": file.lastPathComponent, "duration": audio.duration]) }
        }
        result(["active": false, "interrupted": true, "segments": recovered, "level": 0, "duration": recovered.reduce(0.0) { $0 + ($1["duration"] as? Double ?? 0) }])
      } catch {
        result(FlutterError(code: "recovery_failed", message: "L’audio est conservé sur cet iPad, mais sa récupération nécessite une vérification.", details: nil))
      }
    case "read":
      do {
        guard let id = args["id"] as? String, let name = args["name"] as? String,
          name.range(of: "^[0-9]{4}\\.m4a$", options: .regularExpression) != nil else { throw NSError(domain: "VisitRecorder", code: 4) }
        let data = try Data(contentsOf: folder(id).appendingPathComponent(name))
        result(FlutterStandardTypedData(bytes: data))
      } catch { result(FlutterError(code: "read_failed", message: "Extrait audio indisponible sur cet iPad.", details: nil)) }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func recordNext() throws {
    guard let id = sessionID, segmentIndex < 240 else { active = false; return }
    let url = try folder(id).appendingPathComponent(String(format: "%04d.m4a", segmentIndex))
    let recording = try AVAudioRecorder(url: url, settings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000,
      AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ])
    recording.delegate = self; recording.isMeteringEnabled = true
    guard recording.record(forDuration: 60) else { throw NSError(domain: "VisitRecorder", code: 5) }
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    recorder = recording; segmentIndex += 1
  }

  private func finishSegment(_ url: URL, duration: TimeInterval) {
    guard duration > 0, !segments.contains(where: { $0["name"] as? String == url.lastPathComponent }) else { return }
    segments.append(["name": url.lastPathComponent, "duration": duration])
  }

  func audioRecorderDidFinishRecording(_ recording: AVAudioRecorder, successfully flag: Bool) {
    if flag {
      let duration = (try? AVAudioPlayer(contentsOf: recording.url).duration) ?? 60
      finishSegment(recording.url, duration: duration)
    } else { active = false; interrupted = true }
    if active {
      do { try recordNext() } catch { active = false; interrupted = true }
    }
  }

  func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    active = false; interrupted = true
  }

  @objc private func audioInterrupted(_ notification: Notification) {
    guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      type == AVAudioSession.InterruptionType.began.rawValue else { return }
    interrupted = true; active = false
    if let recording = recorder {
      let duration = recording.currentTime; recording.stop(); finishSegment(recording.url, duration: duration)
    }
    recorder = nil
  }

  private func snapshot() -> [String: Any] {
    let duration = segments.reduce(0.0) { $0 + ($1["duration"] as? Double ?? 0) }
    let power = recorder?.averagePower(forChannel: 0) ?? -160
    return ["id": sessionID ?? "", "active": active, "interrupted": interrupted,
      "segments": segments, "duration": duration + (active ? (recorder?.currentTime ?? 0) : 0),
      "level": active ? min(1.0, pow(10.0, Double(power) / 20.0)) : 0]
  }
}
