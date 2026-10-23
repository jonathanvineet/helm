import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PrintRates: Codable {
    var filamentPerGram = 2.5
    var machinePerHour = 10.0
    var electricityPerHour = 8.0
    var maintenancePercent = 5.0
    var riskPercent = 5.0
    var labourPercent = 10.0
    var designPercent = 5.0
    var packaging = 50.0
    var profitPercent = 30.0

    static let fields: [(String, WritableKeyPath<PrintRates, Double>, Double)] = [
        ("Filament (₹/g)", \.filamentPerGram, 100_000),
        ("Machine (₹/hour)", \.machinePerHour, 100_000),
        ("Electricity (₹/hour)", \.electricityPerHour, 100_000),
        ("Maintenance (%)", \.maintenancePercent, 1_000),
        ("Risk (%)", \.riskPercent, 1_000),
        ("Labour (%)", \.labourPercent, 1_000),
        ("Design (%)", \.designPercent, 1_000),
        ("Packaging (₹)", \.packaging, 1_000_000),
        ("Profit markup (%)", \.profitPercent, 1_000),
    ]
}

private struct PrintExtraction: Decodable {
    let filamentGrams: Double
    let printTimeMinutes: Double
}

struct PrintQuoteResult: Decodable {
    let currency: String
    let quote: [String: Double]
}

private struct PrintQuoteRequest: Encodable {
    let filamentGrams: Double
    let printTimeMinutes: Double
    let rates: PrintRates
}

private struct PrintHelperResponse<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let error: String?
}

enum PrintQuoteError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// Runs quotation work in the bundled helper; screensaver sync stays independent.
@MainActor
final class PrintQuoteModel: ObservableObject {
    @Published var image: NSImage?
    @Published var filename = ""
    @Published var grams = "" { didSet { result = nil } }
    @Published var minutes = "" { didSet { result = nil } }
    @Published var rates: PrintRates {
        didSet {
            result = nil
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(rates) { UserDefaults.standard.set(data, forKey: "printQuoteRates") }
        }
    }
    @Published var busy = false
    @Published var message: String?
    @Published var result: PrintQuoteResult?
    private var upload: Data?
    private var mime = "image/png"

    init() {
        rates = UserDefaults.standard.data(forKey: "printQuoteRates")
            .flatMap { try? JSONDecoder().decode(PrintRates.self, from: $0) } ?? PrintRates()
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10 * 1024 * 1024 else { throw PrintQuoteError.message("Choose an image smaller than 10 MB.") }
            let data = try Data(contentsOf: url)
            guard let preview = NSImage(data: data) else { throw PrintQuoteError.message("This image could not be opened.") }
            setImage(preview, data: data, filename: url.lastPathComponent,
                     mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png")
        } catch { message = error.localizedDescription }
    }

    func pasteImage() {
        guard let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let preview = images.first,
              let tiff = preview.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            message = "Copy an image or screenshot, then choose Paste Image."
            return
        }
        guard data.count <= 10 * 1024 * 1024 else { message = "The pasted image exceeds 10 MB. Crop it and try again."; return }
        setImage(preview, data: data, filename: "Pasted screenshot.png", mime: "image/png")
    }

    func captureScreen() async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            guard let data = try await QuoteScreenCapture.shared.capture(), let preview = NSImage(data: data) else { return }
            setImage(preview, data: data, filename: "Screen capture.png", mime: "image/png")
        } catch { message = error.localizedDescription }
    }

    private func setImage(_ preview: NSImage, data: Data, filename: String, mime: String) {
        image = preview
        upload = data
        self.filename = filename
        self.mime = mime
        grams = ""
        minutes = ""
        message = nil
    }

    var canScan: Bool { upload != nil && !busy }

    private var validInputs: (Double, Double)? {
        guard let g = Double(grams), g.isFinite, g > 0, g <= 10_000,
              let m = Double(minutes), m.isFinite, m > 0, m <= 525_600,
              PrintRates.fields.allSatisfy({ field in
                  let value = rates[keyPath: field.1]
                  return value.isFinite && value >= 0 && value <= field.2
              }) else { return nil }
        return (g, m)
    }

    var canCalculate: Bool { validInputs != nil && !busy }

    func scan() async {
        guard let upload, !busy else { return }
        busy = true
        message = nil
        result = nil
        // Clear old readings so a failed rescan cannot leave stale OCR values.
        grams = ""
        minutes = ""
        defer { busy = false }
        do {
            let payload = try JSONSerialization.data(withJSONObject: ["image": upload.base64EncodedString(), "content_type": mime])
            let reading: PrintExtraction = try await send(action: "extract", payload: payload)
            grams = String(reading.filamentGrams)
            minutes = String(reading.printTimeMinutes)
            message = "Check these values against the image, then calculate the quote."
        } catch { message = friendlyError(error) }
    }

    func calculate() async {
        guard let (g, m) = validInputs, !busy else { return }
        busy = true
        message = nil
        result = nil
        defer { busy = false }
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let payload = try encoder.encode(PrintQuoteRequest(filamentGrams: g, printTimeMinutes: m, rates: rates))
            result = try await send(action: "calculate", payload: payload)
        } catch { message = friendlyError(error) }
    }

    private func send<T: Decodable>(action: String, payload: Data) async throws -> T {
        let data = try await QuoteHelper.shared.request(action: action, payload: payload)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Dictionary keys in the cost breakdown keep their original snake_case names.
        let response = try decoder.decode(PrintHelperResponse<T>.self, from: data)
        guard response.ok, let result = response.result else {
            throw PrintQuoteError.message(response.error ?? "The quotation could not be processed. Try again.")
        }
        return result
    }

    private func friendlyError(_ error: Error) -> String {
        if error is DecodingError { return "Unexpected OCR response. Rebuild or reinstall the complete application." }
        return error.localizedDescription
    }
}

struct PrintQuoteView: View {
    @StateObject private var model = PrintQuoteModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Print Quote").font(.largeTitle.bold())
                Text("Read filament weight and total print time from a Creality Print screenshot. You can also enter the values manually.")
                    .foregroundStyle(.secondary)
                GroupBox("1. Add a screenshot") {
                    VStack(spacing: 12) {
                        if let image = model.image {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                            Text(model.filename).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.secondary).padding()
                        }
                        HStack {
                            Button("Choose Image…", action: model.chooseImage)
                            Button("Paste Image", action: model.pasteImage)
                            Button("Capture Screen…") { Task { await model.captureScreen() } }
                            Spacer()
                            Button("Scan Image") { Task { await model.scan() } }
                                .disabled(!model.canScan)
                        }
                        Text("PNG, JPEG or WebP, up to 10 MB and 25 megapixels. Include Total filament and Total time; capture just the estimate area if needed.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Capture Screen hides Helm while you select an area or press Space to choose the slicer window. Press Escape to cancel. Paste Image reads an image already on the clipboard.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("2. Review the readings") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Filament (grams)") { TextField("e.g. 25.5", text: $model.grams).frame(width: 150) }
                        LabeledContent("Total print time (minutes)") { TextField("e.g. 120", text: $model.minutes).frame(width: 150) }
                        Text("Confirm the total values, including supports and other print overhead. Use a decimal point for fractional values.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.textFieldStyle(.roundedBorder).padding(8)
                }
                DisclosureGroup("Pricing rates · INR") {
                    VStack(spacing: 10) {
                        ForEach(PrintRates.fields.indices, id: \.self) { index in
                            let field = PrintRates.fields[index]
                            LabeledContent(field.0) {
                                TextField("Rate", value: Binding(
                                    get: { model.rates[keyPath: field.1] },
                                    set: { model.rates[keyPath: field.1] = $0 }
                                ), format: .number)
                                    .frame(width: 150)
                            }
                        }
                        Text("Maintenance, risk, labour and design are percentages of material + machine + electricity. Packaging is added once. Profit is a markup on that manufacturing cost. Rates must be nonnegative; percentages are capped at 1,000%.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.textFieldStyle(.roundedBorder).padding(.top, 10)
                }
                HStack {
                    Button("Calculate Quote") { Task { await model.calculate() } }
                        .buttonStyle(.borderedProminent).disabled(!model.canCalculate)
                    if model.busy { ProgressView().controlSize(.small); Text("Processing…").foregroundStyle(.secondary) }
                }
                if let message = model.message { Text(message).textSelection(.enabled).font(.callout) }
                if let result = model.result {
                    GroupBox("Quotation · \(result.currency)") {
                        VStack(spacing: 8) {
                            cost("Filament", "filament", result)
                            cost("Machine", "machine", result)
                            cost("Electricity", "electricity", result)
                            cost("Base subtotal", "subtotal", result)
                            cost("Maintenance, risk, labour & design", "buffers", result)
                            cost("Packaging", "packaging", result)
                            cost("Manufacturing cost", "manufacturing", result)
                            cost("Profit markup", "profit", result)
                            Divider()
                            cost("Total quote", "final_price", result).font(.title2.bold())
                            Text("Estimate in INR. Taxes and shipping are not included.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                }
                Text("OCR and pricing run on your Mac. Images are not uploaded or saved to quote history.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .disabled(model.busy)
        .frame(minWidth: 620, minHeight: 650)
    }

    private func cost(_ title: String, _ key: String, _ result: PrintQuoteResult) -> some View {
        LabeledContent(title) {
            Text((result.quote[key] ?? 0).formatted(.currency(code: result.currency))).textSelection(.enabled)
        }
    }
}
