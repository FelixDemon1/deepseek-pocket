#if os(iOS) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import AVFoundation
import DeepSeekCore

/// Camera sheet that reads a `deepseekgo://setup?…` QR code and hands the raw
/// string back. Scanning is the whole onboarding: no typing, no endpoint, no key.
public struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hint: String?

    private let onResult: (String) -> Void

    public init(onResult: @escaping (String) -> Void) {
        self.onResult = onResult
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                CameraPreview(
                    onCode: { code in
                        onResult(code)
                        dismiss()
                    },
                    onError: { message in
                        hint = message
                    }
                )
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                        .frame(width: 240, height: 240)
                    Spacer()

                    Text(hint ?? "把网关的接入二维码放进取景框")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 28)
                }
            }
            .navigationTitle("扫码接入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

private struct CameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

/// Non-isolated delegate relay: the capture output calls it on the main queue, and
/// it hands work back to the main actor with `assumeIsolated` so no values cross an
/// actor boundary.
final class QRCodeRelay: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    var onCode: (@MainActor (String) -> Void)?
    var onInvalid: (@MainActor () -> Void)?
    private var delivered = false

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let raw = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
        MainActor.assumeIsolated {
            guard !delivered,
                  let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return }
            guard let url = URL(string: value), SetupLink.parse(url) != nil else {
                onInvalid?()
                return
            }
            delivered = true
            onCode?(value)
        }
    }
}

final class ScannerViewController: UIViewController {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var relay: QRCodeRelay?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func requestAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.onError?("相机权限未开启：设置 → 隐私 → 相机 → 允许「DeepSeek Go」")
                    }
                }
            }
        default:
            onError?("相机权限未开启：设置 → 隐私 → 相机 → 允许「DeepSeek Go」")
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onError?("没有可用的摄像头")
            return
        }
        session.beginConfiguration()
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            onError?("无法启用扫码输出")
            return
        }
        session.addOutput(output)

        let relay = QRCodeRelay()
        relay.onCode = { [weak self] code in self?.onCode?(code) }
        relay.onInvalid = { [weak self] in
            self?.onError?("这不是 DeepSeek Go 的接入码，请对准网关首页的二维码")
        }
        output.setMetadataObjectsDelegate(relay, queue: .main)
        output.metadataObjectTypes = [.qr]
        self.relay = relay
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        session.startRunning()
    }
}
#endif
