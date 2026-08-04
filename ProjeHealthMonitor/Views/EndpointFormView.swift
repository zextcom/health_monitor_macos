import SwiftUI

struct EndpointFormView: View {
    enum FormResult {
        case save(Endpoint)
        case cancel
    }

    private static let testTimeout: TimeInterval = 10

    let originalEndpoint: Endpoint?
    let onComplete: (FormResult) -> Void

    @State private var name: String
    @State private var urlString: String
    @State private var expectedStatusCode: String
    @State private var useCustomInterval: Bool
    @State private var customInterval: String
    @State private var jsonFieldPath: String
    @State private var expectedFieldValue: String
    @State private var errorMessage: String?

    @State private var isTesting = false
    @State private var testStatusCode: Int?
    @State private var testElapsedMs: Int?
    @State private var testJSON: Any?
    @State private var testFlattenedFields: [HealthCheckService.FlattenedJSONField] = []
    @State private var testIsJSON = false
    @State private var testErrorMessage: String?

    init(endpoint: Endpoint?, onComplete: @escaping (FormResult) -> Void) {
        self.originalEndpoint = endpoint
        self.onComplete = onComplete
        _name = State(initialValue: endpoint?.name ?? "")
        _urlString = State(initialValue: endpoint?.url.absoluteString ?? "")
        _expectedStatusCode = State(initialValue: String(endpoint?.expectedStatusCode ?? 200))
        _useCustomInterval = State(initialValue: endpoint?.checkIntervalOverride != nil)
        _customInterval = State(initialValue: endpoint?.checkIntervalOverride.map { String(Int($0)) } ?? "")
        _jsonFieldPath = State(initialValue: endpoint?.jsonFieldPath ?? "")
        _expectedFieldValue = State(initialValue: endpoint?.expectedFieldValue ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(originalEndpoint == nil ? "Add Endpoint" : "Edit Endpoint")
                .font(.title3.bold())
                .padding([.top, .horizontal])
                .padding(.bottom, 8)

            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("URL", text: $urlString, prompt: Text("https://api.example.com/health"))
                    TextField("Expected HTTP status code", text: $expectedStatusCode)
                } header: {
                    Label("Details", systemImage: "info.circle")
                }

                Section {
                    Toggle("Use custom check interval for this endpoint", isOn: $useCustomInterval)
                    if useCustomInterval {
                        TextField("Interval (seconds)", text: $customInterval)
                    }
                } header: {
                    Label("Check Interval", systemImage: "clock")
                }

                Section {
                    testSectionContent
                } header: {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                }

                Section {
                    TextField("JSON field", text: $jsonFieldPath, prompt: Text("data.status"))
                    TextField("Expected value", text: $expectedFieldValue, prompt: Text("healthy"))
                    Text("Leave blank to check only the HTTP status code. A dot-separated field path is looked up in the JSON body, e.g. data.status.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let evaluation = livePreview {
                        Label(evaluation.0, systemImage: evaluation.1)
                            .font(.caption.bold())
                            .foregroundStyle(evaluation.2)
                    }
                } header: {
                    Label("JSON Field Match (optional)", systemImage: "curlybraces")
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            HStack {
                Spacer()
                Button("Cancel") { onComplete(.cancel) }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 640, minHeight: 480, idealHeight: 640, maxHeight: 780)
    }

    // MARK: - Test Connection section

    @ViewBuilder
    private var testSectionContent: some View {
        HStack {
            Button {
                Task { await runTest() }
            } label: {
                if isTesting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Test")
                }
            }
            .disabled(!isURLValid || isTesting)
            .accessibilityLabel(isTesting ? "Testing connection" : "Test connection")

            if let testStatusCode, let testElapsedMs {
                Text("Status \(testStatusCode) · \(testElapsedMs) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        if let testErrorMessage {
            Text(testErrorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        } else if testStatusCode != nil, !testIsJSON {
            Text("Response is not JSON — only HTTP status code matching is available for this endpoint.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !testFlattenedFields.isEmpty {
            Text("Tap a field to use it as the JSON match:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(testFlattenedFields) { field in
                        Button {
                            jsonFieldPath = field.path
                            expectedFieldValue = field.value
                        } label: {
                            HStack {
                                Text(field.path)
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                                Text(field.value)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!field.isSelectable)
                        .opacity(field.isSelectable ? 1 : 0.4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(field.isSelectable
                            ? "\(field.path), value \(field.value)"
                            : "\(field.path), \(field.value), not selectable")
                        .accessibilityAddTraits(field.isSelectable ? [.isButton] : [])
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private var isURLValid: Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme != nil
    }

    /// Returns (label, symbol, color) describing whether the current jsonFieldPath/expectedFieldValue
    /// would evaluate as healthy against the last test response, without firing a new request.
    private var livePreview: (String, String, Color)? {
        guard let testJSON,
              !jsonFieldPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let actualValue = HealthCheckService.extractValue(from: testJSON, path: jsonFieldPath.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        let matches = HealthCheckService.evaluate(actualValue: actualValue, expectedValue: expectedFieldValue)
        return matches
            ? ("Would currently evaluate as Healthy", "checkmark.circle.fill", .green)
            : ("Would currently evaluate as Down (\(actualValue))", "xmark.circle.fill", .red)
    }

    private func runTest() async {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            testErrorMessage = "Enter a valid URL first"
            return
        }
        isTesting = true
        testErrorMessage = nil
        defer { isTesting = false }

        switch await HealthCheckService.performRequest(url: url, timeout: Self.testTimeout) {
        case .success(let raw):
            testStatusCode = raw.statusCode
            testElapsedMs = raw.elapsedMs
            if let json = try? JSONSerialization.jsonObject(with: raw.data) {
                testJSON = json
                testIsJSON = true
                testFlattenedFields = HealthCheckService.flatten(json: json)
            } else {
                testJSON = nil
                testIsJSON = false
                testFlattenedFields = []
            }
        case .failure(let error):
            testStatusCode = nil
            testElapsedMs = nil
            testJSON = nil
            testIsJSON = false
            testFlattenedFields = []
            testErrorMessage = error.displayMessage
        }
    }

    // MARK: - Save

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Name cannot be empty"
            return
        }
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil else {
            errorMessage = "Enter a valid URL"
            return
        }
        guard let statusCode = Int(expectedStatusCode) else {
            errorMessage = "Status code must be a number"
            return
        }
        var interval: TimeInterval?
        if useCustomInterval {
            guard let seconds = TimeInterval(customInterval), seconds > 0 else {
                errorMessage = "Enter a valid interval"
                return
            }
            interval = seconds
        }

        let trimmedPath = jsonFieldPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = expectedFieldValue.trimmingCharacters(in: .whitespacesAndNewlines)

        var endpoint = originalEndpoint ?? Endpoint(name: trimmedName, url: url)
        endpoint.name = trimmedName
        endpoint.url = url
        endpoint.expectedStatusCode = statusCode
        endpoint.checkIntervalOverride = interval
        endpoint.jsonFieldPath = trimmedPath.isEmpty ? nil : trimmedPath
        endpoint.expectedFieldValue = trimmedValue.isEmpty ? nil : trimmedValue

        onComplete(.save(endpoint))
    }
}
