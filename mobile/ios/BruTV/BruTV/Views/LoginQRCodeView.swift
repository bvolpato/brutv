import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Shows a QR code that signs another device into this account.
/// Scanning it with the iPhone or iPad Camera opens BruTV and signs in.
public struct LoginQRCodeView: View {
    public let link: LoginLink
    public let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    public init(link: LoginLink, title: String) {
        self.link = link
        self.title = title
    }

    private var qrImage: UIImage? {
        Self.makeQRCode(from: link.url.absoluteString)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Scan with the Camera app on iPhone or iPad. BruTV opens and signs in.")
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
                            .accessibilityLabel("Sign-in QR code")
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

                    HStack(spacing: 12) {
                        if let qrImage {
                            ShareLink(
                                item: Image(uiImage: qrImage),
                                preview: SharePreview("BruTV sign-in for \(title)", image: Image(uiImage: qrImage))
                            ) {
                                Label("Share QR", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                        }

                        Button {
                            UIPasteboard.general.string = link.url.absoluteString
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityIdentifier("copyLoginLink")
                    }
                    .frame(maxWidth: 360)

                    Label {
                        Text("This code contains the password. Share it only with people you trust. Anyone with it can use this subscription.")
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
            .navigationTitle("Sign-In QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
