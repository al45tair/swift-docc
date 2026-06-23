/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021-2026 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation
public import SwiftDocC
import MicroHttpd

/// A preview server instance.
var servers: [String: MicroHttpd] = [:]

fileprivate func trapSignals() {
    // When the user stops docc - stop the preview server first before exiting.
    Signal.on(Signal.all) { _ in
        // This C function wrapper can't capture context so we print to the standard output.
        print("Stopping preview...")

        // This will unblock the execution at `server.start()`.
        for server in servers.values {
            server.stop()
        }
    }
}

/// An action that monitors a documentation bundle for changes and runs a live web-preview.
public final class PreviewAction: AsyncAction {
    /// A test configuration allowing running multiple previews for concurrent testing.
    static var allowConcurrentPreviews = false

    private let printHTMLTemplatePath: Bool
    
    let port: Int
    
    var convertAction: ConvertAction

    private var previewPaths: [String] = []
    
    /// This closure is used to create a new convert action to generate a new version of the docs
    /// whenever the user changes a file in the watched directory.
    private let createConvertAction: () throws -> ConvertAction
    
    /// A unique ID to access the action's preview server.
    let serverIdentifier = ProcessInfo.processInfo.globallyUniqueString
    
    /// Creates a new preview action from the given parameters.
    ///
    /// - Parameters:
    ///   - port: The port number used by the preview server.
    ///   - createConvertAction: A closure that returns the action used to convert the documentation before preview.
    ///
    ///     On macOS, this action will be recreated each time the source is modified to rebuild the documentation.
    ///   - printTemplatePath: Whether or not the HTML template used by the convert action should be printed when the action
    ///     is performed.
    /// - Throws: If an error is encountered while initializing the documentation context.
    public init(
        port: Int,
        createConvertAction: @escaping () throws -> ConvertAction,
        printTemplatePath: Bool = true
    ) throws {
        if !Self.allowConcurrentPreviews && !servers.isEmpty {
            assertionFailure("Running multiple preview actions is not allowed.")
        }
        
        // Initialize the action context.
        self.port = port
        self.createConvertAction = createConvertAction
        self.convertAction = try createConvertAction()
        self.printHTMLTemplatePath = printTemplatePath
    }
    
    /// Converts a documentation bundle and starts a preview server to render the result of that conversion.
    ///
    /// > Important: On macOS, the bundle will be converted each time the source is modified.
    ///
    /// - Parameter logHandle: The file handle that the convert and preview actions will print debug messages to.
    public func perform(logHandle: inout LogHandle) async throws -> ActionResult {
        self.logHandle.sync { $0 = logHandle }

        if let rootURL = convertAction.rootURL {
            print("Input: \(rootURL.path)")
        }
        // TODO: This never did output human readable string; rdar://74324255
        // print("Input: \(convertAction.documentationCoverageOptions)", to: &self.logHandle)

        // In case a developer is using a custom template log its path.
        if printHTMLTemplatePath, let htmlTemplateDirectory = convertAction.htmlTemplateDirectory {
            print("Template: \(htmlTemplateDirectory.path)")
        }
        
        let previewResult = try await preview()
        return ActionResult(didEncounterError: previewResult.didEncounterError, outputs: [convertAction.targetURL])
    }

    /// Stops a currently running preview session.
    func stop() {
        monitoredConvertTask?.cancel()
        
        servers[serverIdentifier]?.stop()
        servers.removeValue(forKey: serverIdentifier)
    }
    
    func preview() async throws -> ActionResult {
        // Convert the documentation source for previewing.
        let result = try await convert()
        guard !result.didEncounterError else {
            return result
        }

        let previewResult: ActionResult
        // Preview the output and monitor the source bundle for changes.
        do {
            print(String(repeating: "=", count: 40))
            if let previewURL = URL(string: "http://localhost:\(port)") {
                print("Starting Local Preview Server")
                printPreviewAddresses(base: previewURL)
                print(String(repeating: "=", count: 40))
            }

            let convertURL = convertAction.targetURL.absoluteURL

            print("Serving from \(convertURL)")

            let fileSystem: any ReadOnlyFileManagerProtocol
            let rootURL: URL
            if FileManager.default.directoryExists(
                atPath: convertURL.path
            ) {
                rootURL = convertAction.targetURL
                fileSystem = FileManager.default
            } else {
                let zippedData = try FileManager.default.contents(of: convertURL)
                let zipDataSource = ZipFileDataSource(data: zippedData)
                let zipReader = try ZipFileReader(source: zipDataSource)

                rootURL = URL(filePath: "/")
                fileSystem = zipReader
            }

            let previewHandler = PreviewRequestHandler(
                archiveRoot: rootURL,
                fileSystem: fileSystem
            )

            servers[serverIdentifier] = MicroHttpd(
                port: UInt16(port),
                requestHandler: previewHandler
            )
            
            // When the user stops docc - stop the preview server first before exiting.
            trapSignals()

            // This will wait until the server is manually killed.
            try servers[serverIdentifier]!.serve()
            previewResult = ActionResult(didEncounterError: false)
        } catch {
            let diagnosticEngine = convertAction.diagnosticEngine
            // FIXME: Instead of wrapping the error message in a diagnostic, re-throw the original Error after removing the server.
            diagnosticEngine.emit(.init(severity: .error, range: nil, identifier: "UnexpectedPreviewFailure", summary: error.localizedDescription))
            diagnosticEngine.flush()
            
            // Stale server entry, remove it from the list
            servers.removeValue(forKey: serverIdentifier)
            previewResult = ActionResult(didEncounterError: true)
        }

        return previewResult
    }
    
    func convert() async throws -> ActionResult {
        convertAction = try createConvertAction()
        var logHandleCopy = logHandle.sync { $0 }
        let (result, context) = try await convertAction.perform(logHandle: &logHandleCopy)
        
        previewPaths = try context.previewPaths()
        return result
    }
    
    private func printPreviewAddresses(base: URL) {
        // If the preview paths are empty, just print the base.
        let firstPath = previewPaths.first ?? ""
        print("\t Address: \(base.appendingPathComponent(firstPath).absoluteString)")
            
        let spacing = String(repeating: " ", count: "Address:".count)
        for previewPath in previewPaths.dropFirst() {
            print("\t \(spacing) \(base.appendingPathComponent(previewPath).absoluteString)")
        }
    }
    
    private var logHandle: Synchronized<LogHandle> = .init(.none)
    
    fileprivate func print(_ string: String, terminator: String = "\n") {
        logHandle.sync { logHandle in
            Swift.print(string, terminator: terminator, to: &logHandle)
        }
    }
    
    fileprivate var monitoredConvertTask: Task<Void, Never>?
}

extension DocumentationContext {
    
    /// A collection of non-implicit root modules
    var renderRootModules: [ResolvedTopicReference] {
        get throws {
            try rootModules.filter({ try !entity(with: $0).isVirtual })
        }
    }
    
    /// Finds the module and tutorial table-of-contents pages in the context and returns their paths.
    func previewPaths() throws -> [String] {
        let urlGenerator = PresentationURLGenerator(context: self, baseURL: URL(string: "/")!)
        
        let rootModules = try renderRootModules
        
        return (rootModules + tutorialTableOfContentsReferences).map { page in
            urlGenerator.presentationURLForReference(page).absoluteString
        }
    }
}
