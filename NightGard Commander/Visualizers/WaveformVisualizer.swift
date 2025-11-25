//
//  WaveformVisualizer.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/25/25.
//

import SwiftUI

/// Classic waveform visualization - smooth curves based on frequency data
struct WaveformVisualizer: View {
    let frequencyData: [Float]
    let amplitude: Float

    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let midY = size.height / 2
                let width = size.width
                let dataCount = frequencyData.count

                // Draw multiple layered waveforms
                for layer in 0..<3 {
                    let layerOpacity = 1.0 - Double(layer) * 0.3
                    let layerOffset = CGFloat(layer) * 0.2

                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: midY))

                    for i in 0..<Int(width) {
                        let progress = CGFloat(i) / width
                        let dataIndex = Int(progress * CGFloat(dataCount - 1))
                        let nextDataIndex = min(dataIndex + 1, dataCount - 1)

                        // Interpolate between data points
                        let fraction = (progress * CGFloat(dataCount - 1)) - CGFloat(dataIndex)
                        let value = CGFloat(frequencyData[dataIndex]) * (1 - fraction) +
                                   CGFloat(frequencyData[nextDataIndex]) * fraction

                        // Create wave with phase offset
                        let wavePhase = phase + progress * .pi * 4 + layerOffset
                        let waveHeight = value * CGFloat(amplitude) * midY * 0.8
                        let y = midY + sin(wavePhase) * waveHeight

                        path.addLine(to: CGPoint(x: CGFloat(i), y: y))
                    }

                    // Stroke the path
                    context.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color.cyan.opacity(layerOpacity),
                                Color.blue.opacity(layerOpacity),
                                Color.purple.opacity(layerOpacity)
                            ]),
                            startPoint: CGPoint(x: 0, y: midY),
                            endPoint: CGPoint(x: width, y: midY)
                        ),
                        lineWidth: 2
                    )
                }

                // Draw center line
                var centerLine = Path()
                centerLine.move(to: CGPoint(x: 0, y: midY))
                centerLine.addLine(to: CGPoint(x: width, y: midY))
                context.stroke(centerLine, with: .color(.white.opacity(0.2)), lineWidth: 1)
            }
        }
        .background(.black)
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

#Preview {
    WaveformVisualizer(
        frequencyData: (0..<64).map { _ in Float.random(in: 0.2...0.8) },
        amplitude: 0.7
    )
    .frame(height: 300)
}
