//
//  GhostTextLiveActivity.swift
//  boringNotch
//

import SwiftUI

/// Closed-notch fallback for a suggestion when the caret position cannot be read.
struct GhostTextLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var ghost = GhostTextManager.shared

    private var side: CGFloat { max(0, vm.effectiveClosedNotchHeight - 12) }

    var body: some View {
        HStack {
            Image(systemName: "text.cursor")
                .foregroundStyle(.gray)
                .frame(width: side, height: side)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)
            Text(ghost.notchSuggestion ?? "")
                .font(.caption)
                .foregroundStyle(.gray)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }
}
