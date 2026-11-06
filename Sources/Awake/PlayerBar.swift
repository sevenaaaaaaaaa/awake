import SwiftUI
import AppKit
import AwakeCore

struct PlayerBar: View {
    @EnvironmentObject var model: AppModel
    @State private var dragProgress: Double?

    var body: some View {
        HStack(spacing: 18) {
            if let track = model.currentTrack {
                nowPlaying(track)
                Spacer(minLength: 12)
                transport
                Spacer(minLength: 12)
                controls(track)
            } else {
                idle
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 76)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(model.palette.deep.opacity(0.55))
                LinearGradient(colors: [model.palette.primary.opacity(0.10), .clear],
                               startPoint: .leading,
                               endPoint: .trailing)
            }
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var idle: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(model.palette.secondary)
            Text("Awake")
                .font(.system(size: AwakeType.bodySize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Button {
                model.showPalette = true
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
                    .font(.system(size: AwakeType.metaSize, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.white.opacity(0.07)))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }

    private func nowPlaying(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Button {
                model.showNowPlaying = true
            } label: {
                ArtworkView(image: model.artwork, cornerRadius: 8, palette: model.palette)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: AwakeType.bodySize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "未知艺人" : track.artist)
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)

            Button {
                model.toggleFavoriteForCurrent()
            } label: {
                Image(systemName: track.favorite ? "heart.fill" : "heart")
                    .font(.system(size: 12))
                    .foregroundStyle(track.favorite ? AwakeTheme.warm : AwakeTheme.secondaryText)
            }
            .buttonStyle(.plain)
        }
    }

    private var transport: some View {
        VStack(spacing: 6) {
            HStack(spacing: 22) {
                Button {
                    model.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(model.canPlayPrevious ? .white.opacity(0.85) : .white.opacity(0.25))
                }
                .buttonStyle(.plain)

                Button {
                    model.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 34, height: 34)
                        if model.isResolving {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.black)
                                .offset(x: model.isPlaying ? 0 : 1)
                        }
                    }
                }
                .buttonStyle(.plain)

                Button {
                    model.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(model.canPlayNext ? .white.opacity(0.85) : .white.opacity(0.25))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Text(model.elapsed.timecode)
                    .font(.system(size: AwakeType.metaSize, design: .rounded))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                    .frame(width: 34, alignment: .trailing)
                scrubber
                    .frame(width: 260)
                Text("-" + model.engine.secondsRemaining.timecode)
                    .font(.system(size: AwakeType.metaSize, design: .rounded))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                    .frame(width: 38, alignment: .leading)
            }
        }
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let progress = dragProgress ?? model.engine.progress
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 3)
                Capsule()
                    .fill(LinearGradient(colors: [model.palette.secondary, model.palette.primary],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * progress), height: 3)
                Circle()
                    .fill(.white)
                    .frame(width: dragProgress == nil ? 6 : 10, height: dragProgress == nil ? 6 : 10)
                    .offset(x: max(0, geo.size.width * progress - 3))
                    .opacity(dragProgress == nil ? 0.75 : 1)
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragProgress = max(0, min(1, value.location.x / max(1, geo.size.width)))
                    }
                    .onEnded { value in
                        let ratio = max(0, min(1, value.location.x / max(1, geo.size.width)))
                        model.seek(to: ratio * model.duration)
                        dragProgress = nil
                    }
            )
        }
        .frame(height: 14)
    }

    private func controls(_ track: Track) -> some View {
        HStack(spacing: 14) {
            if model.engine.isBitPerfect {
                Text("BIT-PERFECT")
                    .font(.system(size: AwakeType.metaSize, weight: .bold, design: .rounded))
                    .foregroundStyle(AwakeTheme.warm)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(AwakeTheme.warm.opacity(0.14)))
            } else if track.isHiRes {
                Text(track.sampleRate > 0 ? String(format: "%.1f kHz", Double(track.sampleRate) / 1000) : "HI-RES")
                    .font(.system(size: AwakeType.metaSize, weight: .bold, design: .rounded))
                    .foregroundStyle(AwakeTheme.secondaryText)
            }

            Button {
                model.showNowPlaying = true
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 13))
                    .foregroundStyle(model.lyrics != nil ? model.palette.secondary : AwakeTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("歌词舞台")

            Button {
                model.showEQ = true
            } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 13))
                    .foregroundStyle(model.autoEQDecision != nil ? model.palette.secondary : AwakeTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("自动 EQ")

            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                Slider(value: Binding(get: { model.volume },
                                      set: { model.volume = $0 }), in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 74)
                    .tint(model.palette.secondary)
            }
        }
        .frame(width: 250, alignment: .trailing)
    }
}
