import AVFoundation
import SwiftUI
import UIKit

/// Camera access for the QR scanner.
enum CameraAccess: Equatable {
    case unavailable, notDetermined, denied, authorized

    static var current: CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func request() async -> CameraAccess {
        guard current == .notDetermined else { return current }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return current
    }
}

/// Scans QR codes with the back camera and reports each payload once (Telegram's QR login scanner).
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onScan = onScan
    }
}

/// The capture session lives on its own queue; this box only moves it there.
private final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: (@MainActor (String) -> Void)?
    private let box = CaptureSessionBox()
    private let queue = DispatchQueue(label: "dev.chenli.crok.qr")
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastPayload: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: camera)
        else { return }
        let session = box.session
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        }
        session.commitConfiguration()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let box = self.box
        queue.async { if !box.session.isRunning { box.session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let box = self.box
        queue.async { if box.session.isRunning { box.session.stopRunning() } }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection
    ) {
        let payloads = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        guard let payload = payloads.first else { return }
        MainActor.assumeIsolated {
            guard payload != lastPayload else { return }
            lastPayload = payload
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onScan?(payload)
        }
    }
}
