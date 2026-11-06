import SwiftUI
import AppKit
import AwakeCore

struct NowPlayingView: View {
    @EnvironmentObject var model: AppModel
    @State private var showTranslation = true

    var body: some View {
        ZStack {
            stageBackground
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                HStack(alignment: .center, spacing: 52) {
                    leftColumn
                        .frame(maxWidth: 430)
                    lyricsPanel
                        .frame(width: 430)
                }
                .padding(.horizontal, 54)
                Spacer(minLength: 12)
                bottomBar
            }
            .padding(.top, 14)
            .padding(.bottom, 26)
        }
        .onExitCommand { model.showNowPlaying = false }
    }

    private var stageBackground: some View {
        GeometryReader { geo in
            ZStack {
                AwakeTheme.background
                model.palette.stageGradient.opacity(0.85)
                if let image = model.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 110)
                        .opacity(0.40)
                }
                model.palette.glowGradient.opacity(0.55)
                LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.65)],
                               startPoint: .top,
                               endPoint: .bottom)
            }
            .clipped()
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                model.showNowPlaying = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AwakeTheme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(AwakeTheme.surfaceRaised))
            }
            .buttonStyle(.plain)
            .padding(.leading, 78)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.queueTitle.isEmpty ? "正在播放" : model.queueTitle)
                    .font(.system(size: AwakeType.metaSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer()

            if model.autoEQDecision != nil {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 10))
                    Text(model.autoEQDecision?.headphone.name ?? "AutoEQ")
                        .font(.system(size: AwakeType.metaSize, weight: .medium))
                }
                .foregroundStyle(AwakeTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(AwakeTheme.surfaceRaised))
            }

            Button {
                showTranslation.toggle()
                if showTranslation && model.translation == nil {
                    model.reloadTranslation()
                }
            } label: {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 12))
                    .foregroundStyle(showTranslation ? AwakeTheme.accent : AwakeTheme.tertiaryText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(AwakeTheme.surfaceRaised))
            }
            .buttonStyle(.plain)
            .help("逐句翻译")

            Button {
                model.showEQ = true
            } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 12))
                    .foregroundStyle(AwakeTheme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(AwakeTheme.surfaceRaised))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private var leftColumn: some View {
        if let track = model.currentTrack {
            VStack(alignment: .leading, spacing: 22) {
                ArtworkView(image: model.artwork, cornerRadius: 8, palette: model.palette)
                    .frame(width: 380, height: 380)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(AwakeTheme.border, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title)
                        .font(.system(size: AwakeType.displaySize, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.system(size: AwakeType.bodySize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        Text(track.album)
                        Text(track.qualityLabel)
                    }
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                    .lineLimit(1)
                }

                spectrumStrip
                    .frame(height: 26)

                seekBar
                transportRow
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                Text("还没有正在播放的歌")
                    .font(.system(size: AwakeType.bodySize))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var spectrumStrip: some View {
        Canvas { context, size in
            let values = model.engine.spectrum
            guard !values.isEmpty else { return }
            let count = values.count
            let gap: CGFloat = 2
            let width = (size.width - CGFloat(count - 1) * gap) / CGFloat(count)
            for (index, value) in values.enumerated() {
                let normalized = CGFloat(max(0, min(1, value)))
                let height = max(1.5, normalized * size.height)
                let rect = CGRect(x: CGFloat(index) * (width + gap),
                                  y: size.height - height,
                                  width: width,
                                  height: height)
                let shade = 0.35 + normalized * 0.65
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(AwakeTheme.accent.opacity(Double(shade))))
            }
        }
        .opacity(model.isPlaying ? 1 : 0.35)
    }

    private var seekBar: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AwakeTheme.surfaceRaised).frame(height: 3)
                    Capsule()
                        .fill(LinearGradient(colors: [AwakeTheme.accent, AwakeTheme.indigo],
                                             startPoint: .leading,
                                             endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * model.engine.progress), height: 3)
                }
                .frame(height: 10)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        let ratio = max(0, min(1, value.location.x / max(1, geo.size.width)))
                        model.seek(to: ratio * model.duration)
                    }
                )
            }
            .frame(height: 10)
            HStack {
                Text(model.elapsed.timecode)
                Spacer()
                Text("-" + model.engine.secondsRemaining.timecode)
            }
            .font(.system(size: AwakeType.metaSize))
            .foregroundStyle(AwakeTheme.tertiaryText)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 26) {
            Button { model.previousTrack() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(AwakeTheme.secondaryText)
            }
            .buttonStyle(.plain)

            Button { model.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(AwakeTheme.accent).frame(width: 46, height: 46)
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AwakeTheme.onAccent)
                        .offset(x: model.isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(.plain)

            Button { model.nextTrack() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(AwakeTheme.secondaryText)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { model.toggleFavoriteForCurrent() } label: {
                Image(systemName: model.currentTrack?.favorite == true ? "heart.fill" : "heart")
                    .font(.system(size: 15))
                    .foregroundStyle(model.currentTrack?.favorite == true ? AwakeTheme.accent : AwakeTheme.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 6)
    }

    private var lyricsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("歌词")
                    .font(.system(size: AwakeType.metaSize, weight: .semibold))
                    .foregroundStyle(AwakeTheme.secondaryText)
                if let lyrics = model.lyrics {
                    Text(lyrics.isSynced ? "逐句同步" : "纯文本")
                        .font(.system(size: AwakeType.metaSize, weight: .medium))
                        .foregroundStyle(AwakeTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AwakeTheme.accent.opacity(0.14)))
                    Text(lyrics.source)
                        .font(.system(size: AwakeType.metaSize))
                        .foregroundStyle(AwakeTheme.tertiaryText)
                }
                Spacer()
                if model.isLoadingMetadata {
                    ProgressView().controlSize(.mini)
                }
            }

            ZStack {
                if let lyrics = model.lyrics, !lyrics.lines.isEmpty {
                    lyricsScroll(lyrics)
                } else {
                    emptyLyrics
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 540)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AwakeTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AwakeTheme.border.opacity(0.8), lineWidth: 1)
        )
    }

    private func lyricsScroll(_ lyrics: LyricsDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 130).id("top")
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        lyricLine(line, index: index, synced: lyrics.isSynced)
                            .id(index)
                    }
                    Color.clear.frame(height: 180).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.84),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: activeIndex(lyrics)) { _, newValue in
                guard let index = newValue else { return }
                withAnimation(AwakeTheme.lyric) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onAppear {
                if let index = activeIndex(lyrics) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    private func lyricLine(_ line: LyricsLine, index: Int, synced: Bool) -> some View {
        let active = synced && activeIndex(model.lyrics) == index
        let past = synced && (activeIndex(model.lyrics) ?? 0) > index
        let translated = translatedLine(index)
        return VStack(alignment: .leading, spacing: 4) {
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: active ? AwakeType.displaySize : AwakeType.titleSize,
                              weight: active ? .bold : .medium,
                              design: .rounded))
                .foregroundStyle(active ? AwakeTheme.textPrimary
                                        : AwakeTheme.tertiaryText.opacity(past ? 0.8 : 1))
                .lineSpacing(2)
            if showTranslation, let translated, !translated.isEmpty {
                Text(translated)
                    .font(.system(size: active ? AwakeType.bodySize : AwakeType.metaSize))
                    .foregroundStyle(active ? AwakeTheme.accent
                                            : AwakeTheme.tertiaryText.opacity(past ? 0.7 : 0.9))
                    .lineSpacing(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(AwakeTheme.lyric, value: active)
    }

    private func translatedLine(_ index: Int) -> String? {
        guard let translation = model.translation, translation.lines.indices.contains(index) else { return nil }
        let value = translation.lines[index].trimmed
        guard !value.isEmpty else { return nil }
        if let original = model.lyrics?.lines[index].text.trimmed, original == value { return nil }
        return value
    }

    private func activeIndex(_ lyrics: LyricsDocument?) -> Int? {
        guard let lyrics, lyrics.isSynced else { return nil }
        var result: Int?
        for (index, line) in lyrics.lines.enumerated() {
            guard let time = line.time else { continue }
            if time <= model.elapsed + 0.12 {
                result = index
            } else {
                break
            }
        }
        return result
    }

    private var emptyLyrics: some View {
        VStack(spacing: 12) {
            Image(systemName: model.isLoadingMetadata ? "sparkles" : "text.bubble")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AwakeTheme.accent)
            Text(model.isLoadingMetadata ? "正在为这首歌匹配歌词与翻译…" : "这首还没有歌词")
                .font(.system(size: AwakeType.bodySize))
                .foregroundStyle(AwakeTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if let decision = model.autoEQDecision {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 10))
                    .foregroundStyle(AwakeTheme.accent)
                Text(decision.reason)
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
            if let upNext = model.upNext {
                Text("接下来：\(upNext.title) — \(upNext.artist)")
                    .font(.system(size: AwakeType.metaSize))
                    .foregroundStyle(AwakeTheme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 30)
        .frame(height: 20)
    }
}
