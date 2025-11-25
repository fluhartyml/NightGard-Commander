//
//  SpectrumVisualizer.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/25/25.
//

import SwiftUI

/// Classic spectrum analyzer with frequency bars
struct SpectrumVisualizer: View {
    let frequencyData: [Float]
    let amplitude: Float

    // Number of bars to display
    private let barCount = 32

    var body: some View {
        GeometryReader { geometry in
            let barWidth = geometry.size.width / CGFloat(barCount)
            let spacing: CGFloat = 2
            let actualBarWidth = barWidth - spacing

            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        SpectrumBar(
                            value: getBarValue(for: index),
                            maxHeight: geometry.size.height,
                            barWidth: actualBarWidth,
                            index: index,
                            totalBars: barCount
                        )
                    }
                }
            }
        }
        .background(.black)
    }

    /// Get the value for a specific bar by averaging nearby frequency data
    private func getBarValue(for barIndex: Int) -> CGFloat {
        let dataPerBar = frequencyData.count / barCount
        let startIndex = barIndex * dataPerBar
        let endIndex = min(startIndex + dataPerBar, frequencyData.count)

        guard startIndex < frequencyData.count else { return 0 }

        var sum: Float = 0
        for i in startIndex..<endIndex {
            sum += frequencyData[i]
        }
        let avg = sum / Float(endIndex - startIndex)

        // Apply amplitude scaling
        return CGFloat(avg * amplitude)
    }
}

/// Individual bar in the spectrum
struct SpectrumBar: View {
    let value: CGFloat
    let maxHeight: CGFloat
    let barWidth: CGFloat
    let index: Int
    let totalBars: Int

    var body: some View {
        let height = max(4, value * maxHeight * 0.9)
        let progress = CGFloat(index) / CGFloat(totalBars)

        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        barColor(for: progress),
                        barColor(for: progress).opacity(0.6)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: barWidth, height: height)
            .animation(.easeOut(duration: 0.1), value: value)
    }

    /// Color based on position (bass = warm, treble = cool)
    private func barColor(for progress: CGFloat) -> Color {
        if progress < 0.33 {
            // Bass - red/orange
            return Color(hue: 0.05 + progress * 0.1, saturation: 0.9, brightness: 1.0)
        } else if progress < 0.66 {
            // Mids - yellow/green
            return Color(hue: 0.15 + (progress - 0.33) * 0.3, saturation: 0.9, brightness: 1.0)
        } else {
            // Treble - cyan/blue
            return Color(hue: 0.5 + (progress - 0.66) * 0.3, saturation: 0.9, brightness: 1.0)
        }
    }
}

#Preview {
    SpectrumVisualizer(
        frequencyData: (0..<64).map { i in
            // Simulate bass-heavy audio
            let position = Float(i) / 64.0
            return Float.random(in: 0.2...0.9) * (1.0 - position * 0.5)
        },
        amplitude: 0.8
    )
    .frame(height: 300)
}
