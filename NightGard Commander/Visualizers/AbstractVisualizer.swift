//
//  AbstractVisualizer.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/25/25.
//

import SwiftUI

/// Morphing geometric shapes that react to audio
struct AbstractVisualizer: View {
    let frequencyData: [Float]
    let amplitude: Float

    @State private var phase: CGFloat = 0
    @State private var colorPhase: CGFloat = 0

    private let shapeCount = 5

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let maxRadius = min(geometry.size.width, geometry.size.height) * 0.4

            ZStack {
                // Background gradient that pulses with amplitude
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(hue: colorPhase.truncatingRemainder(dividingBy: 1), saturation: 0.3, brightness: 0.2),
                        .black
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: maxRadius * 2
                )
                .scaleEffect(1 + CGFloat(amplitude) * 0.2)

                // Multiple morphing shapes
                ForEach(0..<shapeCount, id: \.self) { shapeIndex in
                    MorphingShape(
                        frequencyData: frequencyData,
                        amplitude: amplitude,
                        phase: phase + CGFloat(shapeIndex) * .pi / CGFloat(shapeCount),
                        center: center,
                        baseRadius: maxRadius * (1 - CGFloat(shapeIndex) * 0.15),
                        hueOffset: CGFloat(shapeIndex) * 0.2 + colorPhase
                    )
                    .opacity(1 - Double(shapeIndex) * 0.15)
                }

                // Center shape
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                .white,
                                Color(hue: colorPhase.truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 1)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 40
                        )
                    )
                    .frame(width: 80 * CGFloat(amplitude) + 20, height: 80 * CGFloat(amplitude) + 20)
                    .position(center)
                    .blur(radius: 10)
            }
        }
        .background(.black)
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
            withAnimation(.linear(duration: 15).repeatForever(autoreverses: false)) {
                colorPhase = 1
            }
        }
    }
}

/// A single morphing shape
struct MorphingShape: View {
    let frequencyData: [Float]
    let amplitude: Float
    let phase: CGFloat
    let center: CGPoint
    let baseRadius: CGFloat
    let hueOffset: CGFloat

    private let pointCount = 64

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var firstPoint: CGPoint?

            for i in 0..<pointCount {
                let angle = CGFloat(i) / CGFloat(pointCount) * .pi * 2
                let dataIndex = i * frequencyData.count / pointCount
                let freqValue = CGFloat(frequencyData[min(dataIndex, frequencyData.count - 1)])

                // Modulate radius based on frequency and phase
                let radiusModulation = freqValue * baseRadius * 0.4 * CGFloat(amplitude)
                let phaseModulation = sin(angle * 3 + phase) * baseRadius * 0.1
                let radius = baseRadius + radiusModulation + phaseModulation

                let point = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )

                if i == 0 {
                    path.move(to: point)
                    firstPoint = point
                } else {
                    path.addLine(to: point)
                }
            }

            // Close the path
            if let first = firstPoint {
                path.addLine(to: first)
            }

            // Create gradient fill
            let hue = (hueOffset).truncatingRemainder(dividingBy: 1)
            context.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(hue: hue, saturation: 0.8, brightness: 0.9),
                        Color(hue: (hue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.7)
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            // Add stroke
            context.stroke(
                path,
                with: .color(.white.opacity(0.3)),
                lineWidth: 1
            )
        }
    }
}

#Preview {
    AbstractVisualizer(
        frequencyData: (0..<64).map { _ in Float.random(in: 0.2...0.9) },
        amplitude: 0.7
    )
    .frame(width: 400, height: 400)
}
