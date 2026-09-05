//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    /// Artwork on the left, everything else in the column beside it — the original shape.
    ///
    /// The title and artist moved onto the artwork's own corner, which frees that column
    /// for the lyrics. Three lines of lyric take the space two lines of text and one line
    /// of lyric already occupied, so the notch does not have to grow for them.
    var body: some View {
        HStack {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace).padding(.all, 5)
            // No .drawingGroup() here. It rasterises this whole subtree offscreen, and
            // the subtree contains the scrubber's timeline ticking ten times a second —
            // so the lyric scroll was being re-rasterised mid-animation on every tick,
            // which is what made it stutter.
            MusicControlsView().compositingGroup()
        }
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    /// Dimmed while the identity is showing, so white text stays readable over whatever
    /// the cover happens to be, and cleared on hover so the cover can still be looked at.
    /// The fade is what makes the text legible, so revealing the art has to take the text
    /// with it.
    @State private var revealing = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
                .overlay {
                    if vm.notchState == .open && Defaults[.albumArtShowsIdentity] {
                        identityOverlay
                    }
                }
        }
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.26)) { revealing = hovering }
        }
    }

    /// Title over artist in the corner of the cover, on a scrim that carries them over a
    /// bright or busy image.
    private var identityOverlay: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0.35), location: 0.45),
                        .init(color: .black.opacity(0.78), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom)

                VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(
                        .constant(musicManager.displayTitle),
                        font: .caption, nsFont: .caption1,
                        textColor: .white,
                        frameWidth: max(geo.size.width - 12, 30))
                    .fontWeight(.semibold)
                    // Dropped rather than blanked: an empty marquee still reserves its
                    // line, which is how the artist slot ended up looking like a bug
                    // whenever a player named a track but not who made it.
                    if !musicManager.displayArtist.isEmpty {
                        MarqueeText(
                            .constant(musicManager.displayArtist),
                            font: .caption2, nsFont: .caption2,
                            textColor: Defaults[.playerColorTinting]
                                ? Color(nsColor: musicManager.avgColor)
                                    .ensureMinimumBrightness(factor: 0.85)
                                : .white.opacity(0.72),
                            frameWidth: max(geo.size.width - 12, 30))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed))
        }
        .aspectRatio(1, contentMode: .fit)
        .opacity(revealing ? 0 : 1)
        .allowsHitTesting(false)
    }

    private var albumArtBackground: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                ZStack(alignment:.bottomTrailing) {
                    albumArtImage
                    appIconOverlay
                }
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(musicManager.isPlaying ? 1 : 0.85)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .saturation(showingIdentity ? 0.82 : 1)
            .opacity(showingIdentity ? 0.72 : 1)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }

    /// True while the title is sitting on the cover and the cover is faded for it.
    private var showingIdentity: Bool {
        vm.notchState == .open && Defaults[.albumArtShowsIdentity] && !revealing
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        if Defaults[.showPlayerAppBadge]
            && vm.notchState == .open && !musicManager.usingAppIconForArtwork {
            AppIcon(for: musicManager.bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
        @EnvironmentObject var vm: BoringViewModel
        @ObservedObject var webcamManager = WebcamManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit
    @Default(.lyricsShowContext) private var showLyricsContext

    var body: some View {
        VStack(alignment: .leading) {
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 4) {
                    lyricsBlock(width: geo.size.width)
                    musicSlider
                }
            }
            .padding(.top, 10)
            .padding(.leading, 5)
            slotToolbar
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// The lyrics, in the column the title and artist used to occupy.
    ///
    /// The timeline ticks four times a second to keep the position current, but the column
    /// itself only depends on which line is playing. `.equatable()` makes SwiftUI compare
    /// the inputs and skip rebuilding the column on the ticks that change nothing — without
    /// it the scroll was being torn down and rebuilt underneath its own animation.
    @ViewBuilder
    private func lyricsBlock(width: CGFloat) -> some View {
        if Defaults[.enableLyrics] {
            TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                let currentElapsed: Double = {
                    guard musicManager.isPlaying else { return musicManager.elapsedTime }
                    let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                    let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
                    return min(max(progressed, 0), musicManager.songDuration)
                }()

                LyricScrollColumn(
                    lines: musicManager.lyricLines,
                    index: musicManager.lyricIndex(at: currentElapsed),
                    width: width,
                    showsContext: showLyricsContext,
                    isFetching: musicManager.isFetchingLyrics,
                    isPlaying: musicManager.isPlaying
                )
                .equatable()
            }
        }
    }

    private var musicSlider: some View {
        TimelineView(.animation(minimumInterval: musicManager.playbackRate > 0 ? 0.1 : nil)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, 5)
            .frame(height: 36)
        }
    }

    /// A slot that reads rather than clicks. Sized and coloured like the buttons beside it
    /// so the row still scans as one thing.
    private func slotReadout(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 84)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func remaining(_ seconds: Double) -> String {
        let value = max(0, seconds)
        return String(format: "-%d:%02d", Int(value) / 60, Int(value) % 60)
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(for: slot)
                    .frame(alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        let result = Array(padded.prefix(sanitizedLimit))
        // If calendar and camera are both visible alongside music, hide the edge slots
        let shouldHideEdges = Defaults[.showCalendar] && Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
        if shouldHideEdges && result.count >= 5 {
            return Array(result.dropFirst().dropLast())
        }

        return result
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .album:
            slotReadout(musicManager.album)
        case .remaining:
            TimelineView(.animation(minimumInterval: 1, paused: !musicManager.isPlaying)) { timeline in
                let elapsed = musicManager.isPlaying
                    ? min(musicManager.elapsedTime
                        + timeline.date.timeIntervalSince(musicManager.timestampDate)
                        * musicManager.playbackRate, musicManager.songDuration)
                    : musicManager.elapsedTime
                slotReadout(Self.remaining(musicManager.songDuration - elapsed))
            }
        case .rotating:
            RotatingMusicSlot()
        case .weather:
            slotReadout(WeatherManager.shared.temperatureText ?? "—")

        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .red : .primary, scale: .medium) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", scale: .medium) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", scale: .medium) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .red
        }
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .red : .primary
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if musicManager.volumeControlSupported {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showVolumeSlider.toggle()
                    }
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(musicManager.volumeControlSupported ? .white : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!musicManager.volumeControlSupported)
            .frame(width: 24)

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .white,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    }
                )
                .frame(width: 48, height: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipped()
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                // Sync volume from app when slider appears
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
        .onDisappear {
            // volumeUpdateTask?.cancel() // No longer needed
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var shouldShowCamera: Bool {
        Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: (shouldShowCamera && Defaults[.showCalendar]) ? 10 : 15) {
            MusicPlayerView(albumArtNamespace: albumArtNamespace)

            if Defaults[.showCalendar] {
                CalendarView()
                    .frame(width: shouldShowCamera ? 170 : 215)
                    .onHover { isHovering in
                        vm.isHoveringCalendar = isHovering
                    }
                    .environmentObject(vm)
                    .transition(.opacity)
            }

            if shouldShowCamera {
                CameraPreviewView(webcamManager: webcamManager)
                    .scaledToFit()
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .blur(radius: vm.notchState == .closed ? 20 : 0)
                    .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.76, blendDuration: 0), value: shouldShowCamera)
            }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}

/// Three rows of lyric that scroll as the song advances.
///
/// A long line wraps to a second row rather than truncating, which is what Spotify does —
/// truncation loses the end of the line, and the end is often the part that rhymes. Rows
/// are therefore not one-per-lyric, so each line is placed by accumulating row counts out
/// from the current line rather than by multiplying an index.
struct LyricScrollColumn: View, Equatable {
    let lines: [String]
    let index: Int
    let width: CGFloat
    let showsContext: Bool
    let isFetching: Bool
    let isPlaying: Bool

    /// A wrapped line costs a row that a context line would otherwise have used, so two is
    /// the ceiling: at three the current line fills the column on its own.
    private static let maximumRows = 2

    private var visibleRows: Int { showsContext ? 3 : 1 }
    private var centreRow: Int { showsContext ? 1 : 0 }

    var body: some View {
        Group {
            if lines.isEmpty {
                row(isFetching ? "Loading lyrics…" : "No lyrics found", isCurrent: false, rows: 1)
            } else {
                ZStack(alignment: .topLeading) {
                    ForEach(placements, id: \.position) { placement in
                        row(
                            lines[placement.position],
                            isCurrent: placement.position == index,
                            rows: placement.rows
                        )
                        .offset(y: CGFloat(centreRow + placement.row) * lyricLineHeight)
                        .animation(.smooth(duration: 0.4), value: placement.row)
                    }
                }
                .frame(width: width, alignment: .topLeading)
            }
        }
        .frame(
            width: width,
            height: lyricLineHeight * CGFloat(visibleRows),
            alignment: .topLeading)
        .clipped()
        .opacity(isPlaying ? 1 : 0)
    }

    /// Where each nearby line sits, in rows relative to the current one.
    ///
    /// Positions are accumulated outward from the current line instead of measured from the
    /// start of the song: only a handful of lines are ever on screen, and summing every
    /// preceding line's height on each tick to reach line 200 would be wasted work.
    private var placements: [(position: Int, row: Int, rows: Int)] {
        var result: [(position: Int, row: Int, rows: Int)] = []

        var cursor = 0
        for position in index..<min(index + 3, lines.count) {
            let rows = rowCount(for: lines[position])
            result.append((position, cursor, rows))
            cursor += rows
        }

        cursor = 0
        for position in stride(from: index - 1, through: max(index - 2, 0), by: -1) {
            let rows = rowCount(for: lines[position])
            cursor -= rows
            result.append((position, cursor, rows))
        }

        return result
    }

    /// Whether a line fits on one row at this width.
    ///
    /// Measured against the real font rather than counted in characters — Hangul is roughly
    /// twice the advance width of a Latin letter, so a character count would call a short
    /// Korean line short when it is not.
    private func rowCount(for text: String) -> Int {
        guard width > 0 else { return 1 }
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        let measured = NSAttributedString(string: text, attributes: [.font: font]).size().width
        return measured <= width ? 1 : Self.maximumRows
    }

    /// Splits a leading singer tag off a lyric line.
    ///
    /// K-pop sheets on LRCLIB routinely name the member singing each line —
    /// "(Moka) What are you doing in that". Worth keeping, but it is an annotation rather
    /// than the lyric, and at this width it pushes the actual words off the end. Only a
    /// parenthetical at the very start counts: mid-line parentheses are backing vocals,
    /// which *are* lyrics, and a line that is nothing but a parenthetical is an ad-lib.
    private static func splitSingerTag(_ text: String) -> (tag: String, body: String) {
        guard text.hasPrefix("("), let close = text.firstIndex(of: ")") else { return ("", text) }
        let tag = String(text[...close])
        let rest = text[text.index(after: close)...].drop { $0 == " " }
        guard !rest.isEmpty, tag.count <= 24 else { return ("", text) }
        return (tag + " ", String(rest))
    }

    private func row(_ text: String, isCurrent: Bool, rows: Int) -> some View {
        let isPersian = text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return v >= 0x0600 && v <= 0x06FF
        }
        let (tag, body) = Self.splitSingerTag(text)
        let styled: Text = tag.isEmpty
            ? Text(text)
            : Text(tag).foregroundColor(.gray.opacity(isCurrent ? 0.6 : 0.4)) + Text(body)

        return styled
            .font(isPersian
                ? .custom("Vazirmatn-Regular",
                          size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize)
                : .subheadline)
            // One weight for every row, current or not.
            //
            // The current line used to be .medium and its neighbours .regular, which meant
            // the weight changed under the scroll animation — and an animating font weight
            // is re-rasterised glyph by glyph, which a CJK fallback face does not survive:
            // the Korean lines blanked out while they moved. Spotify separates the current
            // line by colour alone for the same reason it reads better.
            .fontWeight(.medium)
            .foregroundStyle(isCurrent ? Color.white : Color.gray.opacity(0.5))
            .lineLimit(rows)
            .multilineTextAlignment(.leading)
            .truncationMode(.tail)
            .frame(
                width: width,
                height: lyricLineHeight * CGFloat(rows),
                alignment: .topLeading)
    }
}

/// What the playback track needs to find the audio it is drawing.
struct SpectrumTrackSource: Equatable {
    var isPlaying: Bool
    var bundleIdentifier: String?
}

struct MusicSliderView: View {
    @Default(.showRemainingTime) private var showRemainingTime
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void


    /// Matches `CustomSlider`'s spectrum height, so the taller track is not clipped by
    /// the box it sits in.
    private var trackHeight: CGFloat { Defaults[.spectrumPlaybackTrack] ? 16 : 10 }

    var body: some View {
        VStack(spacing: 2) {
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                    : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange,
                spectrum: SpectrumTrackSource(
                    isPlaying: isPlaying,
                    bundleIdentifier: MusicManager.shared.bundleIdentifier)
            )
            .frame(height: trackHeight, alignment: .center)

            HStack {
                Text(timeString(from: sliderValue))
                Spacer()
                // Click to swap between time left and total length, the way Spotify's own
                // label does. Its own tap target, so it cannot steal a scrub.
                Text(
                    showRemainingTime
                        ? "-" + timeString(from: max(0, duration - sliderValue))
                        : timeString(from: duration)
                )
                .contentTransition(.numericText())
                .onTapGesture { showRemainingTime.toggle() }
            }
            .fontWeight(.medium)
            .foregroundColor(
                Defaults[.playerColorTinting]
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
            )
            .font(.caption)
        }
        .onChange(of: currentDate) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?
    /// Set by the playback bar to draw its track as the live spectrum. Left nil by the
    /// volume slider, which stays a plain rule -- there is nothing to visualise about a
    /// volume level, and it is a control people aim at.
    var spectrum: SpectrumTrackSource?

    @Default(.spectrumPlaybackTrack) private var spectrumTrack

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            let spectrumActive = spectrum != nil && spectrumTrack && !dragging
            // 10 pt is enough for a rule and not enough for a spectrum. The extra six
            // come out of the gap above the time labels, not out of the notch.
            let trackHeight: CGFloat = spectrumActive ? 16 : 10

            ZStack(alignment: .leading) {
                if let spectrum, spectrumActive {
                    SpectrumTrack(
                        progress: min(max(progress, 0), 1),
                        color: color,
                        isPlaying: spectrum.isPlaying,
                        bundleIdentifier: spectrum.bundleIdentifier,
                        restingHeight: height
                    )
                    .frame(height: trackHeight)
                } else {
                    Rectangle()
                        .fill(.gray.opacity(0.3))
                        .frame(height: height)
                        .cornerRadius(height / 2)

                    Rectangle()
                        .fill(color)
                        .frame(width: filledTrackWidth, height: height)
                        .cornerRadius(height / 2)
                }
            }
            .frame(height: trackHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}

// MARK: - Rotating slot

/// A readout that cycles the way the stats board does, for people who would rather have
/// information in the slot row than a control they never press.
///
/// Hovering advances it immediately rather than pausing — the board holds on hover because
/// its figures are being read, but here the whole point is to reach the one you want, and
/// waiting out a timer to see it is worse than nudging it along.
struct RotatingMusicSlot: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var weather = WeatherManager.shared

    private enum Readout: CaseIterable { case album, remaining, weather }

    @State private var index = 0
    @State private var timer: Timer?

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 84)
            .contentShape(Rectangle())
            .id(index)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)))
            .clipped()
            .onHover { hovering in
                if hovering { advance() }
            }
            .onAppear(perform: start)
            .onDisappear(perform: stop)
    }

    private var text: String {
        switch Readout.allCases[index % Readout.allCases.count] {
        case .album:
            return musicManager.album.isEmpty ? "—" : musicManager.album
        case .remaining:
            let left = max(0, musicManager.songDuration - musicManager.elapsedTime)
            return String(format: "-%d:%02d", Int(left) / 60, Int(left) % 60)
        case .weather:
            guard let conditions = weather.conditions,
                  let temperature = weather.temperatureText
            else { return "—" }
            return "\(temperature) \(conditions.condition.label.capitalized)"
        }
    }

    private func advance() {
        withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
            index = (index + 1) % Readout.allCases.count
        }
    }

    /// Stored, guarded, invalidated on the way out — the same discipline every other timer
    /// in this app follows since the leaked blink timers.
    private func start() {
        stop()
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
