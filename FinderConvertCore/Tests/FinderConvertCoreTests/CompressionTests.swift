import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import FinderConvertCore

// Same-format compression: output naming, the never-bigger guard, and the
// Finder menu estimates. Runs with the default settings (JPEG quality 0.9)
final class CompressionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "compression-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeSample(named name: String, type: UTType, quality: Double) throws -> URL {
        let image = try XCTUnwrap(QualityPreviewRenderer.sample())
        let url = directory.appending(path: name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testOnlyFormatsWithSameFormatEncodersCompress() {
        for type: DetectedFileType in [.jpeg, .png, .tiff, .gif, .bmp, .mov, .mp3, .wav, .flac, .pdf] {
            XCTAssertTrue(Compression.isCompressible(type), type.rawValue)
        }
        for type: DetectedFileType in [.svg, .ogg, .webm, .docx] {
            XCTAssertFalse(Compression.isCompressible(type), type.rawValue)
        }
    }

    func testCompressWritesSmallerCopyBesideSource() async throws {
        let source = try writeSample(named: "photo.jpg", type: .jpeg, quality: 1.0)
        let result = try await QuickActionConversionService().compress(urls: [source])

        let output = try XCTUnwrap(result.successes.first?.outputURL)
        XCTAssertEqual(output.lastPathComponent, "photo compressed.jpg")
        XCTAssertLessThan(try XCTUnwrap(Compression.fileSize(output)), try XCTUnwrap(Compression.fileSize(source)))
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testCompressKeepsOriginalWhenReencodeIsNotSmaller() async throws {
        let source = try writeSample(named: "tiny.jpg", type: .jpeg, quality: 0.1)
        let result = try await QuickActionConversionService().compress(urls: [source])

        XCTAssertEqual(result.skipped, [source])
        XCTAssertTrue(result.successes.isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["tiny.jpg"])
    }

    func testCompressRejectsSelectionWithNothingCompressible() async throws {
        let source = directory.appending(path: "notes.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await QuickActionConversionService().compress(urls: [source])
            XCTFail("A text file should not compress")
        } catch ConversionError.unsupportedSelection {}
    }

    // Runs the body with a built-in preset applied, restoring settings after
    private func withPreset<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        let prefs = PreferencesManager.shared
        let snapshot = try XCTUnwrap(prefs.captureSettingsSnapshotData())
        defer { prefs.restoreSettingsSnapshot(snapshot) }
        prefs.applyPresetValues(try XCTUnwrap(prefs.presetSettings(named: name)))
        return try await body()
    }

    func testPaletteCompressionKeepsTransparency() async throws {
        // Opaque left half, fading alpha on the right
        let width = 256, height = 128
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(QualityPreviewRenderer.sample()), in: CGRect(x: 0, y: 0, width: width, height: height))
        for x in (width / 2)..<width {
            context.clear(CGRect(x: x, y: 0, width: 1, height: height))
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: CGFloat(width - x) / CGFloat(width / 2))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let image = try XCTUnwrap(context.makeImage())

        let data = try PngQuantizer.encode(image, colors: 64, dpi: (x: 144, y: 144))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyDPIWidth] as? Double, 144)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        // Read back alpha: opaque stays opaque, the fade survives
        let check = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        check.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(check.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        let row = (height / 2) * width * 4
        XCTAssertEqual(pixels[row + 10 * 4 + 3], 255)
        let fadeMid = Int(pixels[row + (width * 3 / 4) * 4 + 3])
        XCTAssertEqual(Double(fadeMid), 127, accuracy: 24)
        XCTAssertLessThan(Int(pixels[row + (width - 1) * 4 + 3]), 24)
    }

    func testPNGAndTIFFShrinkLosslessOrWithPalette() async throws {
        let png = try writeSample(named: "shot.png", type: .png, quality: 1.0)
        let tiff = try writeSample(named: "scan.tiff", type: .tiff, quality: 1.0)
        let result = try await withPreset("Web Optimized") {
            try await QuickActionConversionService().compress(urls: [png, tiff])
        }
        XCTAssertEqual(Set(result.successes.map(\.outputURL.lastPathComponent)), ["shot compressed.png", "scan compressed.tiff"])
    }

    func testAnimatedGIFKeepsEveryFrameAndShrinks() async throws {
        // 12 noisy frames with mixed delays, looping forever
        let url = directory.appending(path: "anim.gif")
        let base = try XCTUnwrap(QualityPreviewRenderer.sample())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 12, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<12 {
            let context = try XCTUnwrap(CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(base, in: CGRect(x: frame * 4, y: 0, width: base.width, height: base.height))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.isMultiple(of: 2) ? 0.1 : 0.3]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let estimate = await Compression.estimate(url: url, type: .gif, preset: PreferencesManager.shared.presetSettings(named: "Thumbnail"), allowProbe: false)
        let result = try await withPreset("Thumbnail") { try await QuickActionConversionService().compress(urls: [url]) }
        let output = try XCTUnwrap(result.successes.first?.outputURL)
        XCTAssertEqual(output.lastPathComponent, "anim compressed.gif")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 12)
        let frame1 = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any])
        let gif = try XCTUnwrap(frame1[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFDelayTime] as? Double), 0.3, accuracy: 0.01)
        XCTAssertEqual(frame1[kCGImagePropertyPixelWidth] as? Int, base.width / 4)
        let after = Double(try XCTUnwrap(Compression.fileSize(output)))
        XCTAssertLessThan(after, Double(try XCTUnwrap(Compression.fileSize(url))))
        XCTAssertEqual(Double(try XCTUnwrap(estimate)), after, accuracy: after * 0.25)
    }

    // Two seconds of a stereo tone in the given file format
    private func writeTone(named name: String, settings: [String: Any]) throws -> URL {
        let url = directory.appending(path: name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
        buffer.frameLength = 88200
        for channel in 0..<2 {
            for frame in 0..<88200 {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44100) * 0.5)
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testPodcastPresetMakesWAVMono() async throws {
        let wav = try writeTone(named: "voice.wav", settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
        ])
        let result = try await withPreset("Podcast") { try await QuickActionConversionService().compress(urls: [wav]) }
        let output = try XCTUnwrap(result.successes.first?.outputURL)
        let format = try AVAudioFile(forReading: output).fileFormat
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.sampleRate, 22050)
    }

    func testM4AUsesTheBitrateSetting() async throws {
        let m4a = try writeTone(named: "song.m4a", settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256000,
        ])
        let result = try await withPreset("Podcast") { try await QuickActionConversionService().compress(urls: [m4a]) }
        let output = try XCTUnwrap(result.successes.first?.outputURL, "64 kbps re-encode of a 256 kbps file should be smaller")
        XCTAssertLessThan(try XCTUnwrap(Compression.fileSize(output)), try XCTUnwrap(Compression.fileSize(m4a)) / 2)
    }

    func testMenuEstimateCoversCurrentSettingsAndPresets() async throws {
        let source = try writeSample(named: "photo.jpg", type: .jpeg, quality: 1.0)
        let computed = await CompressionEstimate.compute(urls: [source], presetNames: ["Email Friendly"])
        let estimate = try XCTUnwrap(computed)

        XCTAssertEqual(estimate.sourceBytes, Compression.fileSize(source))
        let current = try XCTUnwrap(estimate.estimates[""])
        let email = try XCTUnwrap(estimate.estimates["Email Friendly"])
        XCTAssertLessThanOrEqual(current, estimate.sourceBytes)
        XCTAssertLessThan(email, current)
    }

    // Two pages, each a lossless 2000x1500 noisy photo (~400 dpi on the page)
    // under a line of real text, like a phone scan with an OCR layer
    private func writePhotoPDF(named name: String) throws -> URL {
        let url = directory.appending(path: name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let base = try XCTUnwrap(QualityPreviewRenderer.sample())
        for page in 1...2 {
            let photo = try XCTUnwrap(CGContext(data: nil, width: 2000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            photo.draw(base, in: CGRect(x: 0, y: 0, width: 2000, height: 1500))
            let pixels = try XCTUnwrap(photo.data).assumingMemoryBound(to: UInt8.self)
            var seed = UInt32(page)
            for i in stride(from: 0, to: 2000 * 1500 * 4, by: 4) {
                seed = seed &* 1664525 &+ 1013904223
                pixels[i] &+= UInt8(seed >> 28)
            }
            pdf.beginPDFPage(nil)
            pdf.draw(try XCTUnwrap(photo.makeImage()), in: CGRect(x: 36, y: 300, width: 540, height: 405))
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            ("Searchable page \(page)" as NSString).draw(at: CGPoint(x: 36, y: 250), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return url
    }

    func testPDFCompressionShrinksImagesAndKeepsText() async throws {
        let source = try writePhotoPDF(named: "scan.pdf")
        let estimate = await Compression.estimate(url: source, type: .pdf, preset: nil, allowProbe: false)
        let result = try await QuickActionConversionService().compress(urls: [source])

        let output = try XCTUnwrap(result.successes.first?.outputURL)
        XCTAssertEqual(output.lastPathComponent, "scan compressed.pdf")
        let before = try XCTUnwrap(Compression.fileSize(source)), after = try XCTUnwrap(Compression.fileSize(output))
        XCTAssertLessThan(after, before / 4)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(try XCTUnwrap(document.string).contains("Searchable page 2"))
        // The estimate is the same in-memory write, so it should land close
        XCTAssertEqual(Double(try XCTUnwrap(estimate)), Double(after), accuracy: Double(after) * 0.05)
    }

    func testPasswordProtectedPDFIsNotCompressed() async throws {
        let plain = try writePhotoPDF(named: "plain.pdf")
        let locked = directory.appending(path: "locked.pdf")
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: plain)).write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))

        let result = try await QuickActionConversionService().compress(urls: [locked])
        XCTAssertTrue(result.successes.isEmpty)
        XCTAssertEqual(result.failures.map(\.sourceURL), [locked])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "locked compressed.pdf").path))
    }

    // A sample tagged with GPS, a lens name and a comment, rotated 90 degrees
    private func writeTaggedSample(named name: String, type: UTType) throws -> URL {
        let url = directory.appending(path: name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(QualityPreviewRenderer.sample()), [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.97, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "SECRETLENS", kCGImagePropertyExifUserComment: "SECRETNOTE"],
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "SECRETNOTE"],
            kCGImagePropertyOrientation: 6,
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixels(of url: URL) throws -> Data {
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    func testRemoveMetadataKeepsPixelsAndOrientation() throws {
        let jpeg = try writeTaggedSample(named: "photo.jpg", type: .jpeg)
        let png = try writeTaggedSample(named: "shot.png", type: .png)
        let text = directory.appending(path: "notes.txt")
        try "x".write(to: text, atomically: true, encoding: .utf8)

        let result = try QuickActionConversionService().removeMetadata(urls: [jpeg, png, text])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.successes.map(\.outputURL.lastPathComponent).sorted(), ["photo clean.jpg", "shot clean.png"])

        for (source, output) in zip([jpeg, png], result.successes.map(\.outputURL)) {
            let bytes = try Data(contentsOf: output)
            XCTAssertNil(bytes.range(of: Data("SECRETLENS".utf8)), output.lastPathComponent)
            XCTAssertNil(bytes.range(of: Data("SECRETNOTE".utf8)), output.lastPathComponent)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil)), 0, nil) as? [CFString: Any])
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary], output.lastPathComponent)
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6, output.lastPathComponent)
            XCTAssertEqual(try pixels(of: output), try pixels(of: source), output.lastPathComponent)
        }
    }

    func testRemoveMetadataRejectsTruncatedPNG() throws {
        let png = try writeTaggedSample(named: "shot.png", type: .png)
        let data = try Data(contentsOf: png)
        try data.prefix(data.count / 2).write(to: png)
        let result = try QuickActionConversionService().removeMetadata(urls: [png])
        XCTAssertEqual(result.failures.map(\.sourceURL), [png])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "shot clean.png").path))
    }

    func testWatchedFolderPicksOnlyNewCompressibleFiles() throws {
        let photo = try writeSample(named: "Screenshot 1.png", type: .png, quality: 1)
        let folder = WatchedFolder(path: directory.path)
        XCTAssertTrue(folder.shouldCompress(photo))

        let output = directory.appending(path: "Screenshot 1 compressed.png")
        let secondOutput = directory.appending(path: "Screenshot 1 compressed 2.png")
        let hidden = directory.appending(path: ".Screenshot 2.png")
        let text = directory.appending(path: "notes.txt")
        let nested = directory.appending(path: "sub/inner.png")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in [output, secondOutput, hidden, nested] { try FileManager.default.copyItem(at: photo, to: url) }
        try "x".write(to: text, atomically: true, encoding: .utf8)
        for url in [output, secondOutput, hidden, text, nested, directory.appending(path: "gone.png")] {
            XCTAssertFalse(folder.shouldCompress(url), url.lastPathComponent)
        }

        // The list survives a round trip through settings JSON
        let decoded = try JSONDecoder().decode([WatchedFolder].self, from: JSONEncoder().encode([folder, WatchedFolder(path: "/tmp", presetName: "Web Optimized")]))
        XCTAssertEqual(decoded[1].presetName, "Web Optimized")
        XCTAssertEqual(decoded[0], folder)
    }
}
