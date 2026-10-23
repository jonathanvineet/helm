import AppKit
import Foundation

/// Starts one bundled process per request. No installed Python, server, or port
/// is needed. The helper exits after replying; quitting Helm stops active work.
@MainActor
final class QuoteHelper {
    static let shared = QuoteHelper()
    private var process: Process?
    private var workingDirectory: URL?
    private let executable: URL?

    init(executable: URL? = nil) {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        self.executable = executable ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/OCR/\(architecture)/helm-ocr.app/Contents/MacOS/helm-ocr")
    }

    func request(action: String, payload: Data) async throws -> Data {
        guard process == nil else { throw PrintQuoteError.message("A quotation is already being processed.") }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PrintQuoteError.message("This copy of Helm is missing its OCR helper. Rebuild or reinstall the complete application.")
        }
        let object = try JSONSerialization.jsonObject(with: payload)
        let input = try JSONSerialization.data(withJSONObject: ["action": action, "payload": object])
        // Files avoid blocking the UI on large pipe writes. The private temporary
        // directory is removed after every request, including failure and timeout.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helm-quote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        workingDirectory = directory
        defer { try? FileManager.default.removeItem(at: directory); workingDirectory = nil }
        let inputURL = directory.appendingPathComponent("request.json")
        let outputURL = directory.appendingPathComponent("response.json")
        try input.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: inputURL)
        let stdout = try FileHandle(forWritingTo: outputURL)
        defer { try? stdin.close(); try? stdout.close() }

        let child = Process()
        child.executableURL = executable
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = directory
        // A packaged helper must resolve its own runtime rather than inherit
        // development Python/Tesseract configuration from the launching shell.
        var environment = ProcessInfo.processInfo.environment
        for key in ["PYTHONHOME", "PYTHONPATH", "TESSERACT_CMD", "TESSDATA_PREFIX", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] {
            environment.removeValue(forKey: key)
        }
        child.environment = environment
        process = child
        defer { process = nil }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            if child.isRunning { child.terminate() }
        }
        defer { watchdog.cancel() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            child.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do { try child.run() }
            catch {
                child.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            throw PrintQuoteError.message("OCR stopped or timed out. Try a smaller screenshot or enter the values manually.")
        }
        return try Data(contentsOf: outputURL)
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
    }
}

/// Uses macOS's region/window picker while every Helm window is hidden. The
/// clipboard is untouched; a cancelled selection leaves the current image alone.
@MainActor
final class QuoteScreenCapture {
    static let shared = QuoteScreenCapture()
    private var process: Process?
    private var workingDirectory: URL?

    func capture() async throws -> Data? {
        guard process == nil else { return nil }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw PrintQuoteError.message("Allow Helm in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. macOS may ask you to reopen Helm.")
        }
        let window = NSApp.keyWindow
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helm-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        workingDirectory = directory
        let imageURL = directory.appendingPathComponent("capture.png")
        NSApp.hide(nil)
        defer {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            try? FileManager.default.removeItem(at: directory)
            workingDirectory = nil
        }
        // Allow WindowServer to finish removing Helm before the picker starts.
        try await Task.sleep(for: .milliseconds(400))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        child.arguments = ["-i", "-x", "-t", "png", imageURL.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        process = child
        defer { process = nil }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            child.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try child.run() }
            catch {
                child.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        // Escape returns no image (and can return a nonzero exit status).
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return nil }
        guard status == 0 else { throw PrintQuoteError.message("Screen capture failed. Try again or choose an image file.") }
        let size = try imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10 * 1024 * 1024 else {
            throw PrintQuoteError.message("The capture exceeds 10 MB. Capture just the print estimate area.")
        }
        return try Data(contentsOf: imageURL)
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
    }
}
