//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let bundleIdentifier = Bundle.main.bundleIdentifier!
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let spacing: CGFloat = 16

struct CustomVisualizer: Codable, Hashable, Equatable, Defaults.Serializable {
    let UUID: UUID
    var name: String
    var url: URL
    var speed: CGFloat = 1.0
}

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

// Define notification names at file scope
extension Notification.Name {
    static let mediaControllerChanged = Notification.Name("mediaControllerChanged")
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying = "Now Playing"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    case youtubeMusic = "YouTube Music"
    
    var id: String { self.rawValue }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard = "Default"
    case inline = "Inline"
    
    var id: String { self.rawValue }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings = "Open System Settings"
    case showHUD = "Show HUD"
    case none = "No Action"

    var id: String { self.rawValue }
}

extension Defaults.Keys {
    // MARK: General
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let releaseName = Key<String>("releaseName", default: "Flying Rabbit 🐇🪽")
    
    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let extendHoverArea = Key<Bool>("extendHoverArea", default: false)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    //static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
    
    // MARK: Appearance
    static let showEmojis = Key<Bool>("showEmojis", default: false)
    //static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: false)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)

    // Bottom stats strip. Off by default: it reads a log path that only exists on a
    // machine running the Switchboard proxy, and an empty row is worse than no row.
    static let showStatsStrip = Key<Bool>("showStatsStrip", default: false)
    static let statsStripShowUsage = Key<Bool>("statsStripShowUsage", default: true)
    static let statsStripShowSystem = Key<Bool>("statsStripShowSystem", default: true)
    static let statsStripShowBattery = Key<Bool>("statsStripShowBattery", default: true)
    static let batteryHistory = Key<[Double]>("batteryHistory", default: [])

    // Weather backdrop.
    static let showWeatherBackdrop = Key<Bool>("showWeatherBackdrop", default: false)
    static let weatherBackdropIntensity = Key<Double>("weatherBackdropIntensity", default: 0.8)
    /// A place name the user types. Geocoded once and cached below. Not an IP lookup — that
    /// would hand a third party an address on every refresh.
    /// Blur the desktop behind the notch and tint it with the weather, rather than
    /// painting a sky. Real glass over the actual wallpaper.
    static let weatherUseDesktopBlur = Key<Bool>("weatherUseDesktopBlur", default: true)
    /// Show the line before and after the current lyric, not just the current one. Costs
    /// notch height, so it is a choice rather than the default shape.
    static let lyricsShowContext = Key<Bool>("lyricsShowContext", default: true)

    /// Light the notch while an app is recording from the microphone.
    /// Name the app holding the microphone in the closed notch.
    ///
    /// Off by default. macOS already says a microphone is open in two places at once —
    /// the orange mic in the menu bar and the dot in Control Center — and a third
    /// statement of it an inch away carries no information. Off also means the CoreAudio
    /// process listeners are never registered, so the feature costs nothing at all until
    /// it is asked for.
    static let showDictationActivity = Key<Bool>("showDictationActivity", default: false)

    static let dictationDiagnostic = Key<String>("dictationDiagnostic", default: "not started")

    /// The badge for the app the music is coming from, on the artwork's corner. Off: it
    /// only earns its space when more than one player is actually in use.
    static let showPlayerAppBadge = Key<Bool>("showPlayerAppBadge", default: false)

    /// Title and artist sit in the corner of the artwork, which fades so they stay
    /// readable and clears on hover so the cover can actually be seen.
    static let albumArtShowsIdentity = Key<Bool>("albumArtShowsIdentity", default: true)

    /// Right-hand time on the scrubber: time left rather than total length. Spotify makes
    /// that label clickable and remembers the choice, so this does too.
    static let showRemainingTime = Key<Bool>("showRemainingTime", default: true)

    /// Show the current temperature under the month in the calendar panel, in place of
    /// the year. Falls back to the year on its own when no place is set.
    static let calendarShowsTemperature = Key<Bool>("calendarShowsTemperature", default: true)
    static let weatherPlace = Key<String>("weatherPlace", default: "")
    static let weatherResolvedPlace = Key<String>("weatherResolvedPlace", default: "")
    static let weatherLatitude = Key<Double>("weatherLatitude", default: 0)
    static let weatherLongitude = Key<Double>("weatherLongitude", default: 0)
    /// Seconds a page holds before the board flips. 0 pins it to whatever is showing.
    /// Four, not six: with only two pages a six-second hold means a twelve-second round
    /// trip, which reads as broken rather than as slow.
    static let statsStripFlipInterval = Key<Double>("statsStripFlipInterval", default: 4)
    static let statsStripShowCPU = Key<Bool>("statsStripShowCPU", default: true)
    static let statsStripShowMemory = Key<Bool>("statsStripShowMemory", default: true)
    static let statsStripShowNetwork = Key<Bool>("statsStripShowNetwork", default: true)
    static let statsStripSparklines = Key<Bool>("statsStripSparklines", default: true)
    static let statsStripColor = Key<Bool>("statsStripColor", default: true)
    static let routerLogPath = Key<String>(
        "routerLogPath", default: "~/.local/share/claude-router/requests.log")
    /// Security-scoped bookmark for the request log. The app is sandboxed, so a plain
    /// path outside the container is unreadable no matter what it is set to; the user
    /// grants access once and this survives relaunch.
    static let routerLogBookmark = Key<Data>("routerLogBookmark", default: Data())
    /// Outcome of the last log scan, in words. Persisted so the Settings pane can say
    /// what happened without waiting for a rescan, and so a failure is inspectable after
    /// the fact rather than only visible as an empty row.
    static let routerLogDiagnostic = Key<String>("routerLogDiagnostic", default: "never read")

    static let wisprDatabasePath = Key<String>(
        "wisprDatabasePath",
        default: "~/Library/Application Support/Wispr Flow/flow.sqlite")
    /// Security-scoped bookmark for the Wispr Flow folder. Same reason as the request
    /// log, plus one of its own: SQLite needs the `-wal` sidecar beside the database to
    /// see anything dictated since the last checkpoint.
    static let wisprDatabaseBookmark = Key<Data>("wisprDatabaseBookmark", default: Data())
    /// Words dictated per local day, accumulated by this app.
    ///
    /// Persisted rather than derived, and that is forced: Wispr Flow prunes its local
    /// history once it has uploaded, so the database holds hours, not weeks. A window
    /// longer than that can only exist if something keeps the tally, and this is it.
    static let wisprWordsByDay = Key<[String: Int]>("wisprWordsByDay", default: [:])
    /// Highest transcript timestamp already counted, so a row is never banked twice.
    static let wisprLastSeen = Key<String>("wisprLastSeen", default: "")
    static let wisprDiagnostic = Key<String>("wisprDiagnostic", default: "never read")
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)
    static let useMusicVisualizer = Key<Bool>("useMusicVisualizer", default: true)
    static let customVisualizers = Key<[CustomVisualizer]>("customVisualizers", default: [])
    static let selectedVisualizer = Key<CustomVisualizer?>("selectedVisualizer", default: nil)
    
    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)
    
    // MARK: Media playback
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)

    /// Draw the playback bar as the live spectrum of what is playing rather than as a
    /// plain rule. The visualiser is otherwise only visible while the notch is closed,
    /// which is the one time nobody is looking at it.
    static let spectrumPlaybackTrack = Key<Bool>("spectrumPlaybackTrack", default: true)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: false)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let showShuffleAndRepeat = Key<Bool>("showShuffleAndRepeat", default: false)
    static let enableLyrics = Key<Bool>("enableLyrics", default: false)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )
    
    // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)
    
    // MARK: Downloads
    static let enableDownloadListener = Key<Bool>("enableDownloadListener", default: true)
    static let enableSafariDownloads = Key<Bool>("enableSafariDownloads", default: true)
    static let selectedDownloadIndicatorStyle = Key<DownloadIndicatorStyle>("selectedDownloadIndicatorStyle", default: DownloadIndicatorStyle.progress)
    static let selectedDownloadIconStyle = Key<DownloadIconStyle>("selectedDownloadIconStyle", default: DownloadIconStyle.onlyAppIcon)
    
    // MARK: HUD
    static let hudReplacement = Key<Bool>("hudReplacement", default: false)
    static let inlineHUD = Key<Bool>("inlineHUD", default: false)
    static let enableGradient = Key<Bool>("enableGradient", default: false)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchHUD = Key<Bool>("showOpenNotchHUD", default: true)
    static let showOpenNotchHUDPercentage = Key<Bool>("showOpenNotchHUDPercentage", default: true)
    static let showClosedNotchHUDPercentage = Key<Bool>("showClosedNotchHUDPercentage", default: false)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    
    // MARK: Shelf
    static let boringShelf = Key<Bool>("boringShelf", default: true)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: true)
    static let shelfTapToOpen = Key<Bool>("shelfTapToOpen", default: true)
    static let quickShareProvider = Key<String>("quickShareProvider", default: QuickShareProvider.defaultProvider.id)
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: false)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)
    
    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    
    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)
    
    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    
    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    
    // Helper to determine the default media controller based on NowPlaying deprecation status
    static var defaultMediaController: MediaControllerType {
        if MusicManager.shared.isNowPlayingDeprecated {
            return .appleMusic
        } else {
            return .nowPlaying
        }
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)
}
