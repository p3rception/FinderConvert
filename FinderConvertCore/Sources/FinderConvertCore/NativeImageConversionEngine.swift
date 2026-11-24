import AppKit
import CoreGraphics
import CWebP
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

public actor NativeImageConversionEngine: ConversionEngine {
    public let identifier = "com.finderconvert.engine.image.native"

    private let logger = Logger(subsystem: "FinderConvert", category: "image-engine")
    private let naming = OutputNamingStrategy()

    public init() {}

    private static let supportedInputs: Set<DetectedFileType> = [.jpeg, .png, .heic, .tiff, .gif, .webp, .bmp, .avif]
    private static let supportedOutputs: Set<OutputFormat> = [.jpeg, .png, .heic, .tiff, .gif, .bmp, .ico, .avif, .webp]

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

        if isStale {
            logger.notice("Source bookmark was stale and still resolved.")
        }

        return try SecurityScopedAccess(url: sourceURL).perform {
            progress(0.05)
            let inputType = try FileTypeDetector().detect(url: sourceURL).detectedType
            guard supports(input: inputType, output: job.requestedOutput) else {
                logger.error("FinderConvert Engine: Unsupported conversion from \(inputType.rawValue, privacy: .public) to \(job.requestedOutput.rawValue, privacy: .public)")
                throw ConversionError.unsupportedOutput(job.requestedOutput)
            }

            logger.info("FinderConvert Engine: Resolving source URL: \(sourceURL.path(percentEncoded: false), privacy: .public)")
            let sourceData: Data
            do {
                sourceData = try Data(contentsOf: sourceURL)
                logger.info("FinderConvert Engine: Successfully read data. Size: \(sourceData.count, privacy: .public) bytes.")
            } catch {
                logger.error("FinderConvert Engine: Failed to read data from \(sourceURL.path(percentEncoded: false), privacy: .public). Error: \(error.localizedDescription, privacy: .public)")
                throw error
            }

            guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
                logger.error("FinderConvert Engine: CGImageSourceCreateWithData returned nil.")
                throw ConversionError.failedToDecodeImage
            }
            logger.info("FinderConvert Engine: CGImageSourceCreateWithData succeeded.")

            guard var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                logger.error("FinderConvert Engine: CGImageSourceCreateImageAtIndex returned nil for index 0.")
                throw ConversionError.failedToDecodeImage
            }

            // Apply per-format resize and longest-edge cap if configured
            // (except ICO, which is always rendered at the fixed 256x256
            // icon size)
            let prefs = PreferencesManager.shared
            if job.requestedOutput != .ico {
                var scale = 1.0
                let resizePercent = prefs.resizePercent(for: job.requestedOutput)
                if resizePercent > 0 && resizePercent < 100 {
                    scale = Double(resizePercent) / 100.0
                }
                let maxEdge = prefs.maxLongestEdge(for: job.requestedOutput)
                let longest = Double(max(image.width, image.height)) * scale
                if maxEdge > 0, longest > Double(maxEdge) {
                    scale *= Double(maxEdge) / longest
                }
                if scale < 1, let resized = Self.scaled(image, by: scale) {
                    image = resized
                    logger.info("Resized image to \(resized.width)x\(resized.height)")
                }
            }

            progress(0.35)

            let destinationURL = try naming.destinationURL(
                for: sourceURL,
                outputFormat: job.requestedOutput,
                policy: job.destinationPolicy
            )

            let tempURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .notDirectory)
                .appendingPathExtension(job.requestedOutput.preferredExtension)

            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }

            let format = job.requestedOutput
            let metadata = metadataProperties(from: source, for: format)
            let quality = prefs.quality(for: format)
            var data = try encode(image, format: format, quality: quality, metadata: metadata)

            // Size cap: lower the quality first, then the dimensions
            let maxBytes = prefs.maxOutputBytes
            if maxBytes > 0, data.count > Int(maxBytes), format != .ico {
                data = try fit(image, format: format, startQuality: quality, metadata: metadata, under: Int(maxBytes))
                logger.info("Size cap \(maxBytes) B: output is \(data.count) B")
            }
            try data.write(to: tempURL)

            progress(0.85)
            try validateOutputExists(at: tempURL)
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            progress(1.0)
            return ConversionResult(sourceURL: sourceURL, outputURL: destinationURL, outputFormat: job.requestedOutput)
        }
    }

    public func cancel(jobID: UUID) async {}

    private func metadataProperties(from source: CGImageSource, for format: OutputFormat) -> [CFString: Any] {
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        // Stripping removes camera, GPS and EXIF data but keeps what decides
        // how the image displays: without DPI a Retina screenshot opens at
        // double size, without orientation a phone photo turns sideways
        if PreferencesManager.shared.stripMetadata(for: format) {
            return properties.filter { [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight, kCGImagePropertyOrientation].contains($0.key) }
        }
        return properties
    }

    // Encode in memory with the format's own rules (flattening, the fixed
    // ICO canvas, the WebP library) so the result can be measured before it
    // is written
    func encode(_ image: CGImage, format: OutputFormat, quality: Double, metadata: [CFString: Any]) throws -> Data {
        switch format {
        case .png:
            if let colors = PngQuantizer.colorCount(forQuality: quality) {
                let dpi = (metadata[kCGImagePropertyDPIWidth] as? Double).map { x in (x: x, y: metadata[kCGImagePropertyDPIHeight] as? Double ?? x) }
                return try PngQuantizer.encode(image, colors: colors, dpi: dpi)
            }
            return try encodeImageIO(image, utType: .png, format: format, properties: metadata)
        case .jpeg:
            return try encodeImageIO(try flattenIfNeeded(image), utType: .jpeg, format: format,
                                     properties: metadata.merging([kCGImageDestinationLossyCompressionQuality: quality]) { _, new in new })
        case .heic:
            return try encodeImageIO(image, utType: UTType("public.heic") ?? .image, format: format,
                                     properties: metadata.merging([kCGImageDestinationLossyCompressionQuality: quality]) { _, new in new })
        case .avif:
            return try encodeImageIO(image, utType: UTType("public.avif") ?? .image, format: format,
                                     properties: metadata.merging([kCGImageDestinationLossyCompressionQuality: quality]) { _, new in new })
        case .tiff:
            // LZW: lossless and readable everywhere, often half the size
            var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5
            return try encodeImageIO(image, utType: .tiff, format: format,
                                     properties: metadata.merging([kCGImagePropertyTIFFDictionary: tiff]) { _, new in new })
        case .gif:
            return try encodeImageIO(image, utType: .gif, format: format, properties: metadata)
        case .bmp:
            return try encodeImageIO(try flattenIfNeeded(image), utType: .bmp, format: format, properties: metadata)
        case .ico:
            // ImageIO's ICO encoder only accepts standard icon sizes, so
            // render onto an exact 256x256 square canvas (aspect-fit)
            let squared = try squareCanvas(image, size: 256)
            return try encodeImageIO(try flattenIfNeeded(squared), utType: UTType("com.microsoft.ico") ?? .image, format: format, properties: metadata)
        case .webp:
            return try Self.encodeWebP(image, quality: Float(quality * 100))
        default:
            throw ConversionError.unsupportedOutput(format)
        }
    }

    private func encodeImageIO(_ image: CGImage, utType: UTType, format: OutputFormat, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil) else {
            throw ConversionError.failedToEncodeImage(format)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.failedToEncodeImage(format)
        }
        return data as Data
    }

    // Shrinks an encode under a byte budget. Lossy formats binary-search the
    // quality down to 25% first; when that is not enough (or the format is
    // lossless) the dimensions come down in steps. Returns the best effort
    // if even a tiny image will not fit
    func fit(_ image: CGImage, format: OutputFormat, startQuality: Double, metadata: [CFString: Any], under maxBytes: Int) throws -> Data {
        var current = image
        var best: Data?
        for _ in 0..<6 {
            if format.supportsQuality {
                var low = 0.25, high = startQuality
                var fitting: Data?
                var largest = try encode(current, format: format, quality: low, metadata: metadata)
                if largest.count <= maxBytes {
                    fitting = largest
                    for _ in 0..<6 {
                        let mid = (low + high) / 2
                        let candidate = try encode(current, format: format, quality: mid, metadata: metadata)
                        if candidate.count <= maxBytes { fitting = candidate; low = mid } else { high = mid }
                    }
                    return fitting ?? largest
                }
                best = largest
            } else {
                let candidate = try encode(current, format: format, quality: startQuality, metadata: metadata)
                if candidate.count <= maxBytes { return candidate }
                best = candidate
            }
            // Still too big: scale the area down by the overshoot, with margin
            let ratio = min(0.9, (Double(maxBytes) / Double(best?.count ?? maxBytes)).squareRoot() * 0.92)
            guard current.width > 64, current.height > 64, let smaller = Self.scaled(current, by: ratio) else { break }
            current = smaller
        }
        if let best { return best }
        return try encode(current, format: format, quality: startQuality, metadata: metadata)
    }

    static func scaled(_ image: CGImage, by scale: Double) -> CGImage? {
        let newW = max(1, Int((Double(image.width) * scale).rounded()))
        let newH = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: newW, height: newH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.rgbColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    private func flattenIfNeeded(_ image: CGImage) throws -> CGImage {
        if image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst || image.alphaInfo == .noneSkipLast {
            return image
        }

        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ConversionError.failedToEncodeImage(.jpeg)
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard let flattened = context.makeImage() else {
            throw ConversionError.failedToEncodeImage(.jpeg)
        }

        return flattened
    }

    // Aspect-fit the image centered on a fixed square canvas
    private func squareCanvas(_ image: CGImage, size: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.rgbColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.failedToEncodeImage(.ico)
        }
        context.interpolationQuality = .high
        let scale = min(Double(size) / Double(image.width), Double(size) / Double(image.height))
        let w = Double(image.width) * scale
        let h = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(size) - w) / 2, y: (Double(size) - h) / 2, width: w, height: h))
        guard let squared = context.makeImage() else {
            throw ConversionError.failedToEncodeImage(.ico)
        }
        return squared
    }

    static func encodeWebP(_ image: CGImage, quality: Float) throws -> Data {
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: image.rgbColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ConversionError.failedToEncodeImage(.webp)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw ConversionError.failedToEncodeImage(.webp) }

        // Bitmap contexts only hold premultiplied alpha; libwebp wants straight alpha
        let rgbData = data.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = Int(rgbData[i + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in i..<i + 3 {
                rgbData[channel] = UInt8(min(255, (Int(rgbData[channel]) * 255 + alpha / 2) / alpha))
            }
        }
        var output: UnsafeMutablePointer<UInt8>?
        let size = WebPEncodeRGBA(rgbData, Int32(width), Int32(height), Int32(width * 4), quality, &output)
        guard size > 0, let outputPtr = output else { throw ConversionError.failedToEncodeImage(.webp) }
        defer { WebPFree(outputPtr) }

        return Data(bytes: outputPtr, count: Int(size))
    }

    private func validateOutputExists(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw ConversionError.invalidDestination
        }
    }
}

// Lossless metadata removal: the image data is copied byte for byte and
// only GPS, camera, EXIF, XMP and text metadata go. Orientation and
// resolution stay, so photos don't turn sideways and screenshots keep
// their size. ImageIO does this reliably only for JPEG (it leaves EXIF in
// PNG, HEIC and TIFF), so PNG is handled by filtering its chunks
public enum MetadataRemoval {
    public static let outputSuffix = " clean"

    public static func supports(_ type: DetectedFileType) -> Bool {
        type == .jpeg || type == .png
    }

    public static func removeMetadata(from source: URL, to destination: URL, type: DetectedFileType) throws {
        switch type {
        case .jpeg: try copyJPEGWithoutMetadata(from: source, to: destination)
        case .png: try copyPNGWithoutMetadata(from: source, to: destination)
        default: throw ConversionError.unsupportedFileType(type.rawValue)
        }
    }

    private static let keptTags: Set<String> = ["tiff:Orientation", "tiff:XResolution", "tiff:YResolution", "tiff:ResolutionUnit"]

    static func copyJPEGWithoutMetadata(from source: URL, to destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.failedToDecodeImage
        }
        // Merging null values deletes those tags; everything not listed is kept
        let removals = CGImageMetadataCreateMutable()
        let existing = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil)
        for tag in (existing.flatMap { CGImageMetadataCopyTags($0) as? [CGImageMetadataTag] }) ?? [] {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) else { continue }
            let path = "\(prefix):\(name)"
            if !keptTags.contains(path) {
                CGImageMetadataSetValueWithPath(removals, nil, path as CFString, kCFNull)
            }
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: removals,
            kCGImageDestinationMergeMetadata: true,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(output, imageSource, options as CFDictionary, &error) else {
            throw ConversionError.filesystemError(error?.takeRetainedValue().localizedDescription ?? "Could not rewrite the JPEG.")
        }
    }

    // PNG is a signature plus length/type/data/CRC chunks. Text, EXIF and
    // timestamp chunks are dropped; pixel (IDAT), colour (iCCP, sRGB, gAMA)
    // and resolution (pHYs) chunks are copied unchanged. Orientation lives
    // in eXIf, so a rotated PNG gets back an eXIf holding only that
    private static let droppedChunks: Set<String> = ["eXIf", "tEXt", "zTXt", "iTXt", "tIME"]

    static func copyPNGWithoutMetadata(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        let orientation = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyOrientation] as? Int ?? 1
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard data.starts(with: signature) else { throw ConversionError.failedToDecodeImage }

        var output = signature
        var offset = data.startIndex + signature.count
        var sawEnd = false
        while offset + 12 <= data.endIndex {
            let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let chunkEnd = offset + 12 + length
            guard length <= 0x7FFF_FFFF, chunkEnd <= data.endIndex else { throw ConversionError.failedToDecodeImage }
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            if !droppedChunks.contains(type) {
                output.append(data[offset..<chunkEnd])
            }
            if type == "IHDR", (2...8).contains(orientation) {
                // Big-endian TIFF header, one IFD entry: Orientation (0x0112), SHORT, 1 value
                var exif = Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x01, 0x01, 0x12, 0x00, 0x03])
                exif.appendBigEndian(1)
                exif.append(contentsOf: [0x00, UInt8(orientation), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                output.appendChunk("eXIf", exif)
            }
            offset = chunkEnd
            if type == "IEND" { sawEnd = true; break }
        }
        guard sawEnd else { throw ConversionError.failedToDecodeImage }
        try output.write(to: destination)
    }
}

extension CGImage {
    // 8-bit RGBA bitmap contexts reject gray and CMYK spaces. RGB spaces
    // (Display P3, Adobe RGB) are kept so wide-gamut sources stay wide
    var rgbColorSpace: CGColorSpace {
        if let colorSpace, colorSpace.model == .rgb { return colorSpace }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}
