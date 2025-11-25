//
//  NightGard CommanderTypes.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/25/25.
//

import SwiftUI

/// Available visualizer types
enum VisualizerType: String, CaseIterable, Identifiable {
    case waveform = "Waveform"
    case spectrum = "Spectrum"
    case circular = "Circular"
    case particles = "Particles"
    case abstract = "Abstract"

    var id: String { rawValue }

    var icon: String {
        switch self {
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

    var body: some View {
        switch type {
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
