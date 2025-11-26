//
//  NightGard CommanderTypes.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/25/25.
//

import SwiftUI

/// Available visualizer types
enum VisualizerType: String, CaseIterable, Identifiable {
    case albumArt = "Album Art"
    case albumArtPulse = "Album Art (Pulse)"
    case waveform = "Waveform"
    case spectrum = "Spectrum"
    case circular = "Circular"
    case particles = "Particles"
    case abstract = "Abstract"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .albumArt: return "photo"
        case .albumArtPulse: return "photo.fill"
        case .waveform: return "waveform"
        case .spectrum: return "chart.bar.fill"
        case .circular: return "circle.hexagongrid.fill"
        case .particles: return "sparkles"
        case .abstract: return "lasso.badge.sparkles"
        }
    }
}

/// Container view that displays the currently selected visualizer
struct VisualizerContainer: View {
    let type: VisualizerType
    let frequencyData: [Float]
    let amplitude: Float
    var albumArtwork: NSImage? = nil

    var body: some View {
        switch type {
        case .albumArt:
            AlbumArtStaticVisualizer(artwork: albumArtwork)
        case .albumArtPulse:
            AlbumArtVisualizer(artwork: albumArtwork, amplitude: amplitude)
        case .waveform:
            WaveformVisualizer(frequencyData: frequencyData, amplitude: amplitude)
        case .spectrum:
            SpectrumVisualizer(frequencyData: frequencyData, amplitude: amplitude)
        case .circular:
            CircularVisualizer(frequencyData: frequencyData, amplitude: amplitude)
        case .particles:
            ParticleVisualizer(frequencyData: frequencyData, amplitude: amplitude)
        case .abstract:
            AbstractVisualizer(frequencyData: frequencyData, amplitude: amplitude)
        }
    }
}

/// Album Art Visualizer - displays album artwork with subtle pulse animation
struct AlbumArtVisualizer: View {
    let artwork: NSImage?
    let amplitude: Float

    // Track artwork for transitions
    @State private var displayedArtwork: NSImage?
    @State private var artworkID = UUID()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [Color.black, Color.black.opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                if let image = displayedArtwork {
                    // Album art with pulse effect based on audio
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: min(geometry.size.width, geometry.size.height) * (0.85 + CGFloat(amplitude) * 0.1),
                            height: min(geometry.size.width, geometry.size.height) * (0.85 + CGFloat(amplitude) * 0.1)
                        )
                        .cornerRadius(12)
                        .shadow(color: .white.opacity(Double(amplitude) * 0.3), radius: CGFloat(amplitude) * 20)
                        .animation(.easeOut(duration: 0.1), value: amplitude)
                        .id(artworkID)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    // Fallback when no artwork
                    VStack(spacing: 16) {
                        Image(systemName: "music.note")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)
                            .scaleEffect(1.0 + CGFloat(amplitude) * 0.2)
                            .animation(.easeOut(duration: 0.1), value: amplitude)
                        Text("No Album Art")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .id("no-artwork")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeInOut(duration: 0.5), value: artworkID)
        }
        .onChange(of: artwork) { oldValue, newValue in
            // Animate artwork change
            withAnimation(.easeInOut(duration: 0.5)) {
                displayedArtwork = newValue
                artworkID = UUID()
            }
        }
        .onAppear {
            displayedArtwork = artwork
        }
    }
}

/// Album Art Static Visualizer - displays album artwork without animation
struct AlbumArtStaticVisualizer: View {
    let artwork: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black

                if let image = artwork {
                    // Static album art - no animation
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: min(geometry.size.width, geometry.size.height) * 0.85,
                            height: min(geometry.size.width, geometry.size.height) * 0.85
                        )
                        .cornerRadius(12)
                } else {
                    // Fallback when no artwork
                    VStack(spacing: 16) {
                        Image(systemName: "music.note")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)
                        Text("No Album Art")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }
}
