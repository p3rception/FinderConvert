import AVFoundation
import CoreGraphics
import ImageIO
import PDFKit
import XCTest
@testable import FinderConvertCore

// Pushes the bundled sample picture through every encoder path, so an
// encoder setting that a future macOS rejects fails here, not on a user's
// first conversion
final class EncoderTests: XCTestCase {
    private var sample: CGImage {
        get throws { try XCTUnwrap(QualityPreviewRenderer.sample()) }
    }

    // A one-second H.264 movie built from the sample, for transcoder tests
    private func makeMovie(seconds: Double = 1.0, withAudio: Bool = false) async throws -> URL {
        let image = try sample
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: image.width, AVVideoHeightKey: image.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: image.width, kCVPixelBufferHeightKey as String: image.height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer), width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        // Pan across the picture so every frame carries real motion; a
        // static clip is one keyframe and says nothing about rate control
        let frames = Int(seconds * 30)
        for frame in 0..<frames {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let shift = (frame * 6) % image.width
            context.draw(image, in: CGRect(x: -shift, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: image.width - shift, y: 0, width: image.width, height: image.height))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }

    private func frameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        // Passthrough readers also hand out empty marker buffers, so count
        // samples rather than buffers
        var count = 0
        while let buffer = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(buffer) }
        return count
    }

    func testEveryVideoLevelEncodesInBothRateModes() async throws {
        let source = try await makeMovie()
        defer { try? FileManager.default.removeItem(at: source) }
        for format in [OutputFormat.mp4, .mov, .hevc] {
            for preset in ["highest", "high", "medium", "low"] {
                let codec: AVVideoCodecType = format == .hevc ? .hevc : .h264
                let bitRate = VideoRateModel.targetBitRate(preset: preset, width: 640, height: 400, frameRate: 30, codec: codec)
                for mode in [VideoRateMode.constantQuality(VideoRateModel.encoderQuality(for: preset)), .averageBitRate(bitRate)] {
                    if case .constantQuality = mode,
                       !VideoRateModel.supportsConstantQuality(codec: codec, width: 640, height: 400) { continue }
                    let destination = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(format.preferredExtension)")
                    defer { try? FileManager.default.removeItem(at: destination) }
                    let result = try await VideoTranscoder().run(
                        sourceURL: source, destination: destination,
                        options: VideoTranscoder.Options(format: format, preset: preset, rateMode: mode)
                    )
                    XCTAssertGreaterThan(result.bytes, 1_000, "\(format) \(preset) \(mode)")
                    XCTAssertEqual(result.rateMode, mode)
                    let frames = try await frameCount(destination)
                    XCTAssertEqual(frames, 30, "\(format) \(preset) \(mode) dropped frames")
                }
            }
        }
    }

    func testTimeRangeSliceEncodesOnlyThatSlice() async throws {
        let source = try await makeMovie(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let sourceFrames = try await frameCount(source)
        XCTAssertEqual(sourceFrames, 60, "fixture frame count")
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600))
        try await VideoTranscoder().run(sourceURL: source, destination: destination,
                                        options: VideoTranscoder.Options(format: .mp4, preset: "medium", timeRange: range))
        let frames = try await frameCount(destination)
        XCTAssertEqual(frames, 30)
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: destination).load(.duration))
        XCTAssertEqual(duration, 1.0, accuracy: 0.05)
    }

    func testSizeProbeProjectsWholeClip() async throws {
        let source = try await makeMovie(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let projected = try await VideoSizeProbe.projectedBytes(sourceURL: source, format: .mp4, preset: "medium")
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        let actual = try await VideoTranscoder().run(sourceURL: source, destination: destination,
                                                     options: VideoTranscoder.Options(format: .mp4, preset: "medium"))
        // Static footage with keyframe-heavy slices: within a factor of two
        // is what the probe promises, real footage lands within a few percent
        XCTAssertGreaterThan(projected, actual.bytes / 2)
        XCTAssertLessThan(projected, actual.bytes * 2)
    }

    func testFittingBitRateLandsUnderBudget() async throws {
        let source = try await makeMovie(seconds: 4)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        let full = try await VideoTranscoder().run(sourceURL: source, destination: destination,
                                                   options: VideoTranscoder.Options(format: .mp4, preset: "highest"))
        try? FileManager.default.removeItem(at: destination)
        let budget = full.bytes / 2
        let bitRate = VideoRateModel.bitRate(fitting: budget, duration: 4, audioBitRate: 0)
        let result = try await VideoTranscoder().run(fittingUnder: budget, sourceURL: source, destination: destination,
                                                     options: VideoTranscoder.Options(format: .mp4, preset: "high", rateMode: .averageBitRate(bitRate)))
        XCTAssertLessThanOrEqual(result.bytes, budget)
        XCTAssertGreaterThan(result.bytes, budget / 2, "should land near the budget, not far under it")
    }

    func testQualityPreviewRendersEveryLossyFormat() async throws {
        for format in [OutputFormat.jpeg, .heic, .avif, .webp, .mp4, .mov, .hevc] {
            let preview = try await QualityPreviewRenderer.render(format: format, quality: 0.5, videoPreset: "medium")
            XCTAssertEqual(preview.encoded.width, preview.original.width, "\(format)")
            XCTAssertEqual(preview.encoded.height, preview.original.height, "\(format)")
            if format.supportsQuality {
                XCTAssertGreaterThan(preview.encodedBytes, 0, "\(format)")
            }
        }
    }

    func testImageFitHoldsEveryFormatUnderBudget() async throws {
        let image = try sample
        let engine = NativeImageConversionEngine()
        for format in [OutputFormat.jpeg, .heic, .avif, .webp, .png, .gif, .bmp, .tiff] {
            let full = try await engine.encode(image, format: format, quality: 0.9, metadata: [:])
            let budget = max(4_000, full.count / 4)
            let fitted = try await engine.fit(image, format: format, startQuality: 0.9, metadata: [:], under: budget)
            XCTAssertLessThanOrEqual(fitted.count, budget, "\(format) \(fitted.count) > \(budget)")
        }
    }

    func testPresetJSONWithoutNewFieldsStillDecodes() throws {
        let legacy = Data(#"{"jpegQuality":0.7,"resizePercent":50}"#.utf8)
        let preset = try JSONDecoder().decode(PresetSettings.self, from: legacy)
        XCTAssertEqual(preset.resizePercent, 50)
        XCTAssertNil(preset.maxLongestEdge)
    }

    func testWebPKeepsTransparency() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        let webp = try NativeImageConversionEngine.encodeWebP(try XCTUnwrap(context.makeImage()), quality: 90)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(webp as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        context.clear(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Row-major from the top: pixel 0 is in the half-transparent red half, pixel 7 in the clear half
        XCTAssertEqual(Double(pixels[3]), 128, accuracy: 8, "half-transparent alpha")
        XCTAssertEqual(Double(pixels[0]), 128, accuracy: 8, "premultiplied red survives")
        XCTAssertEqual(pixels[7 * 4 + 3], 0, "clear pixel stays clear")
    }

    func testWebPEncodesGrayscaleSource() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        XCTAssertFalse(try NativeImageConversionEngine.encodeWebP(try XCTUnwrap(context.makeImage()), quality: 90).isEmpty)
    }

    private func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, tool)
    }

    private func convert(_ url: URL, to output: OutputFormat, with engine: some ConversionEngine) async throws -> URL {
        let job = ConversionJob(sourceBookmarkData: try url.bookmarkData(), requestedOutput: output,
                                destinationPolicy: .neverReplace(customSuffix: nil))
        return try await engine.convert(job: job) { _ in }.outputURL
    }

    func testDOCXConvertsToText() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appending(path: "note.txt")
        try "Hello from DOCX".write(to: text, atomically: true, encoding: .utf8)
        let docx = directory.appending(path: "note.docx")
        try run("/usr/bin/textutil", ["-convert", "docx", text.path, "-output", docx.path])

        let output = try await convert(docx, to: .html, with: DocumentConversionEngine())
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("Hello from DOCX"))
    }

    // A zipped EPUB whose spine lists `chapters` (manifest hrefs) in order.
    // `files` are written into the book, `symlinks` map a book path to a target
    private func makeEPUB(in directory: URL, chapters: [String], files: [String: String],
                          symlinks: [String: URL] = [:]) throws -> URL {
        let book = directory.appending(path: "book")
        try FileManager.default.createDirectory(at: book.appending(path: "META-INF"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: book.appending(path: "mimetype"), atomically: true, encoding: .utf8)
        try #"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>"#
            .write(to: book.appending(path: "META-INF/container.xml"), atomically: true, encoding: .utf8)
        let items = chapters.enumerated().map { #"<item id="c\#($0.offset)" href="\#($0.element)"/>"# }.joined()
        let refs = chapters.indices.map { #"<itemref idref="c\#($0)"/>"# }.joined()
        try #"<package xmlns="http://www.idpf.org/2007/opf"><manifest>\#(items)</manifest><spine>\#(refs)</spine></package>"#
            .write(to: book.appending(path: "content.opf"), atomically: true, encoding: .utf8)
        for (name, content) in files {
            try content.write(to: book.appending(path: name), atomically: true, encoding: .utf8)
        }
        for (name, target) in symlinks {
            try FileManager.default.createSymbolicLink(at: book.appending(path: name), withDestinationURL: target)
        }
        let epub = directory.appending(path: "book.epub")
        try run("/usr/bin/zip", ["-qry", epub.path, "."], in: book)
        return epub
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testEPUBToPDFPaginates() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paragraphs = String(repeating: "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>", count: 400)
        let epub = try makeEPUB(in: directory, chapters: ["c1.xhtml"], files: ["c1.xhtml": "<html><body>\(paragraphs)</body></html>"])

        let output = try await convert(epub, to: .pdf, with: EpubConversionEngine())
        XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(url: output)).pageCount, 1)
    }

    func testEPUBReadsNothingOutsideTheBook() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = directory.appending(path: "secret.xhtml")
        try "<html><body>SECRET-VALUE</body></html>".write(to: secret, atomically: true, encoding: .utf8)
        let traversal = String(repeating: "../", count: 30) + secret.path.dropFirst()
        let epub = try makeEPUB(
            in: directory,
            chapters: ["c1.xhtml", traversal, "linked.xhtml"],
            files: ["c1.xhtml": "<html><body>LEGIT-CHAPTER</body></html>"],
            symlinks: ["linked.xhtml": secret]
        )

        let html = try String(contentsOf: try await convert(epub, to: .html, with: EpubConversionEngine()), encoding: .utf8)
        XCTAssertTrue(html.contains("LEGIT-CHAPTER"))
        XCTAssertFalse(html.contains("SECRET-VALUE"))
    }

    func testHTMLToPDFRunsNoScriptsAndStaysOnTheDocument() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "SECRET-VALUE".write(to: directory.appending(path: "secret.txt"), atomically: true, encoding: .utf8)
        let page = directory.appending(path: "page.html")
        try """
        <html><head><meta http-equiv="refresh" content="0;url=secret.txt"></head><body>
        <p>VISIBLE-TEXT</p><iframe src="secret.txt"></iframe>
        <script>document.body.insertAdjacentHTML('beforeend', '<p>SCRIPT-RAN</p>')</script>
        </body></html>
        """.write(to: page, atomically: true, encoding: .utf8)

        let output = try await convert(page, to: .pdf, with: DocumentConversionEngine())
        let text = try XCTUnwrap(PDFDocument(url: output)?.string)
        XCTAssertTrue(text.contains("VISIBLE-TEXT"))
        XCTAssertFalse(text.contains("SCRIPT-RAN"))
        XCTAssertFalse(text.contains("SECRET-VALUE"))
    }

    func testUpdateMustMatchTheInstalledSigner() async throws {
        let installer = UpdateInstaller()
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try await installer.verifySignature(of: calculator, matches: calculator)
        do {
            try await installer.verifySignature(of: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), matches: calculator)
            XCTFail("a different app passed the signature check")
        } catch UpdateInstallError.signatureMismatch {}
    }

    func testXLSXKeepsTextThatOnlyLooksNumeric() async throws {
        for (value, isNumber) in [("4.5", true), ("-12", true), ("1e5", true), ("0", true), ("00123", false),
                                  ("nan", false), ("inf", false), ("0x1p3", false), ("+5", false), ("1234567890123456", false)] {
            XCTAssertEqual(SpreadsheetConversionEngine.isPlainNumber(value), isNumber, value)
        }

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let csv = directory.appending(path: "table.csv")
        try "zip,price,note\n00123,4.5,a\u{01}b\n".write(to: csv, atomically: true, encoding: .utf8)
        let xlsx = try await convert(csv, to: .xlsx, with: SpreadsheetConversionEngine())
        try run("/usr/bin/unzip", ["-q", xlsx.path, "-d", directory.appending(path: "x").path])
        let sheet = try Data(contentsOf: directory.appending(path: "x/xl/worksheets/sheet1.xml"))
        XCTAssertNoThrow(try XMLDocument(data: sheet), "sheet must be well-formed XML")
        let xml = String(decoding: sheet, as: UTF8.self)
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">00123</t>"))
        XCTAssertTrue(xml.contains("<v>4.5</v>"))
        XCTAssertTrue(xml.contains(">ab</t>"))
    }
}
