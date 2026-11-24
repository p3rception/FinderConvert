import AppKit
import Foundation
import OSLog
import PDFKit
import UniformTypeIdentifiers
import WebKit

public actor EpubConversionEngine: ConversionEngine {
    public let identifier = "com.finderconvert.engine.epub"
    private let logger = Logger(subsystem: "FinderConvert", category: "epub-engine")
    private let naming = OutputNamingStrategy()

    public init() {}

    public nonisolated func supports(input: DetectedFileType, output: OutputFormat) -> Bool {
        guard input == .epub else { return false }
        switch output {
        case .pdf, .txt, .html:
            return true
        default:
            return false
        }
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
        progress(0.1)

        let destinationURL = try naming.destinationURL(
            for: sourceURL,
            outputFormat: job.requestedOutput,
            policy: job.destinationPolicy
        )

        // EPUB is a ZIP of XHTML files
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Unzip EPUB
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", sourceURL.path, "-d", tempDir.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()

        guard unzip.terminationStatus == 0 else {
            throw ConversionError.filesystemError("Could not extract EPUB file.")
        }

        progress(0.3)

        // Find content files by parsing container.xml
        let contentFiles = try findContentFiles(in: tempDir).compactMap { Self.resolved($0, inside: tempDir) }
        guard !contentFiles.isEmpty else {
            throw ConversionError.filesystemError("No content found in EPUB.")
        }

        progress(0.4)

        // Combine all XHTML/HTML content
        var combinedHTML = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        body { font-family: -apple-system, Georgia, serif; max-width: 700px; margin: 40px auto; padding: 0 20px; line-height: 1.8; color: #333; }
        h1, h2, h3 { margin-top: 1.5em; }
        img { max-width: 100%; }
        .chapter-break { page-break-before: always; border-top: 1px solid #ddd; margin-top: 3em; padding-top: 2em; }
        </style></head><body>
        """

        for (i, file) in contentFiles.enumerated() {
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                // Extract body content from XHTML
                var body = extractBody(from: content)
                if job.requestedOutput != .txt {
                    body = Self.inlineImages(in: body, chapter: file, book: tempDir)
                }
                if i > 0 { combinedHTML += "<div class=\"chapter-break\"></div>\n" }
                combinedHTML += body + "\n"
            }
            progress(0.4 + 0.3 * Double(i + 1) / Double(contentFiles.count))
        }
        combinedHTML += "</body></html>"

        let tempOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(job.requestedOutput.preferredExtension)
        defer { try? FileManager.default.removeItem(at: tempOutput) }

        switch job.requestedOutput {
        case .pdf:
            try await DocumentConversionEngine.renderHTMLToPDF(html: combinedHTML, baseURL: tempDir, to: tempOutput)
        case .html:
            try combinedHTML.write(to: tempOutput, atomically: true, encoding: .utf8)
        case .txt:
            // Strip HTML tags for plain text
            let attributed = try NSAttributedString(
                data: combinedHTML.data(using: .utf8) ?? Data(),
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
            )
            try attributed.string.write(to: tempOutput, atomically: true, encoding: .utf8)
        default:
            throw ConversionError.unsupportedOutput(job.requestedOutput)
        }

        progress(0.9)
        try FileManager.default.moveItem(at: tempOutput, to: destinationURL)
        _ = access
        progress(1.0)
        return ConversionResult(sourceURL: sourceURL, outputURL: destinationURL, outputFormat: job.requestedOutput)
    }

    public func cancel(jobID: UUID) async {}

    // Manifest hrefs are URL references: "Text/chapter%201.xhtml#start"
    static func filePath(fromHref href: String) -> String {
        let path = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        return path.removingPercentEncoding ?? path
    }

    // Chapter images are relative to the chapter file and live in a temp
    // folder that is deleted after conversion, so embed them as data URIs.
    // Remote and data: sources stay as they are
    static func inlineImages(in html: String, chapter: URL, book: URL) -> String {
        let source = /(<(?:img|image)\b[^>]*?\b(?:src|xlink:href|href)\s*=\s*)(["'])(.*?)\2/.ignoresCase()
        return html.replacing(source) { match in
            let (_, prefix, quote, reference) = match.output
            let original = String(match.output.0)
            guard !reference.contains(":"),
                  let file = resolved(chapter.deletingLastPathComponent().appendingPathComponent(filePath(fromHref: String(reference))), inside: book),
                  let data = try? Data(contentsOf: file) else { return original }
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return "\(prefix)\(quote)data:\(mime);base64,\(data.base64EncodedString())\(quote)"
        }
    }

    // The book's real path, or nil when a "../" href or a symlink in the zip
    // points outside the extraction folder. realpath follows the kernel's
    // resolution order, so the checked path is the path that gets read
    static func resolved(_ url: URL, inside directory: URL) -> URL? {
        guard let rootPointer = realpath(directory.path, nil), let filePointer = realpath(url.path, nil) else { return nil }
        defer { free(rootPointer); free(filePointer) }
        let root = String(cString: rootPointer), file = String(cString: filePointer)
        return file.hasPrefix(root + "/") ? URL(fileURLWithPath: file) : nil
    }

    private func findContentFiles(in epubDir: URL) throws -> [URL] {
        // Parse META-INF/container.xml to find content.opf
        let containerURL = epubDir.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL),
              let containerDoc = try? XMLDocument(data: containerData, options: []) else {
            // Fallback: find HTML/XHTML files directly
            return findHTMLFiles(in: epubDir)
        }

        let rootfiles = (try? containerDoc.nodes(forXPath: "//*[local-name()='rootfile']")) ?? []
        guard let rootfile = rootfiles.first as? XMLElement,
              let opfPath = rootfile.attribute(forName: "full-path")?.stringValue else {
            return findHTMLFiles(in: epubDir)
        }

        let opfURL = epubDir.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()

        guard let opfData = try? Data(contentsOf: opfURL),
              let opfDoc = try? XMLDocument(data: opfData, options: []) else {
            return findHTMLFiles(in: epubDir)
        }

        // Get spine order (reading order)
        let spineItems = (try? opfDoc.nodes(forXPath: "//*[local-name()='itemref']")) ?? []
        let manifestItems = (try? opfDoc.nodes(forXPath: "//*[local-name()='item']")) ?? []

        // Build manifest map: id → href
        var manifest: [String: String] = [:]
        for item in manifestItems {
            guard let element = item as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = href
        }

        // Build ordered file list from spine
        var files: [URL] = []
        for spineItem in spineItems {
            guard let element = spineItem as? XMLElement,
                  let idref = element.attribute(forName: "idref")?.stringValue,
                  let href = manifest[idref] else { continue }
            let fileURL = opfDir.appendingPathComponent(Self.filePath(fromHref: href))
            if FileManager.default.fileExists(atPath: fileURL.path) {
                files.append(fileURL)
            }
        }

        return files.isEmpty ? findHTMLFiles(in: epubDir) : files
    }

    private func findHTMLFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            if ext == "xhtml" || ext == "html" || ext == "htm" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func extractBody(from html: String) -> String {
        // Extract content between <body> and </body>
        if let bodyStart = html.range(of: "<body", options: .caseInsensitive),
           let bodyTagEnd = html[bodyStart.upperBound...].range(of: ">"),
           let bodyEnd = html.range(of: "</body>", options: .caseInsensitive) {
            return String(html[bodyTagEnd.upperBound..<bodyEnd.lowerBound])
        }
        return html
    }
}
