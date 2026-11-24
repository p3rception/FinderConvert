import Foundation
import OSLog

public struct QuickActionConversionService: Sendable {
    private let logger = Logger(subsystem: "FinderConvert", category: "finder-extension")
    private let detector: FileTypeDetector
    private let registry: FinderConvertRegistry

    public init(
        detector: FileTypeDetector = FileTypeDetector(),
        registry: FinderConvertRegistry = FinderConvertRegistry()
    ) {
        self.detector = detector
        self.registry = registry
    }

    public func inspectSelectedURLs(_ urls: [URL]) throws -> [DetectedFile] {
        try urls.map { try detector.detect(url: $0) }
    }

    // Bounded look at a selection for menu building: enumerate at most
    // `limit` files so a huge folder can't stall the caller. Empty result
    // can mean either nothing convertible or no permission to enumerate
    public func sampledOutputs(for urls: [URL], limit: Int = 200) -> [OutputFormat] {
        var files: [DetectedFile] = []
        let fileManager = FileManager.default
        outer: for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let child = enumerator?.nextObject() as? URL {
                    if let detected = try? detector.detect(url: child), detected.detectedType != .unsupported {
                        files.append(detected)
                        if files.count >= limit { break outer }
                    }
                }
            } else if let detected = try? detector.detect(url: url), detected.detectedType != .unsupported {
                files.append(detected)
                if files.count >= limit { break }
            }
        }
        return registry.availableOutputs(for: files)
    }

    public func availableOutputs(for urls: [URL]) throws -> [OutputFormat] {
        let expanded = expandURLs(urls)
        let detected = expanded.compactMap { item -> DetectedFile? in
            guard let df = try? detector.detect(url: item.url), df.detectedType != .unsupported else { return nil }
            return df
        }
        return registry.availableOutputs(for: detected)
    }

    private func expandURLs(_ urls: [URL]) -> [(url: URL, originalRoot: URL?)] {
        var expanded: [(URL, URL?)] = []
        let fileManager = FileManager.default

        for url in urls {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    let resolvedRoot = url.standardizedFileURL.resolvingSymlinksInPath()
                    let enumerator = fileManager.enumerator(at: resolvedRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    while let childURL = enumerator?.nextObject() as? URL {
                        let resourceValues = try? childURL.resourceValues(forKeys: [.isRegularFileKey])
                        if resourceValues?.isRegularFile == true {
                            let resolvedChild = childURL.standardizedFileURL.resolvingSymlinksInPath()
                            expanded.append((resolvedChild, resolvedRoot))
                        }
                    }
                } else {
                    expanded.append((url, nil))
                }
            }
        }
        return expanded
    }

    public func convert(urls: [URL], requestedOutput: OutputFormat? = nil) async throws -> BatchConversionResult {
        let expanded = expandURLs(urls)
        let detected = expanded.compactMap { item -> (file: DetectedFile, root: URL?)? in
            guard let df = try? detector.detect(url: item.url), df.detectedType != .unsupported else { return nil }
            return (df, item.originalRoot)
        }
        
        let outputs = registry.availableOutputs(for: detected.map { $0.file })
        guard let chosenOutput = requestedOutput ?? outputs.first else {
            throw ConversionError.unsupportedSelection
        }

        var successes: [ConversionResult] = []
        var failures: [ConversionFailure] = []

        for item in detected {
            // Cancelling stops between files; finished outputs are kept
            if Task.isCancelled { break }
            let file = item.file
            let originalRoot = item.root
            do {
                let bookmarkData = try SecurityScopedAccess(url: file.url).perform {
                    try file.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                
                let job = ConversionJob(
                    sourceBookmarkData: bookmarkData,
                    requestedOutput: chosenOutput,
                    destinationPolicy: destinationPolicy(for: file.url, root: originalRoot, folderSuffix: " converted", fileSuffix: nil)
                )
                let engine = registry.engine(for: file.detectedType, output: chosenOutput)
                let result = try await run(engine, job)
                successes.append(result)
            } catch _ where Task.isCancelled {
                break
            } catch let error as ConversionError {
                failures.append(ConversionFailure(sourceURL: file.url, error: error))
            } catch {
                logger.error("Unexpected conversion error: \(error.localizedDescription, privacy: .public)")
                failures.append(ConversionFailure(sourceURL: file.url, error: .filesystemError(error.localizedDescription)))
            }
        }

        return BatchConversionResult(
            requestedOutput: chosenOutput,
            successes: successes,
            failures: failures
        )
    }

    // Re-encode every lossy file in its own format with the current
    // settings, as "name compressed.ext" (or into "Folder compressed").
    // Results that aren't smaller are deleted and the source reported as
    // skipped, so compressing never leaves a bigger copy behind
    public func compress(urls: [URL]) async throws -> BatchConversionResult {
        let detected = expandURLs(urls).compactMap { item -> (file: DetectedFile, root: URL?)? in
            guard let df = try? detector.detect(url: item.url), Compression.isCompressible(df.detectedType) else { return nil }
            return (df, item.originalRoot)
        }
        guard !detected.isEmpty else { throw ConversionError.unsupportedSelection }

        var successes: [ConversionResult] = []
        var failures: [ConversionFailure] = []
        var skipped: [URL] = []
        var firstOutput: OutputFormat?

        for (file, originalRoot) in detected {
            if Task.isCancelled { break }
            do {
                guard let output = await Compression.target(for: file.url, type: file.detectedType) else {
                    skipped.append(file.url)
                    continue
                }
                firstOutput = firstOutput ?? output
                let bookmarkData = try SecurityScopedAccess(url: file.url).perform {
                    try file.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                let job = ConversionJob(
                    sourceBookmarkData: bookmarkData,
                    requestedOutput: output,
                    destinationPolicy: destinationPolicy(for: file.url, root: originalRoot, folderSuffix: Compression.outputSuffix, fileSuffix: Compression.outputSuffix)
                )
                let engine = registry.engine(for: file.detectedType, output: output)
                let result = try await run(engine, job)

                if let before = Compression.fileSize(file.url), let after = Compression.fileSize(result.outputURL), after >= before {
                    try? FileManager.default.removeItem(at: result.outputURL)
                    skipped.append(file.url)
                } else {
                    successes.append(result)
                }
            } catch _ where Task.isCancelled {
                break
            } catch let error as ConversionError {
                failures.append(ConversionFailure(sourceURL: file.url, error: error))
            } catch {
                logger.error("Unexpected compression error: \(error.localizedDescription, privacy: .public)")
                failures.append(ConversionFailure(sourceURL: file.url, error: .filesystemError(error.localizedDescription)))
            }
        }

        // Targets differ per file; the batch reports the first one
        return BatchConversionResult(
            requestedOutput: firstOutput ?? .jpeg,
            successes: successes,
            failures: failures,
            skipped: skipped
        )
    }

    // Cancelling the calling task also stops the file in progress, for
    // engines that support it (video); the others finish the current file.
    // Their temp output is removed and nothing is published
    private func run(_ engine: any ConversionEngine, _ job: ConversionJob) async throws -> ConversionResult {
        try await withTaskCancellationHandler {
            try await engine.convert(job: job) { _ in }
        } onCancel: {
            Task { await engine.cancel(jobID: job.id) }
        }
    }

    // Copy each JPEG/PNG as "name clean.ext" with its metadata removed and
    // the image data untouched. Other files in the selection are skipped
    public func removeMetadata(urls: [URL]) throws -> BatchConversionResult {
        let detected = urls.compactMap { url -> DetectedFile? in
            guard let file = try? detector.detect(url: url), MetadataRemoval.supports(file.detectedType) else { return nil }
            return file
        }
        guard !detected.isEmpty else { throw ConversionError.unsupportedSelection }

        var successes: [ConversionResult] = []
        var failures: [ConversionFailure] = []
        for file in detected {
            let output: OutputFormat = file.detectedType == .png ? .png : .jpeg
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension(output.preferredExtension)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            do {
                let destination = try OutputNamingStrategy().destinationURL(
                    for: file.url, outputFormat: output,
                    policy: destinationPolicy(for: file.url, root: nil, folderSuffix: MetadataRemoval.outputSuffix, fileSuffix: MetadataRemoval.outputSuffix)
                )
                try MetadataRemoval.removeMetadata(from: file.url, to: tempURL, type: file.detectedType)
                try FileManager.default.moveItem(at: tempURL, to: destination)
                successes.append(ConversionResult(sourceURL: file.url, outputURL: destination, outputFormat: output))
            } catch let error as ConversionError {
                failures.append(ConversionFailure(sourceURL: file.url, error: error))
            } catch {
                failures.append(ConversionFailure(sourceURL: file.url, error: .filesystemError(error.localizedDescription)))
            }
        }
        return BatchConversionResult(requestedOutput: successes.first?.outputFormat ?? .jpeg, successes: successes, failures: failures)
    }

    // Folder contents mirror into a sibling "<folder><suffix>" (or the custom
    // output folder); loose files land beside the source
    private func destinationPolicy(for url: URL, root: URL?, folderSuffix: String, fileSuffix: String?) -> DestinationPolicy {
        let prefs = PreferencesManager.shared
        if prefs.useCustomOutputFolder, let customFolder = prefs.customOutputFolder {
            if let root {
                return .mirroredDirectory(originalRoot: root, newRoot: customFolder.appending(path: root.lastPathComponent, directoryHint: .isDirectory))
            }
            return .mirroredDirectory(originalRoot: url.deletingLastPathComponent(), newRoot: customFolder)
        }
        if let root {
            let newRoot = root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)\(folderSuffix)", directoryHint: .isDirectory)
            return .mirroredDirectory(originalRoot: root, newRoot: newRoot)
        }
        return .neverReplace(customSuffix: fileSuffix)
    }
}
