import AppKit
import Foundation
import OSLog
import PDFKit
import UniformTypeIdentifiers
import WebKit

private final class PDFPrintCompletionDelegate: NSObject {
    private let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @objc func printOperationDidRun(
        _ printOperation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        continuation.resume(returning: success)
    }
}

public actor DocumentConversionEngine: ConversionEngine {
    public let identifier = "com.finderconvert.engine.document.text"
    private let logger = Logger(subsystem: "FinderConvert", category: "document-engine")
    private let naming = OutputNamingStrategy()

    public init() {}

    private static let textInputs: Set<DetectedFileType> = [.rtf, .html, .txt, .markdown, .docx]
    private static let textOutputs: Set<OutputFormat> = [.pdf, .rtf, .html, .txt]

    public nonisolated func supports(input: DetectedFileType, output: OutputFormat) -> Bool {
        Self.textInputs.contains(input) && Self.textOutputs.contains(output)
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

        progress(0.1)

        let destinationURL = try naming.destinationURL(
            for: sourceURL,
            outputFormat: job.requestedOutput,
            policy: job.destinationPolicy
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(job.requestedOutput.preferredExtension)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Read source document into NSAttributedString
        let attributedString = try readDocument(at: sourceURL, type: inputType)
        progress(0.4)

        // Write to target format
        switch job.requestedOutput {
        case .pdf:
            try await writePDF(from: attributedString, sourceType: inputType, sourceURL: sourceURL, to: tempURL)
        case .rtf:
            try writeRTF(from: attributedString, to: tempURL)
        case .html:
            // For markdown → html, produce clean HTML directly
            if inputType == .markdown {
                let mdData = try Data(contentsOf: sourceURL)
                let mdString = String(data: mdData, encoding: .utf8) ?? ""
                try markdownToHTML(mdString).write(to: tempURL, atomically: true, encoding: .utf8)
            } else {
                try writeHTML(from: attributedString, to: tempURL)
            }
        case .txt:
            try writePlainText(from: attributedString, to: tempURL)
        default:
            throw ConversionError.unsupportedOutput(job.requestedOutput)
        }

        progress(0.9)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        _ = access
        progress(1.0)
        return ConversionResult(sourceURL: sourceURL, outputURL: destinationURL, outputFormat: job.requestedOutput)
    }

    public func cancel(jobID: UUID) async {}

    // MARK: - Reading

    private func readDocument(at url: URL, type: DetectedFileType) throws -> NSAttributedString {
        var data = try Data(contentsOf: url)

        // Convert Markdown to HTML before parsing
        var effectiveType = type
        if type == .markdown {
            let markdown = String(data: data, encoding: .utf8) ?? ""
            let html = markdownToHTML(markdown)
            data = html.data(using: .utf8) ?? data
            effectiveType = .html
        }

        let documentType: NSAttributedString.DocumentType
        switch effectiveType {
        case .rtf: documentType = .rtf
        case .html: documentType = .html
        case .docx: documentType = .officeOpenXML
        case .txt: documentType = .plain
        default: documentType = .plain
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]

        return try NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    // MARK: - Writing

    private func writePDF(from text: NSAttributedString, sourceType: DetectedFileType, sourceURL: URL, to url: URL) async throws {
        // For HTML and Markdown, use WebKit for better rendering
        if sourceType == .html || sourceType == .markdown {
            try await renderHTMLToPDF(sourceURL: sourceURL, to: url, isMarkdown: sourceType == .markdown)
            return
        }

        // Copy string data to cross actor boundary safely
        let plainString = text.string
        let rtfData = try? text.data(from: NSRange(location: 0, length: text.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])

        try await MainActor.run {
            let pageSize = NSSize(width: 612, height: 792)
            let margin: CGFloat = 72
            let contentWidth = pageSize.width - margin * 2

            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: pageSize.height))
            textView.isVerticallyResizable = true
            textView.textContainer?.widthTracksTextView = true

            if let rtfData,
               let restored = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
                textView.textStorage?.setAttributedString(restored)
            } else {
                textView.string = plainString
            }
            textView.sizeToFit()

            // Print the text view so long documents paginate across multiple
            // pages (dataWithPDF produces a single oversized page)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: pageSize),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = textView

            let printInfo = NSPrintInfo()
            printInfo.paperSize = pageSize
            printInfo.topMargin = margin
            printInfo.bottomMargin = margin
            printInfo.leftMargin = margin
            printInfo.rightMargin = margin
            printInfo.horizontalPagination = .fit
            printInfo.verticalPagination = .automatic
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

            let operation = NSPrintOperation(view: textView, printInfo: printInfo)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false

            if operation.run(), FileManager.default.fileExists(atPath: url.path) {
                return
            }

            // Fallback: capture the full content as a single tall PDF page
            let pdfData = textView.dataWithPDF(inside: textView.bounds)
            try pdfData.write(to: url)
        }
    }

    @MainActor
    private func renderHTMLToPDF(sourceURL: URL, to outputURL: URL, isMarkdown: Bool = false) async throws {
        let htmlData = try Data(contentsOf: sourceURL)
        guard let rawString = String(data: htmlData, encoding: .utf8) else {
            throw ConversionError.unreadableInput
        }
        let htmlString = isMarkdown ? markdownToHTML(rawString) : rawString
        try await Self.renderHTMLToPDF(html: htmlString, baseURL: sourceURL.deletingLastPathComponent(), to: outputURL)
    }

    @MainActor
    static func renderHTMLToPDF(html htmlString: String, baseURL: URL, to outputURL: URL) async throws {
        // Input files are untrusted: no page scripts, and no navigation past
        // the document itself (a meta refresh or iframe could otherwise pull
        // another local file into the PDF)
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), configuration: configuration)
        webView.loadHTMLString(htmlString, baseURL: baseURL)

        // Wait for load
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            class LoadDelegate: NSObject, WKNavigationDelegate {
                private var continuation: CheckedContinuation<Void, Error>?
                private var loadedDocument = false
                init(_ c: CheckedContinuation<Void, Error>) { self.continuation = c }
                // Load callbacks and the timeout can both fire; only the first counts
                func finish(_ error: Error? = nil) {
                    if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
                    continuation = nil
                }
                func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
                    decisionHandler(loadedDocument ? .cancel : .allow)
                    loadedDocument = true
                }
                func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                    finish()
                }
                func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
                    finish(error)
                }
                func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
                    finish(error)
                }
            }
            let delegate = LoadDelegate(continuation)
            objc_setAssociatedObject(webView, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.navigationDelegate = delegate
            // A slow remote image or stylesheet can stall didFinish indefinitely
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak webView, weak delegate] in
                webView?.stopLoading()
                delegate?.finish(ConversionError.filesystemError("The document took too long to load."))
            }
        }

        // Let WebKit finish layout after the navigation callback fires
        try await Task.sleep(nanoseconds: 300_000_000)

        // Print through WebKit so long documents paginate across multiple pages
        // (a fixed-rect webView.pdf() snapshot only captures the first page)
        let pageSize = NSSize(width: 612, height: 792)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: pageSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView

        let printInfo = NSPrintInfo()
        printInfo.paperSize = pageSize
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = outputURL

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = NSRect(origin: .zero, size: pageSize)

        let printed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let delegate = PDFPrintCompletionDelegate(continuation)
            objc_setAssociatedObject(webView, "printDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            operation.runModal(
                for: window,
                delegate: delegate,
                didRun: #selector(PDFPrintCompletionDelegate.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }

        if printed, FileManager.default.fileExists(atPath: outputURL.path) {
            return
        }

        // Fallback: capture the full content as a single tall PDF page
        let heightValue = try? await webView.evaluateJavaScript("document.documentElement.scrollHeight")
        let contentHeight = (heightValue as? Double).map { CGFloat($0) } ?? pageSize.height
        webView.frame = NSRect(x: 0, y: 0, width: pageSize.width, height: max(contentHeight, pageSize.height))
        let pdfConfig = WKPDFConfiguration()
        pdfConfig.rect = webView.bounds
        let pdfData = try await webView.pdf(configuration: pdfConfig)
        try pdfData.write(to: outputURL)
    }

    private func writeRTF(from text: NSAttributedString, to url: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        let data = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: url)
    }

    private func writeHTML(from text: NSAttributedString, to url: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        let data = try text.data(from: range, documentAttributes: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ])
        try data.write(to: url)
    }

    private func writePlainText(from text: NSAttributedString, to url: URL) throws {
        try text.string.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Markdown

    nonisolated func markdownToHTML(
        _ markdown: String,
        style: MarkdownStyle = PreferencesManager.shared.markdownStyle
    ) -> String {
        var html = ""
        let lines = markdown.components(separatedBy: .newlines)
        var inCodeBlock = false
        // Open lists, outermost first. An item's <li> stays open so a more
        // indented list nests inside it
        var lists: [(indent: Int, tag: String)] = []

        func closeLists(deeperThan indent: Int = -1) {
            while let last = lists.last, last.indent > indent {
                html += "</li></\(last.tag)>\n"
                lists.removeLast()
            }
        }

        func listItem(_ line: String) -> (indent: Int, tag: String, content: String)? {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                return (indent, "ul", String(trimmed.dropFirst(2)))
            }
            if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }), dot > trimmed.startIndex,
               trimmed[..<dot].allSatisfy(\.isNumber), trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                return (indent, "ol", String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1

            // Code blocks
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCodeBlock {
                    html += "</code></pre>\n"
                    inCodeBlock = false
                } else {
                    closeLists()
                    html += "<pre><code>"
                    inCodeBlock = true
                }
                continue
            }
            if inCodeBlock {
                html += escapeHTML(line) + "\n"
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line
            if trimmed.isEmpty {
                closeLists()
                continue
            }

            if let item = listItem(line) {
                closeLists(deeperThan: item.indent)
                if let last = lists.last, last.indent == item.indent {
                    if last.tag == item.tag {
                        html += "</li>\n"
                    } else {
                        html += "</li></\(last.tag)>\n"
                        lists.removeLast()
                    }
                }
                if lists.last.map({ $0.indent < item.indent }) ?? true {
                    html += "<\(item.tag)>\n"
                    lists.append((item.indent, item.tag))
                }
                html += "<li>\(processInline(item.content))"
                continue
            }
            closeLists()

            // Pipe table: a header row, then a |---|:---:| separator row
            if trimmed.contains("|"), index < lines.count, let alignments = tableAlignments(lines[index]) {
                index += 1
                let header = tableCells(trimmed)
                func cellTag(_ name: String, _ column: Int, _ content: String) -> String {
                    let align = column < alignments.count ? alignments[column] : nil
                    return "<\(name)\(align.map { " style=\"text-align: \($0)\"" } ?? "")>\(processInline(content))</\(name)>"
                }
                html += "<table>\n<thead><tr>" + header.enumerated().map { cellTag("th", $0.offset, $0.element) }.joined() + "</tr></thead>\n<tbody>\n"
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let cells = tableCells(lines[index].trimmingCharacters(in: .whitespaces))
                    // Rows are padded or cut to the header's width, as GitHub does
                    let row = (0..<header.count).map { $0 < cells.count ? cells[$0] : "" }
                    html += "<tr>" + row.enumerated().map { cellTag("td", $0.offset, $0.element) }.joined() + "</tr>\n"
                    index += 1
                }
                html += "</tbody>\n</table>\n"
                continue
            }

            // Headers
            if let level = Optional(trimmed.prefix { $0 == "#" }.count), (1...6).contains(level),
               trimmed.dropFirst(level).first == " " {
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                html += "<h\(level)>\(processInline(text))</h\(level)>\n"
            }
            // Horizontal rule
            else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                html += "<hr/>\n"
            }
            // Blockquote
            else if trimmed.hasPrefix(">") {
                html += "<blockquote><p>\(processInline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))</p></blockquote>\n"
            }
            // Regular paragraph
            else {
                html += "<p>\(processInline(trimmed))</p>\n"
            }
        }

        if inCodeBlock { html += "</code></pre>\n" }
        closeLists()

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
        \(style.css)
        </style></head><body>
        \(html)
        </body></html>
        """
    }

    // Cells of a table row; a leading and trailing pipe are optional and
    // "\|" is a literal pipe
    nonisolated private func tableCells(_ row: String) -> [String] {
        var body = row.replacingOccurrences(of: "\\|", with: "\u{0}")
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "\u{0}", with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    // Per-column alignment from a separator row like "| :--- | :--: | --: |",
    // or nil when the line isn't one
    nonisolated private func tableAlignments(_ line: String) -> [String?]? {
        let cells = tableCells(line.trimmingCharacters(in: .whitespaces))
        guard !cells.isEmpty, cells.allSatisfy({ $0.wholeMatch(of: /:?-+:?/) != nil }) else { return nil }
        return cells.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): "center"
            case (false, true): "right"
            case (true, false): "left"
            default: nil
            }
        }
    }

    nonisolated private func processInline(_ text: String) -> String {
        var result = escapeHTML(text)
        // Bold: **text** or __text__
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        result = result.replacingOccurrences(of: "__(.+?)__", with: "<strong>$1</strong>", options: .regularExpression)
        // Italic: *text* or _text_
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<![a-zA-Z])_(.+?)_(?![a-zA-Z])", with: "<em>$1</em>", options: .regularExpression)
        // Inline code: `text`
        result = result.replacingOccurrences(of: "`(.+?)`", with: "<code>$1</code>", options: .regularExpression)
        // Images: ![alt](src "optional title"), before links so the link
        // pattern doesn't take them
        result = result.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\(([^)\\s]+)[^)]*\\)", with: "<img src=\"$2\" alt=\"$1\">", options: .regularExpression)
        // Links: [text](url)
        result = result.replacingOccurrences(of: "\\[(.+?)\\]\\((.+?)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        return result
    }

    nonisolated private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
