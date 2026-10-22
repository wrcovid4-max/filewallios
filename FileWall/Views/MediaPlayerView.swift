import SwiftUI
import AVKit

/// Video and audio player for the vault: play/pause, 10-second skips, a seek bar, and speed.
/// Plays the decrypted preview file, so nothing leaves the device.
struct MediaPlayerView: View {
    let url: URL

    @State private var player = AVPlayer()
    @State private var observer: Any?
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var rate: Float = 1
    @State private var playing = false

    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "caf", "amr"]

    /// True for audio and video files this player can open.
    static func handles(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext) || audioExtensions.contains(ext)
    }

    private var isAudio: Bool { Self.audioExtensions.contains(url.pathExtension.lowercased()) }

    var body: some View {
        VStack(spacing: 18) {
            if isAudio {
                Image(systemName: "waveform.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180)
                    .foregroundStyle(.tint)
                    .padding(.top, 40)
            } else {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }

            Slider(value: Binding(get: { position }, set: { seek(to: $0) }), in: 0...max(duration, 1))

            HStack {
                Text(format(position))
                Spacer()
                Text(format(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 40) {
                Button { skip(by: -10) } label: { Image(systemName: "gobackward.10").font(.title) }
                Button { togglePlay() } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                }
                Button { skip(by: 10) } label: { Image(systemName: "goforward.10").font(.title) }
            }

            Picker("Speed", selection: $rate) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { value in
                    Text(value == 1 ? "1×" : "\(value)×").tag(value)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: rate) { value in
                if playing { player.rate = value }
            }
        }
        .padding()
        .onAppear(perform: setup)
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer) }
        }
    }

    private func setup() {
        guard player.currentItem == nil else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            position = time.seconds
            let total = player.currentItem?.duration.seconds ?? 0
            duration = total.isFinite ? total : 0
            playing = player.rate != 0
        }
    }

    private func togglePlay() {
        if playing {
            player.pause()
        } else {
            player.rate = rate
        }
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        position = seconds
    }

    private func skip(by delta: Double) {
        seek(to: min(max(position + delta, 0), duration))
    }

    private func format(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
