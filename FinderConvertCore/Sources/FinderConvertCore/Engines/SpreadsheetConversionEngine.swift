import Foundation
import OSLog

public actor SpreadsheetConversionEngine: ConversionEngine {
    public let identifier = "com.finderconvert.engine.spreadsheet"
    private let logger = Logger(subsystem: "FinderConvert", category: "spreadsheet-engine")
    private let naming = OutputNamingStrategy()

    public init() {}

    private static let supportedInputs: Set<DetectedFileType> = [.csv, .tsv, .xlsx]
    private static let supportedOutputs: Set<OutputFormat> = [.csv, .tsv, .xlsx]

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

        progress(0.1)

        // XLSX → CSV/TSV
        if inputType == .xlsx && (job.requestedOutput == .csv || job.requestedOutput == .tsv) {
            let sheets = try parseXLSXSheets(at: sourceURL)
            progress(0.5)

            let delimiter: String = job.requestedOutput == .csv ? "," : "\t"
            let ext = job.requestedOutput.preferredExtension
            let parentDir = sourceURL.deletingLastPathComponent()
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let nonEmptySheets = sheets.filter { !$0.rows.isEmpty }

            // Single sheet → single file beside source
            if nonEmptySheets.count <= 1 {
                let sheet = nonEmptySheets.first
                guard let rows = sheet?.rows, !rows.isEmpty else {
                    throw ConversionError.filesystemError("No data found in XLSX sheets.")
                }
                let destURL = try naming.destinationURL(for: sourceURL, outputFormat: job.requestedOutput, policy: job.destinationPolicy)
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                try writeDelimited(rows: rows, delimiter: delimiter, to: tempURL)
                try FileManager.default.moveItem(at: tempURL, to: destURL)
                _ = access
                progress(1.0)
                return ConversionResult(sourceURL: sourceURL, outputURL: destURL, outputFormat: job.requestedOutput)
            }

            // Multiple sheets → folder named after file, one file per sheet named after sheet
            var folderURL = parentDir.appendingPathComponent(baseName)
            var counter = 2
            while FileManager.default.fileExists(atPath: folderURL.path(percentEncoded: false)) {
                folderURL = parentDir.appendingPathComponent("\(baseName) \(counter)")
                counter += 1
            }
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

            var firstOutput: URL?

            for (index, sheet) in nonEmptySheets.enumerated() {
                let safeName = sheet.name
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                let destURL = folderURL.appendingPathComponent("\(safeName).\(ext)")

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)

                try writeDelimited(rows: sheet.rows, delimiter: delimiter, to: tempURL)
                try FileManager.default.moveItem(at: tempURL, to: destURL)

                if firstOutput == nil { firstOutput = destURL }
                progress(0.5 + 0.4 * Double(index + 1) / Double(nonEmptySheets.count))
            }

            _ = access
            progress(1.0)

            guard let output = firstOutput else {
                throw ConversionError.filesystemError("No data found in XLSX sheets.")
            }
            return ConversionResult(sourceURL: sourceURL, outputURL: output, outputFormat: job.requestedOutput)
        }

        // Single-sheet conversions
        let destinationURL = try naming.destinationURL(
            for: sourceURL,
            outputFormat: job.requestedOutput,
            policy: job.destinationPolicy
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(job.requestedOutput.preferredExtension)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let rows: [[String]]
        switch inputType {
        case .csv:
            rows = try parseDelimited(at: sourceURL, delimiter: ",")
        case .tsv:
            rows = try parseDelimited(at: sourceURL, delimiter: "\t")
        case .xlsx:
            let sheets = try parseXLSXSheets(at: sourceURL)
            rows = sheets.first?.rows ?? []
        default:
            throw ConversionError.unsupportedFileType(inputType.rawValue)
        }

        progress(0.5)

        switch job.requestedOutput {
        case .csv:
            try writeDelimited(rows: rows, delimiter: ",", to: tempURL)
        case .tsv:
            try writeDelimited(rows: rows, delimiter: "\t", to: tempURL)
        case .xlsx:
            try writeXLSX(rows: rows, to: tempURL)
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

    // MARK: - CSV/TSV Parsing

    private func parseDelimited(at url: URL, delimiter: Character) throws -> [[String]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var rows: [[String]] = []

        for line in content.components(separatedBy: .newlines) {
            // Only trim carriage returns and spaces, not tabs (tabs are delimiters in TSV)
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \r"))
            if trimmed.isEmpty { continue }
            rows.append(parseCSVLine(trimmed, delimiter: delimiter))
        }
        return rows
    }

    private func parseCSVLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = line.makeIterator()

        while let c = chars.next() {
            if inQuotes {
                if c == "\"" {
                    // Check for escaped quote
                    if let next = chars.next() {
                        if next == "\"" {
                            current.append("\"")
                        } else {
                            inQuotes = false
                            if next == delimiter {
                                fields.append(current)
                                current = ""
                            } else {
                                current.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == delimiter {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(c)
                }
            }
        }
        fields.append(current)
        return fields
    }

    // MARK: - CSV/TSV Writing

    private func writeDelimited(rows: [[String]], delimiter: String, to url: URL) throws {
        var output = ""
        for row in rows {
            let escaped = row.map { field -> String in
                if field.contains(delimiter) || field.contains("\"") || field.contains("\n") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }
            output += escaped.joined(separator: delimiter) + "\n"
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - XLSX Parsing

    struct ParsedSheet {
        let name: String
        let rows: [[String]]
    }

    private func parseXLSXSheets(at url: URL) throws -> [ParsedSheet] {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Unzip XLSX
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ConversionError.filesystemError("Failed to unzip XLSX file.")
        }

        // Parse shared strings (may not exist if file uses inline strings).
        // All element lookups match by local name: writers like ClosedXML
        // and EPPlus prefix every element (<x:si>), which name-based
        // matching would miss entirely
        var sharedStrings: [String] = []
        let sharedStringsURL = tempDir.appendingPathComponent("xl/sharedStrings.xml")
        if let ssData = try? Data(contentsOf: sharedStringsURL),
           let ssDoc = try? XMLDocument(data: ssData, options: []) {
            let nodes = try ssDoc.nodes(forXPath: "//*[local-name()='si']")
            for node in nodes {
                if let element = node as? XMLElement {
                    let texts = childElements(of: element, localName: "t").compactMap { $0.stringValue }
                    if texts.isEmpty {
                        let runs = childElements(of: element, localName: "r")
                        let runTexts = runs.flatMap { childElements(of: $0, localName: "t") }.compactMap { $0.stringValue }
                        sharedStrings.append(runTexts.joined())
                    } else {
                        sharedStrings.append(texts.joined())
                    }
                }
            }
        }

        // Read sheet names from workbook.xml and map rId → name
        var sheetNamesByRId: [String: String] = [:]
        let workbookURL = tempDir.appendingPathComponent("xl/workbook.xml")
        if let wbData = try? Data(contentsOf: workbookURL) {
            // Parse with namespace-aware XMLDocument
            if let wbDoc = try? XMLDocument(data: wbData, options: []) {
                let sheetNodes = (try? wbDoc.nodes(forXPath: "//*[local-name()='sheet']")) ?? []
                for node in sheetNodes {
                    guard let element = node as? XMLElement,
                          let name = element.attribute(forName: "name")?.stringValue else { continue }
                    let rId = element.attribute(forName: "r:id")?.stringValue
                        ?? element.attribute(forLocalName: "id", uri: "http://schemas.openxmlformats.org/officeDocument/2006/relationships")?.stringValue
                        ?? ""
                    if !rId.isEmpty {
                        sheetNamesByRId[rId] = name
                    }
                }
            }
            // Fallback: regex parse if XMLDocument namespace handling fails
            if sheetNamesByRId.isEmpty, let xml = String(data: wbData, encoding: .utf8) {
                let pattern = #"<sheet[^>]+name="([^"]+)"[^>]+r:id="([^"]+)""#
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
                    for match in matches {
                        if let nameRange = Range(match.range(at: 1), in: xml),
                           let rIdRange = Range(match.range(at: 2), in: xml) {
                            sheetNamesByRId[String(xml[rIdRange])] = String(xml[nameRange])
                        }
                    }
                }
            }
        }

        // Map rId → file target from workbook.xml.rels
        var sheetEntries: [(rId: String, name: String, url: URL)] = []
        let relsURL = tempDir.appendingPathComponent("xl/_rels/workbook.xml.rels")
        if let relsData = try? Data(contentsOf: relsURL),
           let relsDoc = try? XMLDocument(data: relsData, options: []) {
            let rels = try relsDoc.nodes(forXPath: "//*[local-name()='Relationship']")
            for rel in rels {
                guard let element = rel as? XMLElement,
                      let type = element.attribute(forName: "Type")?.stringValue,
                      type.contains("worksheet"),
                      let target = element.attribute(forName: "Target")?.stringValue,
                      let rId = element.attribute(forName: "Id")?.stringValue else { continue }
                // Target may be relative ("worksheets/sheet1.xml") or absolute ("/xl/worksheets/sheet1.xml")
                let cleanTarget = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
                let sheetURL = tempDir.appendingPathComponent(cleanTarget)
                let name = sheetNamesByRId[rId] ?? sheetURL.deletingPathExtension().lastPathComponent
                if FileManager.default.fileExists(atPath: sheetURL.path) {
                    sheetEntries.append((rId: rId, name: name, url: sheetURL))
                }
            }
            sheetEntries.sort { $0.rId < $1.rId }
        }

        // Fallback: find sheets by listing directory
        if sheetEntries.isEmpty {
            let wsDir = tempDir.appendingPathComponent("xl/worksheets")
            let contents = (try? FileManager.default.contentsOfDirectory(at: wsDir, includingPropertiesForKeys: nil)) ?? []
            let sorted = contents.filter { $0.pathExtension == "xml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for sheetURL in sorted {
                let name = sheetURL.deletingPathExtension().lastPathComponent
                sheetEntries.append((rId: "", name: name, url: sheetURL))
            }
        }

        if sheetEntries.isEmpty {
            throw ConversionError.filesystemError("No worksheets found in XLSX file.")
        }

        let dateStyles = Self.dateStyles(in: tempDir.appendingPathComponent("xl/styles.xml"))
        let workbookXML = (try? String(contentsOf: workbookURL, encoding: .utf8)) ?? ""
        let uses1904 = workbookXML.range(of: #"date1904="(1|true)""#, options: .regularExpression) != nil

        // Parse each sheet
        var sheets: [ParsedSheet] = []
        for entry in sheetEntries {
            guard let sheetData = try? Data(contentsOf: entry.url),
                  let sheetDoc = try? XMLDocument(data: sheetData, options: []) else { continue }
            let rows = try parseSheetXML(doc: sheetDoc, sharedStrings: sharedStrings, dateStyles: dateStyles, uses1904: uses1904)
            if !rows.isEmpty {
                sheets.append(ParsedSheet(name: entry.name, rows: rows))
            }
        }

        return sheets
    }

    // Children matched by local name, so namespace-prefixed spreadsheets
    // (<x:row>, <x:c>) parse the same as unprefixed ones
    private func childElements(of element: XMLElement, localName: String) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == localName }
    }

    private func parseSheetXML(doc: XMLDocument, sharedStrings: [String], dateStyles: [Int: DateKind], uses1904: Bool) throws -> [[String]] {
        let rowNodes = try doc.nodes(forXPath: "//*[local-name()='row']")
        var rows: [[String]] = []
        var maxCol = 0

        for rowNode in rowNodes {
            guard let rowElement = rowNode as? XMLElement else { continue }
            let cellNodes = childElements(of: rowElement, localName: "c")
            var rowData: [(Int, String)] = [] // (column index, value)

            for cell in cellNodes {
                let type = cell.attribute(forName: "t")?.stringValue
                let cellRef = cell.attribute(forName: "r")?.stringValue ?? ""

                // Parse column index from cell reference (e.g., "B3" → column 1)
                let colIndex = columnIndex(from: cellRef)

                let value: String
                if type == "inlineStr" {
                    // Inline string: <is><t>value</t></is>
                    value = childElements(of: cell, localName: "is").first
                        .flatMap { childElements(of: $0, localName: "t").first }?.stringValue ?? ""
                } else if type == "s" {
                    // Shared string reference
                    let vStr = childElements(of: cell, localName: "v").first?.stringValue ?? ""
                    if let idx = Int(vStr), idx < sharedStrings.count {
                        value = sharedStrings[idx]
                    } else {
                        value = vStr
                    }
                } else {
                    // Number or other value. Dates are numbers too (days
                    // since 1900), told apart only by the cell's style
                    let raw = childElements(of: cell, localName: "v").first?.stringValue ?? ""
                    if type == nil || type == "n",
                       let style = cell.attribute(forName: "s")?.stringValue.flatMap(Int.init),
                       let kind = dateStyles[style], let serial = Double(raw) {
                        value = Self.formatDate(serial: serial, kind: kind, uses1904: uses1904)
                    } else {
                        value = raw
                    }
                }

                rowData.append((colIndex, value))
                maxCol = max(maxCol, colIndex)
            }

            // Build full row with empty cells for gaps
            if !rowData.isEmpty {
                var row = Array(repeating: "", count: maxCol + 1)
                for (col, val) in rowData {
                    if col < row.count {
                        row[col] = val
                    }
                }
                rows.append(row)
            }
        }

        // Normalize all rows to same width
        if maxCol > 0 {
            rows = rows.map { row in
                if row.count < maxCol + 1 {
                    return row + Array(repeating: "", count: maxCol + 1 - row.count)
                }
                return row
            }
        }

        return rows
    }

    enum DateKind { case date, time, dateTime }

    // Built-in number formats that show dates or times (ECMA-376 18.8.30,
    // plus the East Asian date ids 27-36 and 50-58)
    private static let builtInDateFormats: [Int: DateKind] = {
        var formats: [Int: DateKind] = [14: .date, 15: .date, 16: .date, 17: .date, 18: .time, 19: .time, 20: .time, 21: .time,
                                        22: .dateTime, 45: .time, 46: .time, 47: .time]
        for id in Array(27...36) + Array(50...58) { formats[id] = .date }
        return formats
    }()

    // Style index (the cell's s attribute) -> date kind, for every cellXfs
    // entry whose number format shows a date or time
    static func dateStyles(in stylesURL: URL) -> [Int: DateKind] {
        guard let data = try? Data(contentsOf: stylesURL), let doc = try? XMLDocument(data: data) else { return [:] }
        var custom: [Int: DateKind] = [:]
        for case let element as XMLElement in (try? doc.nodes(forXPath: "//*[local-name()='numFmt']")) ?? [] {
            guard let id = element.attribute(forName: "numFmtId")?.stringValue.flatMap(Int.init),
                  let code = element.attribute(forName: "formatCode")?.stringValue,
                  let kind = dateKind(ofFormatCode: code) else { continue }
            custom[id] = kind
        }
        let xfs = ((try? doc.nodes(forXPath: "//*[local-name()='cellXfs']/*[local-name()='xf']")) ?? []).compactMap { $0 as? XMLElement }
        var styles: [Int: DateKind] = [:]
        for (index, xf) in xfs.enumerated() {
            guard let id = xf.attribute(forName: "numFmtId")?.stringValue.flatMap(Int.init),
                  let kind = custom[id] ?? builtInDateFormats[id] else { continue }
            styles[index] = kind
        }
        return styles
    }

    // A custom format is a date/time format when, outside quoted text,
    // escapes and [color]/[$-locale] sections, it uses y/d (date) or h/s
    // (time; [h] is elapsed hours). "m" next to h or s is minutes, alone it
    // is months
    static func dateKind(ofFormatCode code: String) -> DateKind? {
        let section = code.split(separator: ";", maxSplits: 1).first.map(String.init) ?? code
        let bare = section
            .replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\."#, with: "", options: .regularExpression)
            .lowercased()
            .replacingOccurrences(of: #"\[([hms]+)\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        guard bare != "general" else { return nil }
        let hasDate = bare.contains("y") || bare.contains("d")
        let hasTime = bare.contains("h") || bare.contains("s")
        switch (hasDate || (bare.contains("m") && !hasTime), hasTime) {
        case (true, true): return .dateTime
        case (true, false): return .date
        case (false, true): return .time
        default: return nil
        }
    }

    // ISO 8601, unambiguous in every locale. Serials count days from
    // 1899-12-30 (which absorbs Excel's fictional 1900-02-29 for every date
    // after it) or, in the 1904 system, from 1904-01-01.
    // ponytail: serials before 1900-03-01 come out one day early
    static func formatDate(serial: Double, kind: DateKind, uses1904: Bool) -> String {
        let unixDays = serial - (uses1904 ? 24107 : 25569)
        let date = Date(timeIntervalSince1970: (unixDays * 86_400).rounded())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch kind {
        case .date: formatter.dateFormat = "yyyy-MM-dd"
        case .time: formatter.dateFormat = "HH:mm:ss"
        case .dateTime: formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        }
        return formatter.string(from: date)
    }

    private func columnIndex(from cellRef: String) -> Int {
        var col = 0
        for c in cellRef {
            if c.isLetter {
                col = col * 26 + Int(c.asciiValue! - 64)
            } else {
                break
            }
        }
        return max(0, col - 1) // Convert 1-based to 0-based
    }

    // MARK: - XLSX Writing

    private func writeXLSX(rows: [[String]], to url: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create XLSX directory structure
        let xlDir = tempDir.appendingPathComponent("xl")
        let wsDir = xlDir.appendingPathComponent("worksheets")
        let relsRoot = tempDir.appendingPathComponent("_rels")
        let relsXL = xlDir.appendingPathComponent("_rels")

        for dir in [wsDir, relsRoot, relsXL] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // [Content_Types].xml
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """.write(to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        // _rels/.rels
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """.write(to: relsRoot.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        // xl/_rels/workbook.xml.rels
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """.write(to: relsXL.appendingPathComponent("workbook.xml.rels"), atomically: true, encoding: .utf8)

        // xl/workbook.xml
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """.write(to: xlDir.appendingPathComponent("workbook.xml"), atomically: true, encoding: .utf8)

        // xl/worksheets/sheet1.xml
        var sheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
        """

        for (rowIndex, row) in rows.enumerated() {
            let rowNum = rowIndex + 1
            sheetXML += "    <row r=\"\(rowNum)\">"
            for (colIndex, value) in row.enumerated() {
                let colLetter = columnLetter(colIndex)
                let cellRef = "\(colLetter)\(rowNum)"
                let escaped = xmlEscape(value)

                if Self.isPlainNumber(value) {
                    sheetXML += "<c r=\"\(cellRef)\"><v>\(escaped)</v></c>"
                } else {
                    sheetXML += "<c r=\"\(cellRef)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escaped)</t></is></c>"
                }
            }
            sheetXML += "</row>\n"
        }

        sheetXML += """
          </sheetData>
        </worksheet>
        """

        try sheetXML.write(to: wsDir.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)

        // ZIP it into .xlsx
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ConversionError.filesystemError("Failed to create XLSX archive.")
        }
    }

    // Written as a number only when Excel would keep it exactly: no leading
    // zeros ("00123" zip codes), no nan/inf/hex that Double accepts, and at
    // most 15 digits (longer IDs would lose precision)
    static func isPlainNumber(_ value: String) -> Bool {
        value.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) != nil
            && value.prefix { $0 != "e" && $0 != "E" }.filter(\.isNumber).count <= 15
    }

    private func columnLetter(_ index: Int) -> String {
        var result = ""
        var n = index
        repeat {
            result = String(Character(UnicodeScalar(65 + n % 26)!)) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }

    // Control characters other than tab, newline and CR are illegal in XML
    // 1.0 and make Excel/Word reject the whole file, so they are dropped
    private func xmlEscape(_ string: String) -> String {
        String(String.UnicodeScalarView(string.unicodeScalars.filter {
            $0.value >= 0x20 ? $0.value != 0xFFFE && $0.value != 0xFFFF : [0x09, 0x0A, 0x0D].contains($0.value)
        }))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
