import SwiftUI

public struct TechStatsHUD: View {
    public let telemetry: StreamTelemetry
    public let format: String

    @ObservedObject private var localization = LocalizationManager.shared

    public init(telemetry: StreamTelemetry, format: String = "HLS (.m3u8)") {
        self.telemetry = telemetry
        self.format = format
    }

    private var bufferHealthColor: Color {
        if telemetry.bufferDuration >= 3.0 {
            return .green
        } else if telemetry.bufferDuration >= 1.0 {
            return .yellow
        } else {
            return .red
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(bufferHealthColor)
                    .frame(width: 8, height: 8)
                Text("STREAM TELEMETRY".localized)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Text(format)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.cyan)
            }

            Divider().background(Color.white.opacity(0.2))

            Group {
                statRow(label: "Buffer Ahead".localized, value: telemetry.bufferDurationFormatted, valueColor: bufferHealthColor)
                statRow(label: "Resolution".localized, value: telemetry.resolutionFormatted.localized)
                statRow(label: "Bitrate".localized, value: telemetry.observedBitrateFormatted.localized)
                statRow(label: "Dropped Frames".localized, value: "\(telemetry.droppedFrames)", valueColor: telemetry.droppedFrames > 0 ? .orange : .white)
                statRow(label: "Stalls Count".localized, value: "\(telemetry.stallCount)", valueColor: telemetry.stallCount > 0 ? .red : .white)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .frame(maxWidth: 240)
    }

    private func statRow(label: String, value: String, valueColor: Color = .white) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(valueColor)
        }
    }
}
