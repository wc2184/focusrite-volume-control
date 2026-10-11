//
//  VolumeHUDView.swift
//  Focusrite Volume Control
//
//  Sonoma-style volume overlay with the Focusrite Control 2 icon.
//

import SwiftUI
import Combine

class VolumeHUDViewModel: ObservableObject {
    @Published var volumeDb: Double = -20
    @Published var isMuted: Bool = false

    var filledTickCount: Int {
        isMuted ? 0 : VolumeTickScale.tick(for: volumeDb)
    }
}

struct VolumeHUDView: View {
    @ObservedObject var viewModel: VolumeHUDViewModel
    static let panelSize: CGFloat = 200

    var body: some View {
        Color.clear
            .frame(width: Self.panelSize, height: Self.panelSize)
            .overlay(alignment: .topLeading) {
                Image("FocusriteControlIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 125, height: 125)
                    .offset(x: 37.5, y: 29.5)
            }
            .overlay(alignment: .topLeading) {
                SonomaVolumeBar(filledTickCount: viewModel.filledTickCount)
                    .frame(width: 160, height: 8)
                    .offset(x: 20, y: 172)
            }
        .accessibilityLabel("Focusrite volume")
        .accessibilityValue("\(viewModel.filledTickCount) of 16 ticks")
    }
}

private struct SonomaVolumeBar: View {
    let filledTickCount: Int

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color(red: 135 / 255, green: 135 / 255, blue: 138 / 255))

            HStack(spacing: 1) {
                ForEach(0..<16, id: \.self) { index in
                    Color.clear
                        .frame(width: 9, height: 7)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color(red: 246 / 255, green: 245 / 255, blue: 248 / 255))
                                .frame(width: index < filledTickCount ? 9 : 0, height: 7)
                        }
                }
            }
            // The ticks and gaps span 159 points, leaving a Retina pixel at each edge.
            .offset(x: 0.5)
        }
        .frame(width: 160, height: 8)
    }
}
