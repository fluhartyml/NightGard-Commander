//
//  AudioAnalyzer.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/25/25.
//

import AVFoundation
import Accelerate
import Observation

/// Separate FFT processor that's Sendable for concurrent access
final class FFTProcessor: Sendable {
    private let fftSize: Int
    private let fftSetup: FFTSetup
    private let log2n: vDSP_Length

    init(fftSize: Int = 2048) {
        self.fftSize = fftSize
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func performFFT(_ data: UnsafeMutablePointer<Float>, frameCount: Int) -> [Float] {
        let halfSize = fftSize / 2
        var realPart = [Float](repeating: 0, count: halfSize)
        var imagPart = [Float](repeating: 0, count: halfSize)

        // Apply Hanning window
        var windowedData = [Float](repeating: 0, count: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let copyCount = min(frameCount, fftSize)
        for i in 0..<copyCount {
            windowedData[i] = data[i] * window[i]
        }

        windowedData.withUnsafeMutableBufferPointer { windowedPtr in
            realPart.withUnsafeMutableBufferPointer { realPtr in
                imagPart.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(
                        realp: realPtr.baseAddress!,
                        imagp: imagPtr.baseAddress!
                    )

                    windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfSize))
                    }

                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                    var magnitudes = [Float](repeating: 0, count: halfSize)
                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))

                    var normalizedMagnitudes = [Float](repeating: 0, count: halfSize)
                    var one: Float = 1
                    vDSP_vdbcon(&magnitudes, 1, &one, &normalizedMagnitudes, 1, vDSP_Length(halfSize), 0)

                    let bandCount = 64
                    let bandsPerGroup = halfSize / bandCount
                    var bands = [Float](repeating: 0, count: bandCount)

                    for i in 0..<bandCount {
                        let startIdx = i * bandsPerGroup
                        let endIdx = min(startIdx + bandsPerGroup, halfSize)
                        var sum: Float = 0
                        for j in startIdx..<endIdx {
                            sum += normalizedMagnitudes[j]
                        }
                        let avg = sum / Float(endIdx - startIdx)
                        bands[i] = max(0, min(1, (avg + 80) / 80))
                    }

                    for i in 0..<bandCount {
                        realPtr[i] = bands[i]
                    }
                }
            }
        }

        return Array(realPart.prefix(64))
    }
}

/// Real-time audio analyzer that taps into AVPlayer audio
@Observable
@MainActor
final class AudioAnalyzer {
    // MARK: - Published Data

    private(set) var frequencyData: [Float] = Array(repeating: 0, count: 64)
    private(set) var amplitude: Float = 0
    private(set) var isAnalyzing: Bool = false

    // MARK: - Private Properties

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let fftProcessor = FFTProcessor()
    private let fftSize: Int = 2048
    private var audioFile: AVAudioFile?

    // MARK: - Public Methods

    /// Start analyzing audio from a file URL (creates internal player)
    func startAnalyzing(url: URL) {
        stopAnalyzing()

        do {
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()

            engine.attach(playerNode)

            let audioFile = try AVAudioFile(forReading: url)
            self.audioFile = audioFile

            let format = audioFile.processingFormat
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)

            // Install tap for analysis
            let bufferSize: AVAudioFrameCount = AVAudioFrameCount(fftSize)
            let processor = fftProcessor

            engine.mainMixerNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)

                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
                let normalizedAmplitude = min(rms * 5, 1.0)

                let frequencyBands = processor.performFFT(channelData, frameCount: frameLength)

                Task { @MainActor [weak self] in
                    self?.amplitude = normalizedAmplitude
                    self?.frequencyData = frequencyBands
                }
            }

            try engine.start()
            playerNode.scheduleFile(audioFile, at: nil)
            playerNode.play()

            self.engine = engine
            self.playerNode = playerNode
            self.isAnalyzing = true

        } catch {
            print("AudioAnalyzer error: \(error)")
        }
    }

    /// Stop analyzing and clean up
    func stopAnalyzing() {
        playerNode?.stop()
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        playerNode = nil
        audioFile = nil
        isAnalyzing = false
        amplitude = 0
        frequencyData = Array(repeating: 0, count: 64)
    }

    /// Start demo mode with generated data
    func startDemoMode() {
        stopAnalyzing()
        isAnalyzing = true
        Task { [weak self] in
            await self?.runDemoLoop()
        }
    }

    /// Stop demo mode
    func stopDemoMode() {
        isAnalyzing = false
        amplitude = 0
        frequencyData = Array(repeating: 0, count: 64)
    }

    // MARK: - Private Methods

    private func runDemoLoop() async {
        while isAnalyzing {
            var newData = [Float](repeating: 0, count: 64)
            for i in 0..<64 {
                let base = Float.random(in: 0.1...0.9)
                let weight = 1.0 - (Float(i) / 64.0) * 0.5
                newData[i] = base * weight
            }

            for i in 0..<64 {
                frequencyData[i] = frequencyData[i] * 0.7 + newData[i] * 0.3
            }

            amplitude = Float.random(in: 0.3...0.8)

            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
