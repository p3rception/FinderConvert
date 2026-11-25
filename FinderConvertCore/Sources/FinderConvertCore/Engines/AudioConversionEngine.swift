import AudioToolbox
import AVFoundation
import CLame
import Foundation
import OSLog

public actor AudioConversionEngine: ConversionEngine {
    public let identifier = "com.finderconvert.engine.audio.native"
    private let logger = Logger(subsystem: "FinderConvert", category: "audio-engine")
    private let naming = OutputNamingStrategy()

    public init() {}

    private static let supportedInputs: Set<DetectedFileType> = [.mp3, .m4a, .wav, .aiff, .flac, .ogg]
    private static let supportedOutputs: Set<OutputFormat> = [.mp3, .m4a, .wav, .aiff, .flac]

    public nonisolated func supports(input: DetectedFileType, output: OutputFormat) -> Bool {
        Self.supportedInputs.contains(input) && Self.supportedOutputs.contains(output)
    }

    public func convert(
        job: ConversionJob,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        var isStale = false
        let sourceURL = try URL(
            resolvingBookmarkData: job.sourceBookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        let access = SecurityScopedAccess(url: sourceURL)
        let inputType = try FileTypeDetector().detect(url: sourceURL).detectedType
        guard supports(input: inputType, output: job.requestedOutput) else {
            throw ConversionError.unsupportedOutput(job.requestedOutput)
        }

        let destinationURL = try naming.destinationURL(
            for: sourceURL,
            outputFormat: job.requestedOutput,
            policy: job.destinationPolicy
        )

        progress(0.1)
        try await encode(source: sourceURL, destination: destinationURL, output: job.requestedOutput, progress: progress)
        _ = access
        progress(1.0)
        return ConversionResult(sourceURL: sourceURL, outputURL: destinationURL, outputFormat: job.requestedOutput)
    }

    public func cancel(jobID: UUID) async {}

    // The audio track of any asset (audio file or video) in an audio format,
    // with the format's settings, including its loudness target
    func encode(source: URL, destination: URL, output: OutputFormat, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch output {
        case .mp3:
            try await exportToMP3(source: source, destination: destination, progress: progress)
        case .m4a, .wav, .aiff:
            try await exportWithAssetWriter(source: source, destination: destination, output: output, progress: progress)
        case .flac:
            try await exportToFLAC(source: source, destination: destination, progress: progress)
        default:
            throw ConversionError.unsupportedOutput(output)
        }
    }

    // Reads the track as PCM in `settings`, raised or lowered to the
    // format's loudness target when one is set
    private func pcmOutput(track: AVAssetTrack, in asset: AVAsset, settings: [String: Any], output: OutputFormat) async throws -> AVAssetReaderOutput {
        let target = PreferencesManager.shared.loudnessTarget(for: output)
        guard target != 0, let gain = try Loudness.gain(of: track, in: asset, to: Double(target), settings: settings), gain != 1 else {
            return AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        }
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(gain, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        mixOutput.audioMix = mix
        return mixOutput
    }

    // MARK: - MP3 via LAME

    private func exportToMP3(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.filesystemError("No audio track found in source file.")
        }

        let sampleRate = PreferencesManager.shared.audioSampleRate(for: .mp3)
        let bitrate = PreferencesManager.shared.audioBitrate(for: .mp3)

        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = try await pcmOutput(track: audioTrack, in: asset, settings: readerSettings, output: .mp3)
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw ConversionError.filesystemError(reader.error?.localizedDescription ?? "Failed to read audio.")
        }

        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        // Initialize LAME
        guard let lame = lame_init() else {
            throw ConversionError.filesystemError("Failed to initialize MP3 encoder.")
        }
        lame_set_in_samplerate(lame, Int32(sampleRate))
        lame_set_num_channels(lame, 2)
        lame_set_brate(lame, Int32(bitrate / 1000))
        lame_set_quality(lame, 2) // 0=best, 9=fastest
        lame_set_mode(lame, JOINT_STEREO)
        lame_init_params(lame)

        // Open output file
        guard let outFile = fopen(destination.path, "wb") else {
            lame_close(lame)
            throw ConversionError.filesystemError("Could not create output MP3 file.")
        }

        let mp3BufSize = 8640
        let mp3Buf = UnsafeMutablePointer<UInt8>.allocate(capacity: mp3BufSize)
        defer {
            mp3Buf.deallocate()
            fclose(outFile)
            lame_close(lame)
        }

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)

            guard let pcm = pcmBytes(of: blockBuffer) else { continue }

            // Interleaved 16-bit stereo PCM
            let frames = min(numSamples, pcm.count / 4)
            let written = pcm.withUnsafeBytes { raw in
                lame_encode_buffer_interleaved(lame, UnsafeMutablePointer(mutating: raw.bindMemory(to: Int16.self).baseAddress),
                                               Int32(frames), mp3Buf, Int32(mp3BufSize))
            }

            if written > 0 {
                fwrite(mp3Buf, 1, Int(written), outFile)
            }

            // Progress
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if totalSeconds > 0 {
                let p = min(0.9, 0.1 + 0.8 * (CMTimeGetSeconds(ts) / totalSeconds))
                progress(p)
            }
        }

        // Flush remaining MP3 data
        let flushed = lame_encode_flush(lame, mp3Buf, Int32(mp3BufSize))
        if flushed > 0 {
            fwrite(mp3Buf, 1, Int(flushed), outFile)
        }
    }

    private func exportWithAssetWriter(
        source: URL,
        destination: URL,
        output: OutputFormat,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.filesystemError("No audio track found in source file.")
        }

        let prefs = PreferencesManager.shared
        let sampleRate = prefs.audioSampleRate(for: output)
        let channels = output.supportsAudioChannels ? prefs.audioChannels(for: output) : 2
        let fileType: AVFileType
        let outputSettings: [String: Any]

        switch output {
        case .m4a:
            // AAC at the chosen bitrate; the Apple M4A export preset this
            // replaced ignored the bitrate setting
            fileType = .m4a
            outputSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: prefs.audioBitrate(for: output),
            ]
        case .wav:
            fileType = .wav
            outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .aiff:
            fileType = .aiff
            outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
        default:
            throw ConversionError.unsupportedOutput(output)
        }

        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = try await pcmOutput(track: audioTrack, in: asset, settings: readerOutputSettings, output: output)
        reader.add(readerOutput)

        guard writer.startWriting() else {
            throw ConversionError.filesystemError(writer.error?.localizedDescription ?? "Failed to start audio writer.")
        }
        guard reader.startReading() else {
            throw ConversionError.filesystemError(reader.error?.localizedDescription ?? "Failed to start audio reader.")
        }

        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio-writer")) {
                while writerInput.isReadyForMoreMediaData {
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let currentSeconds = CMTimeGetSeconds(timestamp)
                    if totalSeconds > 0 {
                        let pct = min(0.9, 0.1 + 0.8 * (currentSeconds / totalSeconds))
                        progress(pct)
                    }
                    writerInput.append(sampleBuffer)
                }
            }
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            throw ConversionError.filesystemError(writer.error?.localizedDescription ?? "Audio writer failed.")
        }
    }

    // MARK: - FLAC via ExtAudioFile (AudioToolbox)

    private func exportToFLAC(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.filesystemError("No audio track found in source file.")
        }

        let sampleRate = PreferencesManager.shared.audioSampleRate(for: .flac)
        let channels = PreferencesManager.shared.audioChannels(for: .flac)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        // Read source as PCM via AVAssetReader
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = try await pcmOutput(track: audioTrack, in: asset, settings: readerSettings, output: .flac)
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw ConversionError.filesystemError(reader.error?.localizedDescription ?? "Failed to read audio.")
        }

        // Setup ExtAudioFile for FLAC output
        var inputASBD = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatFLAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Fill in output ASBD defaults
        var outputASBDSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fillStatus = AudioFormatGetProperty(
            kAudioFormatProperty_FormatInfo,
            0, nil,
            &outputASBDSize, &outputASBD
        )
        if fillStatus != noErr {
            logger.warning("AudioFormatGetProperty returned \(fillStatus), proceeding with manual ASBD.")
        }

        var extAudioFile: ExtAudioFileRef?
        let destCF = destination as CFURL
        let createStatus = ExtAudioFileCreateWithURL(
            destCF,
            kAudioFileFLACType,
            &outputASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &extAudioFile
        )

        guard createStatus == noErr, let outputFile = extAudioFile else {
            throw ConversionError.filesystemError("Failed to create FLAC output file (status: \(createStatus)).")
        }

        defer { ExtAudioFileDispose(outputFile) }

        // Set client data format (the PCM format we'll feed it)
        var status = ExtAudioFileSetProperty(
            outputFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &inputASBD
        )
        guard status == noErr else {
            throw ConversionError.filesystemError("Failed to set FLAC client format (status: \(status)).")
        }

        // Write PCM buffers to FLAC
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)

            guard var pcm = pcmBytes(of: blockBuffer) else { continue }

            status = pcm.withUnsafeMutableBytes { raw in
                var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(raw.count),
                    mData: raw.baseAddress
                ))
                return ExtAudioFileWrite(outputFile, UInt32(numSamples), &bufferList)
            }
            if status != noErr {
                throw ConversionError.filesystemError("Failed to write FLAC data (status: \(status)).")
            }

            // Progress
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if totalSeconds > 0 {
                let p = min(0.9, 0.1 + 0.8 * (CMTimeGetSeconds(ts) / totalSeconds))
                progress(p)
            }
        }
    }
}

// The sample buffer's PCM bytes. CMBlockBufferGetDataPointer only reaches
// the first contiguous segment of a block buffer; copying covers all of it
func pcmBytes(of block: CMBlockBuffer) -> Data? {
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0 else { return nil }
    var data = Data(count: length)
    let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
    return status == kCMBlockBufferNoErr ? data : nil
}

// Integrated loudness per ITU-R BS.1770-4 / EBU R128: K-weighting, 400 ms
// blocks every 100 ms, absolute gate at -70 LUFS, relative gate 10 LU below.
// Matched ffmpeg's ebur128 filter to 0.1 LU on the files tested
enum Loudness {
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func callAsFunction(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    // The two K-weighting stages (high shelf, then high pass) for any rate
    private static func kWeighting(sampleRate fs: Double) -> [Biquad] {
        var k = tan(.pi * 1681.974450955533 / fs)
        let q1 = 0.7071752369554196, vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q1 + k * k
        let shelf = Biquad(b0: (vh + vb * k / q1 + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q1 + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0)
        k = tan(.pi * 38.13547087602444 / fs)
        let q2 = 0.5003270373238773
        a0 = 1 + k / q2 + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q2 + k * k) / a0)
        return [shelf, highPass]
    }

    // LUFS and sample peak of the track as decoded with `settings` (the
    // output's sample rate and channels), so a mono downmix is measured as
    // mono. Streams: only one energy value per 100 ms is kept
    static func measure(_ track: AVAssetTrack, in asset: AVAsset, settings: [String: Any]) throws -> (lufs: Double, peak: Double) {
        var floatSettings = settings
        floatSettings[AVLinearPCMBitDepthKey] = 32
        floatSettings[AVLinearPCMIsFloatKey] = true
        floatSettings[AVLinearPCMIsNonInterleaved] = false
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: floatSettings)
        reader.add(output)
        guard reader.startReading() else { throw ConversionError.unreadableInput }

        let rate = Double(settings[AVSampleRateKey] as? Int ?? 44100)
        let channels = max(1, settings[AVNumberOfChannelsKey] as? Int ?? 2)
        // L, R, C weigh 1; in 5.1 the LFE (4th) is skipped and surrounds weigh 1.41
        let weights: [Double] = channels == 6 ? [1, 1, 1, 0, 1.41, 1.41] : Array(repeating: 1, count: channels)
        var filters = Array(repeating: kWeighting(sampleRate: rate), count: channels)
        let segmentLength = max(1, Int(rate / 10))
        var segments: [Double] = []
        var energy = 0.0, filled = 0, peak = 0.0

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer), let pcm = pcmBytes(of: block) else { continue }
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Float.self)
                for frame in stride(from: 0, to: samples.count - channels + 1, by: channels) {
                    for channel in 0..<channels {
                        let x = Double(samples[frame + channel])
                        peak = max(peak, abs(x))
                        let y = filters[channel][1](filters[channel][0](x))
                        energy += weights[channel] * y * y
                    }
                    filled += 1
                    if filled == segmentLength {
                        segments.append(energy)
                        energy = 0
                        filled = 0
                    }
                }
            }
        }
        guard reader.status == .completed else { throw ConversionError.unreadableInput }

        let blockLength = Double(segmentLength * 4)
        let blocks = segments.count >= 4 ? (0...(segments.count - 4)).map { segments[$0..<$0 + 4].reduce(0, +) / blockLength } : []
        let loudness = { (z: Double) in -0.691 + 10 * log10(z) }
        let audible = blocks.filter { loudness($0) > -70 }
        guard !audible.isEmpty else { return (-.infinity, peak) }
        let relativeGate = loudness(audible.reduce(0, +) / Double(audible.count)) - 10
        let gated = audible.filter { loudness($0) > relativeGate }
        return (loudness(gated.reduce(0, +) / Double(gated.count)), peak)
    }

    // Linear gain that brings the track to `target` LUFS, capped so the
    // sample peak stays at or below -1 dBFS (a quiet track with loud spikes
    // ends up under the target instead of clipping). nil for silence
    static func gain(of track: AVAssetTrack, in asset: AVAsset, to target: Double, settings: [String: Any]) throws -> Float? {
        let (lufs, peak) = try measure(track, in: asset, settings: settings)
        guard lufs.isFinite, peak > 0 else { return nil }
        let wanted = pow(10, (target - lufs) / 20)
        let ceiling = pow(10, -1.0 / 20) / peak
        return Float(min(wanted, ceiling))
    }
}
