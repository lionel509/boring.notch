//
//  VoiceDictationLiveActivity.swift
//  boringNotch
//
//  Closed-notch strip for a dictation take: listening (with the live partial text),
//  transcribing, pasted, or the reason it failed.
//

import SwiftUI

struct VoiceDictationLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var voice = VoiceDictationManager.shared

    var body: some View {
        HStack {
            Color.clear
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12))

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(spacing: 5) {
                        Spacer(minLength: vm.closedNotchSize.width)
                        content
                        Spacer(minLength: 0)
                    }
                )
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    @ViewBuilder
    private var content: some View {
        switch voice.state {
        case .idle:
            EmptyView()
        case .recording:
            Text(voice.liveText.isEmpty ? "Listening" : voice.liveText)
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(1)
                .truncationMode(.head)
            ListeningDots()
        case .processing:
            Text("Transcribing")
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(1)
            ProgressView()
                .controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Pasted")
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(1)
        case .failed(let message):
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
    }
}
