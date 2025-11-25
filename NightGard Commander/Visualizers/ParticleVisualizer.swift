//
//  ParticleVisualizer.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/25/25.
//

import SwiftUI

/// Particle system that reacts to audio
struct ParticleVisualizer: View {
    let frequencyData: [Float]
    let amplitude: Float

    @State private var particles: [Particle] = []
    @State private var timer: Timer?

    private let maxParticles = 150

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            TimelineView(.animation) { timeline in
                Canvas { context, canvasSize in
                    for particle in particles {
                        let age = timeline.date.timeIntervalSince(particle.birthTime)
                        let lifeProgress = age / particle.lifetime

                        guard lifeProgress < 1 else { continue }

                        // Calculate current position
                        let x = particle.startX + particle.velocityX * age
                        let y = particle.startY + particle.velocityY * age + (50 * age * age) // gravity

                        // Fade out as particle ages
                        let opacity = (1 - lifeProgress) * particle.opacity

                        // Scale down as particle ages
                        let scale = particle.size * (1 - lifeProgress * 0.5)

                        let rect = CGRect(
                            x: x - scale / 2,
                            y: y - scale / 2,
                            width: scale,
                            height: scale
                        )

                        context.fill(
                            Circle().path(in: rect),
                            with: .color(particle.color.opacity(opacity))
                        )
                    }
                }
            }
            .background(.black)
            .onChange(of: amplitude) { _, newValue in
                // Spawn particles based on amplitude
                if newValue > 0.3 {
                    spawnParticles(in: size, intensity: newValue)
                }
            }
            .onAppear {
                // Spawn initial particles
                for _ in 0..<30 {
                    spawnParticles(in: size, intensity: 0.5)
                }

                // Continuous spawning
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    spawnParticles(in: size, intensity: amplitude)
                    cleanupOldParticles()
                }
            }
            .onDisappear {
                timer?.invalidate()
            }
        }
    }

    private func spawnParticles(in size: CGSize, intensity: Float) {
        let count = Int(intensity * 5) + 1

        for _ in 0..<count {
            guard particles.count < maxParticles else { break }

            // Get frequency-based color
            let freqIndex = Int.random(in: 0..<frequencyData.count)
            let freqValue = frequencyData[freqIndex]
            let hue = Double(freqIndex) / Double(frequencyData.count)

            let particle = Particle(
                startX: CGFloat.random(in: 0...size.width),
                startY: size.height + 20,
                velocityX: CGFloat.random(in: -30...30),
                velocityY: CGFloat.random(in: -200...(-100)) * CGFloat(intensity),
                size: CGFloat.random(in: 4...12) * CGFloat(freqValue + 0.5),
                color: Color(hue: hue, saturation: 0.9, brightness: 1.0),
                opacity: Double.random(in: 0.6...1.0),
                lifetime: Double.random(in: 1.5...3.0),
                birthTime: Date()
            )

            particles.append(particle)
        }
    }

    private func cleanupOldParticles() {
        let now = Date()
        particles.removeAll { particle in
            now.timeIntervalSince(particle.birthTime) > particle.lifetime
        }
    }
}

/// Individual particle data
struct Particle: Identifiable {
    let id = UUID()
    let startX: CGFloat
    let startY: CGFloat
    let velocityX: CGFloat
    let velocityY: CGFloat
    let size: CGFloat
    let color: Color
    let opacity: Double
    let lifetime: TimeInterval
    let birthTime: Date
}

#Preview {
    ParticleVisualizer(
        frequencyData: (0..<64).map { _ in Float.random(in: 0.2...0.9) },
        amplitude: 0.7
    )
    .frame(height: 400)
}
