//
//  DictationSounds.swift
//  boringNotch
//
//  Subtle start and stop cues for a dictation take. They are macOS system sounds,
//  so no audio is bundled, and they play only when the user has them switched on.
//

import AppKit
import Defaults

enum DictationSounds {
    /// Held here so the sound is not released before it has played.
    private static var current: NSSound?

    static func playStart() {
        play("Tink")
    }

    static func playStop() {
        play("Pop")
    }

    private static func play(_ name: String) {
        guard Defaults[.dictationSounds] else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0.25
        current = sound
        sound.play()
    }
}
