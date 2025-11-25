//
//  CircularVisualizer.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/25/25.
//

import SwiftUI

/// Radial/circular frequency visualization
struct CircularVisualizer: View {
    let frequencyData: [Float]
    let amplitude: Float

    @State private var rotation: Double = 0

    private let barCount = 64

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(geometry.size.width, geometry.size.height) * 0.35
            let maxBarHeight = radius * 0.8

            ZStack {
                // Background glow
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.purple.opacity(0.3 * Double(amplitude)),
                                Color.clear
                            ]),
                            center: .center,
                            startRadius: radius * 0.5,
                            endRadius: radius * 1.5
                        )
                    )
                    .frame(width: radius * 3, height: radius * 3)

                // Inner circle
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.cyan, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
                    .frame(width: radius * 2, height: radius * 2)

                // Frequency bars arranged in circle
                Canvas { context, size in
                    for i in 0..<barCount {
                        let angle = (CGFloat(i) / CGFloat(barCount)) * .pi * 2 - .pi / 2
                        let dataIndex = i * frequencyData.count / barCount
                        let value = CGFloat(frequencyData[min(dataIndex, frequencyData.count - 1)])
                        let barHeight = value * maxBarHeight * CGFloat(amplitude)

                        let innerPoint = CGPoint(
                            x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius
                        )
                        let outerPoint = CGPoint(
                            x: center.x + cos(angle) * (radius + barHeight),
                            y: center.y + sin(angle) * (radius + barHeight)
                        )

                        var path = Path()
                        path.move(to: innerPoint)
                        path.addLine(to: outerPoint)

                        // Color based on frequency position
                        let hue = Double(i) / Double(barCount)
                        let color = Color(hue: hue, saturation: 0.9, brightness: 1.0)

                        context.stroke(
                            path,
                            with: .color(color),
                            lineWidth: 3
                        )
                    }
                }
                .rotationEffect(.degrees(rotation))

                // Center amplitude indicator
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                .white,
                                Color.cyan.opacity(Double(amplitude))
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: 30
                        )
                    )
                    .frame(width: 60 * CGFloat(amplitude) + 20, height: 60 * CGFloat(amplitude) + 20)
                    .animation(.easeOut(duration: 0.1), value: amplitude)
            }
            .position(center)
        }
        .background(.black)
        .onAppear {
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

#Preview {
    CircularVisualizer(
        frequencyData: (0..<64).map { _ in Float.random(in: 0.2...0.9) },
        amplitude: 0.7
    )
    .frame(width: 400, height: 400)
}
