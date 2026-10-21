//
//  VoiceDictationLiveActivity.swift
//  boringNotch
//
//  Closed-notch strip for a dictation take, laid out like the music strip: an icon on
//  the left and live mic bars on the right. Nothing the user said is shown here. Failures
//  and the model download add one short message cell to say why.
//

import SwiftUI

/// Motion for the dictation strip: the chin width leads on one spring, the content
/// follows on its own spring 80 ms later.
enum DictationMotion {
    static let expand = Animation.spring(response: 0.38, dampingFraction: 0.72, blendDuration: 0)
    static let collapse = Animation.spring(response: 0.34, dampingFraction: 0.92, blendDuration: 0)
    static let content = Animation.spring(response: 0.28, dampingFraction: 0.8).delay(0.08)
}

struct VoiceDictationLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var voice = VoiceDictationManager.shared

    private var side: CGFloat { max(0, vm.effectiveClosedNotchHeight - 12) }

    private var showsMessage: Bool {
        switch voice.state {
        case .failed: return true
        case .recording: return voice.downloadingModel
        default: return false
        }
    }

    var body: some View {
        HStack {
            leftCell
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)
            rightCell
                .transition(.scale(scale: 0.6).combined(with: .opacity))
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
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    let problem = voice.micStatus == .noSignal || voice.micStatus == .quiet
                    Image(systemName: voice.micStatus == .noSignal ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(problem ? Color.orange : Color.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            case .processing:
                ProgressView().controlSize(.mini)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
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
            withMessage("Downloading speech model", bars: bars(.rest, dim: false))
        case .recording:
            bars(.live, dim: voice.micStatus == .waiting || voice.micStatus == .noSignal)
        case .processing:
            bars(voice.refining ? .rest : .idle, dim: false, refining: voice.refining)
        case .done:
            bars(.rest, dim: false)
        case .failed(let message):
            withMessage(DictationStrip.headline(message), bars: bars(.rest, dim: false))
        }
    }

    /// The strip's bars cell, then one message cell to its right. The message is the
    /// headline only, so it always fits `DictationStrip.messageWidth`.
    private func withMessage<Bars: View>(_ headline: String, bars: Bars) -> some View {
        HStack(spacing: 0) {
            bars
            Text(headline)
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: DictationStrip.messageWidth, alignment: .leading)
                .padding(.trailing, 6)
        }
    }

    /// The music strip's spectrum cell, fed by the mic instead of the playing track.
    private func bars(_ mode: MicSpectrumView.Mode, dim: Bool, refining: Bool = false) -> some View {
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
        .modifier(RefiningShimmer(active: refining))
    }
}

/// While the cloud pass refines the pasted text, a dark band sweeps across the bars.
/// The bars keep their place, so the strip's width does not change.
private struct RefiningShimmer: ViewModifier {
    let active: Bool
    @State private var sweeping = false

    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.7), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: sweeping ? geo.size.width : -geo.size.width * 0.6)
                    }
                }
                .clipped()
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        sweeping = true
                    }
                }
        } else {
            content
        }
    }
}
