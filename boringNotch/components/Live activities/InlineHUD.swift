//
//  InlineHUDs.swift
//  boringNotch
//
//  Created by Richard Kunkli on 14/09/2024.
//

import SwiftUI
import Defaults

struct InlineHUD: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    @Binding var detail: String
    @Binding var detailSecondary: String
    /// Set by the caller when `type` alone cannot say what the left word is.
    @Binding var label: String
    /// The icon's colour. White for everything that predates this, so the only things that
    /// gain colour are the ones that asked for it.
    @Binding var tint: Color
    @Binding var hoverAnimation: Bool
    @Binding var gestureProgress: CGFloat
    @State private var showSecondary = false
    var body: some View {
        HStack {
            HStack(spacing: 5) {
                Group {
                    switch (type) {
                        case .volume:
                            if icon.isEmpty {
                                Image(systemName: SpeakerSymbol(value))
                                    .contentTransition(.interpolate)
                                    .symbolVariant(value > 0 ? .none : .slash)
                                    .frame(width: 20, height: 15, alignment: .leading)
                            } else {
                                Image(systemName: icon)
                                    .contentTransition(.interpolate)
                                    .opacity(value.isZero ? 0.6 : 1)
                                    .scaleEffect(value.isZero ? 0.85 : 1)
                                    .frame(width: 20, height: 15, alignment: .leading)
                            }
                        case .brightness:
                            Image(systemName: BrightnessSymbol(value))
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .backlight:
                            Image(systemName: value > 0.5 ? "light.max" : "light.min")
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .wifi:
                            Image(systemName: "wifi")
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .bluetooth:
                            Image(systemName: icon.isEmpty ? "dot.radiowaves.right" : icon)
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .systemAlert:
                            Image(systemName: icon.isEmpty ? "exclamationmark.triangle" : icon)
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        case .mic:
                            Image(systemName: "mic")
                                .symbolRenderingMode(.hierarchical)
                                .symbolVariant(value > 0 ? .none : .slash)
                                .contentTransition(.interpolate)
                                .frame(width: 20, height: 15, alignment: .center)
                        default:
                            EmptyView()
                    }
                }
                // Was hardcoded white, which is why the notch read as grey-on-black no
                // matter what it was telling you. The icon is the one element that can carry
                // colour without costing legibility, so it is the only one that does: the
                // text stays white and keeps its contrast.
                .foregroundStyle(tint)
                .symbolVariant(.fill)
                
                Text(leftLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    // The slot is a fixed ~88pt and "Disconnected" is wider than that, so it
                    // came out as "Disconne...". Shrinking a long word to fit keeps the whole
                    // word; truncating it loses the only thing the left side is for.
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                    .contentTransition(.numericText())
            }
            .frame(width: 100 - (hoverAnimation ? 0 : 12) + gestureProgress / 2, height: vm.notchSize.height - (hoverAnimation ? 0 : 12), alignment: .leading)
            
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 20)
            
            HStack {
                if type.isAnnouncement {
                    // The whole point of the layout: what happened on the left of the
                    // notch, which thing it happened to on the right -- and the right side
                    // gets two beats, because "connected" and "which network" both want the
                    // same few characters and the name is the half worth waiting for.
                    Text(showSecondary && !detailSecondary.isEmpty ? detailSecondary : detail)
                        .id(showSecondary && !detailSecondary.isEmpty)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.tail)
                        .allowsTightening(true)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .onAppear {
                            showSecondary = false
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(1100))
                                withAnimation(.snappy(duration: 0.28)) { showSecondary = true }
                            }
                        }
                } else if (type == .mic) {
                    Text(value.isZero ? "muted" : "unmuted")
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.interpolate)
                } else {
                        HStack {
                        DraggableProgressBar(value: $value, onChange: { v in
                            if type == .volume {
                                VolumeManager.shared.setAbsolute(Float32(v))
                            } else if type == .brightness {
                                BrightnessManager.shared.setAbsolute(value: Float32(v))
                            }
                        })
                        if (type == .volume && value.isZero) {
                            Text("muted")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.gray)
                                .lineLimit(1)
                                .allowsTightening(true)
                                .multilineTextAlignment(.trailing)
                        } else if Defaults[.showClosedNotchHUDPercentage] {
                            Text("\(Int(value * 100))%")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.gray)
                                .lineLimit(1)
                                .allowsTightening(true)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .padding(.trailing, 4)
            .frame(width: 100 - (hoverAnimation ? 0 : 12) + gestureProgress / 2, height: vm.closedNotchSize.height - (hoverAnimation ? 0 : 12), alignment: .center)
        }
        .frame(height: vm.closedNotchSize.height + (hoverAnimation ? 8 : 0), alignment: .center)
    }
    
    func SpeakerSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0:
                return "speaker"
            case 0...0.3:
                return "speaker.wave.1"
            case 0.3...0.8:
                return "speaker.wave.2"
            case 0.8...1:
                return "speaker.wave.3"
            default:
                return "speaker.wave.2"
        }
    }
    
    func BrightnessSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0...0.6:
                return "sun.min"
            case 0.6...1:
                return "sun.max"
            default:
                return "sun.min"
        }
    }
    
    /// The word on the left of the notch.
    ///
    /// For a connection event this is the *event*, not the subsystem: "Disconnected" beside
    /// the device's name says something, whereas "Bluetooth" beside "Bluetooth device ..."
    /// said the same word twice and truncated the half that mattered.
    private var leftLabel: String {
        switch type {
        case .bluetooth: value == 1 ? "Connected" : "Disconnected"
        case .wifi: value == 1 ? "Wi-Fi" : "Wi-Fi lost"
        // The rule picks its own word -- "CPU high" and "Draining" arrive under one type,
        // so there is nothing here that could derive it.
        case .systemAlert: label.isEmpty ? "System" : label
        default: Type2Name(type)
        }
    }

    func Type2Name(_ type: SneakContentType) -> String {
        switch(type) {
            case .volume:
                return "Volume"
            case .brightness:
                return "Brightness"
            case .backlight:
                return "Backlight"
            case .mic:
                return "Mic"
            case .wifi:
                return "Wi-Fi"
            case .bluetooth:
                return "Bluetooth"
            default:
                return ""
        }
    }
}

#Preview {
    InlineHUD(type: .constant(.brightness), value: .constant(0.4), icon: .constant(""), detail: .constant(""), detailSecondary: .constant(""), label: .constant(""), tint: .constant(.white), hoverAnimation: .constant(false), gestureProgress: .constant(0))
        .padding(.horizontal, 8)
        .background(Color.black)
        .padding()
        .environmentObject(BoringViewModel())
}
