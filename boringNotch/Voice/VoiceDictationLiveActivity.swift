//
//  VoiceDictationLiveActivity.swift
//  boringNotch
//
//  Closed-notch strip for a dictation take, laid out like the music strip: an icon on
//  the left and live mic bars on the right, with no text while listening. Failures
//  and the model download still say why in words.
//

import SwiftUI

struct VoiceDictationLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var voice = VoiceDictationManager.shared

    private var side: CGFloat { max(0, vm.effectiveClosedNotchHeight - 12) }

    var body: some View {
        HStack {
            leftCell
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)
            rightCell
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    @ViewBuilder
    private var leftCell: some View {
        Group {
            switch voice.state {
            case .idle:
                EmptyView()
            case .recording:
                if voice.downloadingModel {
                    ProgressView().controlSize(.mini)
                } else {
                    let problem = voice.micStatus == .noSignal || voice.micStatus == .quiet
                    Image(systemName: voice.micStatus == .noSignal ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(problem ? Color.orange : Color.white)
                }
            case .processing:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: side, height: side)
    }

    @ViewBuilder
    private var rightCell: some View {
        switch voice.state {
        case .idle:
            EmptyView()
        case .recording where voice.downloadingModel:
            Text("Downloading speech model")
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 6)
        case .recording:
            bars(.live, dim: voice.micStatus == .waiting || voice.micStatus == .noSignal)
        case .processing:
            bars(.idle, dim: false)
        case .done:
            bars(.rest, dim: false)
        case .failed(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 6)
        }
    }

    /// The music strip's spectrum cell, fed by the mic instead of the playing track.
    private func bars(_ mode: MicSpectrumView.Mode, dim: Bool) -> some View {
        HStack {
            Rectangle()
                .fill(Color.white)
                .frame(width: 50, alignment: .center)
                .mask {
                    MicSpectrumView(mode: mode)
                        .frame(width: 20, height: 12)
                }
        }
        .frame(width: side, height: side, alignment: .center)
        .opacity(dim ? 0.4 : 1)
    }
}
