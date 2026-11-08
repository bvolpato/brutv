import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
#if !os(tvOS)
import AVFoundation
import PhotosUI
#endif

/// Shows a QR code that signs another device into this account.
/// Scanning it with the iPhone or iPad Camera opens BruTV and signs in.
public struct LoginQRCodeView: View {
    public let link: LoginLink
    public let title: String

    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    public init(link: LoginLink, title: String) {
        self.link = link
        self.title = title
    }

    private var qrImage: UIImage? {
        Self.makeQRCode(from: link.universalURL.absoluteString)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Scan with the Camera app on iPhone or iPad. BruTV opens and signs in.".localized)
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(16)
                            .background(Color.white)
                            .cornerRadius(16)
                            .frame(maxWidth: 320)
                            .accessibilityLabel("Sign-in QR code".localized)
                            .accessibilityIdentifier("loginQRCode")
                    }

                    VStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                        Text(sourceDescription)
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    #if !os(tvOS)
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            if qrImage != nil {
                                ShareLink(
                                    item: link.universalURL,
                                    subject: Text("Join BruTV".localized),
                                    message: Text(String(format: "BruTV sign-in for %@".localized, title))
                                ) {
                                    Label("Share Link".localized, systemImage: "square.and.arrow.up")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                            }

                            Button {
                                UIPasteboard.general.string = link.universalURL.absoluteString
                                copied = true
                            } label: {
                                Label(copied ? "Copied".localized : "Copy Link".localized, systemImage: copied ? "checkmark" : "link")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .accessibilityIdentifier("copyLoginLink")
                        }

                        Text("Link opens BruTV directly or prompts to download the app if not installed.".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: 360)
                    #endif

                    Label {
                        Text("This code contains the password. Share it only with people you trust. Anyone with it can use this subscription.".localized)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(.orange)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .padding(12)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(10)
                    .frame(maxWidth: 360)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(white: 0.04).ignoresSafeArea())
            .navigationTitle("Sign-In QR Code".localized)
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Label("Done".localized, systemImage: "checkmark")
                    }
                }
            }
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }

    private var sourceDescription: String {
        switch link {
        case let .xtream(server, _, _): return "Xtream Codes · \(server)"
        case let .m3u(url): return "M3U · \(url)"
        }
    }

    /// Renders a crisp QR code. Medium error correction survives screenshots and printing.
    static func makeQRCode(from string: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#if !os(tvOS)
// MARK: - Scanning

/// Reads a BruTV sign-in link from a QR code in an image.
enum LoginQRDecoder {
    /// Returns the first QR code in the image that holds a BruTV link or playlist URL.
    static func link(in image: CGImage) -> LoginLink? {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        for case let feature as CIQRCodeFeature in features {
            if let message = feature.messageString, let link = LoginLink(pasted: message) {
                return link
            }
        }
        return nil
    }
}

/// Scans a sign-in QR code with the camera, or reads one from a photo.
///
/// The photo option covers devices without a camera (Mac without one, the Simulator)
/// and codes that people receive as a screenshot.
public struct LoginQRScannerView: View {
    public let onLink: (LoginLink) -> Void

    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var cameraState: CameraState = .checking
    @State private var photoItem: PhotosPickerItem?
    @State private var message: String?

    private enum CameraState { case checking, ready, denied, unavailable }

    public init(onLink: @escaping (LoginLink) -> Void) {
        self.onLink = onLink
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(Color.black)
                    switch cameraState {
                    case .ready:
                        QRCameraPreview { code in handle(code: code) }
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.cyan, lineWidth: 3)
                            .padding(40)
                            .allowsHitTesting(false)
                    case .checking:
                        ProgressView().tint(.cyan)
                    case .denied:
                        cameraMessage("Camera access is off for BruTV.".localized, systemImage: "camera.fill",
                                      action: ("Open Settings".localized, openSettings))
                    case .unavailable:
                        cameraMessage("No camera is available. Choose a photo of the QR code instead.".localized,
                                      systemImage: "camera.metering.unknown", action: nil)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 420)
                .accessibilityIdentifier("qrScannerPreview")

                Text("Point the camera at a BruTV sign-in QR code.".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                if let message {
                    Label(message.localized, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                        .accessibilityIdentifier("qrScannerMessage")
                }

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose Photo".localized, systemImage: "photo.on.rectangle")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
                .accessibilityIdentifier("qrScannerChoosePhoto")

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color(white: 0.04).ignoresSafeArea())
            .navigationTitle("Scan QR Code".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".localized) { dismiss() }
                        .accessibilityIdentifier("qrScannerCancel")
                }
            }
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .task { await checkCamera() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await readPhoto(item) }
        }
    }

    private func cameraMessage(_ text: String, systemImage: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundColor(.gray)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    private func checkCamera() async {
        guard AVCaptureDevice.default(for: .video) != nil else {
            cameraState = .unavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraState = .ready
        case .notDetermined:
            cameraState = await AVCaptureDevice.requestAccess(for: .video) ? .ready : .denied
        default:
            cameraState = .denied
        }
    }

    private func readPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)?.cgImage else {
            message = "That photo could not be opened.".localized
            return
        }
        guard let link = LoginQRDecoder.link(in: image) else {
            message = "No BruTV QR code was found in that photo.".localized
            return
        }
        finish(with: link)
    }

    private func handle(code: String) {
        guard let link = LoginLink(pasted: code) else {
            message = "This QR code is not a BruTV sign-in code.".localized
            return
        }
        finish(with: link)
    }

    private func finish(with link: LoginLink) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
        onLink(link)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Live camera preview that reports QR code text.
private struct QRCameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraViewController {
        let controller = QRCameraViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRCameraViewController, context: Context) {
        controller.onCode = onCode
    }
}

final class QRCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "brutv.qr-camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastCode: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview

        sessionQueue.async { [weak self] in self?.configureAndStart() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    private func configureAndStart() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        }
        session.commitConfiguration()
        session.startRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first,
              code != lastCode else { return }
        lastCode = code
        onCode?(code)
    }
}
#endif
