import SwiftUI

public struct PlaybackDiagnosticsView: View {
    @ObservedObject private var diagnostics = PlaybackDiagnosticsStore.shared

    public init() {}

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let summaries = diagnostics.summaries
            List {
                Section {
                    Text("Playback health stays on this device. Reports exclude channels, provider URLs, account details, and device identifiers.".localized)
                    Text("These summaries measure player-reported buffering, not frozen video frames or general app hangs.".localized)
                    #if !os(tvOS)
                    ShareLink(item: diagnostics.report, subject: Text("BruTV playback diagnostics".localized)) {
                        Label("Share playback summary".localized, systemImage: "square.and.arrow.up")
                    }
                    .disabled(summaries.isEmpty)
                    .accessibilityIdentifier("sharePlaybackDiagnosticsButton")
                    #endif
                    Button("Clear playback summaries".localized, role: .destructive) { diagnostics.clear() }
                        .disabled(summaries.isEmpty)
                        .accessibilityIdentifier("clearPlaybackDiagnosticsButton")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Up to 10 recent summaries and one current-session checkpoint are saved when playback activity changes. History resets after an app version, build, or OS major update. Clearing resets saved and current data; new playback activity starts a fresh summary.".localized)
                        Text("Active time includes playing and waiting, excluding pauses. Startup ends when the player reports playing, not at the first decoded frame. Apple crash and app-hang reports depend on your analytics sharing settings.".localized)
                    }
                }

                if summaries.isEmpty {
                    Text("No playback summaries yet.".localized)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(summaries.reversed().enumerated()), id: \.offset) { _, summary in
                    Section {
                        metric("Active time", seconds: summary.requestedSeconds)
                        if let startup = summary.startupSeconds { metric("Startup", seconds: startup) }
                        value("Buffering events", text: "\(summary.stallCount)")
                        metric("Buffering time", seconds: summary.stallSeconds)
                        metric("Longest buffer", seconds: summary.maxStallSeconds)
                        value("Recovery retries", text: "\(summary.retryCount)")
                        if summary.outcome == .interrupted {
                            Text("Counters stop at the last saved playback event; the interruption's cause is unknown.".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text((summary.kind == .live ? "Live TV" : "Video").localized + " · " + outcome(summary.outcome))
                    }
                }
            }
            .navigationTitle("Playback diagnostics".localized)
        }
    }

    private func metric(_ title: String, seconds: Double) -> some View {
        value(title, text: String(format: "%.1f s", seconds))
    }

    private func value(_ title: String, text: String) -> some View {
        HStack {
            Text(title.localized)
            Spacer()
            Text(text).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func outcome(_ outcome: PlaybackHealthSummary.Outcome) -> String {
        switch outcome {
        case .inProgress: return "Current session".localized
        case .stopped: return "Stopped".localized
        case .ended: return "Ended".localized
        case .failed: return "Failed".localized
        case .switched: return "Switched".localized
        case .interrupted: return "Interrupted".localized
        }
    }
}
