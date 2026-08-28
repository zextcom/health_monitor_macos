import SwiftUI

struct EndpointFormView: View {
    enum SecretUpdate {
        case unchanged
        case set(String)
        case cleared
    }

    enum FormResult {
        case save(Endpoint, secret: SecretUpdate)
        case cancel
    }

    private static let testTimeout: TimeInterval = 10

    let originalEndpoint: Endpoint?
    let suggestedGroupNames: [String]
    let onComplete: (FormResult) -> Void

    @State private var name: String
    @State private var groupName: String
    @State private var urlString: String
    @State private var checkType: CheckType
    @State private var expectedStatusCode: String
    @State private var useCustomInterval: Bool
    @State private var customInterval: String
    @State private var assertions: [JSONAssertion]
    @State private var errorMessage: String?

    @State private var authType: AuthType
    @State private var authUsername: String
    @State private var authHeaderName: String
    /// Never prefilled from the Keychain — left blank on edit means "keep the existing secret".
    @State private var authSecret: String = ""

    @State private var isTesting = false
    @State private var testStatusCode: Int?
    @State private var testElapsedMs: Int?
    @State private var testJSON: Any?
    @State private var testFlattenedFields: [HealthCheckService.FlattenedJSONField] = []
    @State private var testIsJSON = false
    @State private var testErrorMessage: String?
    @State private var testCertificateExpiresAt: Date?
    /// Set only for `.tcp` test runs — `nil` while `.http` or before any test has run.
    @State private var testTCPConnected: Bool?

    init(endpoint: Endpoint?, suggestedGroupNames: [String] = [], onComplete: @escaping (FormResult) -> Void) {
        self.originalEndpoint = endpoint
        self.suggestedGroupNames = EndpointGrouping.normalizedGroupNames(from: suggestedGroupNames)
        self.onComplete = onComplete
        _name = State(initialValue: endpoint?.name ?? "")
        _groupName = State(initialValue: endpoint?.groupName ?? "")
        _urlString = State(initialValue: endpoint?.url.absoluteString ?? "")
        _checkType = State(initialValue: endpoint?.checkType ?? .http)
        _expectedStatusCode = State(initialValue: String(endpoint?.expectedStatusCode ?? 200))
        _useCustomInterval = State(initialValue: endpoint?.checkIntervalOverride != nil)
        _customInterval = State(initialValue: endpoint?.checkIntervalOverride.map { String(Int($0)) } ?? "")
        _assertions = State(initialValue: endpoint?.jsonAssertions ?? [])
        _authType = State(initialValue: endpoint?.authType ?? .none)
        _authUsername = State(initialValue: endpoint?.authUsername ?? "")
        _authHeaderName = State(initialValue: endpoint?.authHeaderName ?? "")
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
                    TextField("Group", text: $groupName, prompt: Text("Optional"))
                    Text("Optional. Leave blank to keep this endpoint ungrouped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !availableGroupSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Existing groups")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(availableGroupSuggestions, id: \.self) { suggestion in
                                        Button(suggestion) {
                                            groupName = suggestion
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(.vertical, 1)
                            }
                        }
                    }
                    Picker("Check Type", selection: $checkType) {
                        ForEach(CheckType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField(checkType == .tcp ? "Host:Port" : "URL", text: $urlString,
                              prompt: Text(checkType == .tcp ? "tcp://db.example.com:5432" : "https://api.example.com/health"))
                    if checkType == .http {
                        TextField("Expected HTTP status code", text: $expectedStatusCode)
                    }
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

                if checkType == .http {
                    Section {
                        authSectionContent
                    } header: {
                        Label("Authentication", systemImage: "key")
                    }
                }

                Section {
                    testSectionContent
                } header: {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                }

                if checkType == .http {
                    Section {
                        ForEach($assertions) { $assertion in
                            HStack {
                                TextField("JSON field", text: $assertion.path, prompt: Text("data.status"))
                                TextField("Expected value", text: $assertion.expectedValue, prompt: Text("healthy"))
                                Picker("", selection: $assertion.matchMode) {
                                    ForEach(MatchMode.allCases) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 100)
                                .labelsHidden()
                                Button {
                                    assertions.removeAll { $0.id == assertion.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove assertion")
                            }
                        }
                        Button {
                            assertions.append(JSONAssertion(path: "", expectedValue: ""))
                        } label: {
                            Label("Add Assertion", systemImage: "plus")
                        }
                        Text("All assertions below must match (AND) for the endpoint to be considered healthy. Leave the list empty to check only the HTTP status code. A dot-separated field path is looked up in the JSON body, e.g. data.status. Match mode controls how the expected value is compared: Exact (trimmed, case-insensitive equality), Contains (substring), or Regex (pattern match; an invalid pattern never matches).")
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
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 640, minHeight: 480, idealHeight: 680, maxHeight: 820)
    }

    // MARK: - Authentication section

    @ViewBuilder
    private var authSectionContent: some View {
        Picker("Type", selection: $authType) {
            ForEach(AuthType.allCases) { type in
                Text(type.displayName).tag(type)
            }
        }

        switch authType {
        case .none:
            EmptyView()
        case .bearerToken:
            SecureField(secretPlaceholder, text: $authSecret)
        case .basicAuth:
            TextField("Username", text: $authUsername)
            SecureField(secretPlaceholder, text: $authSecret)
        case .customHeader:
            TextField("Header name", text: $authHeaderName, prompt: Text("X-API-Key"))
            SecureField(secretPlaceholder, text: $authSecret)
        }

        if authType != .none {
            Text(hasExistingSecret
                ? "Stored in the macOS Keychain. Leave blank to keep the current value."
                : "Stored in the macOS Keychain, never in plain-text settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var secretPlaceholder: String {
        switch authType {
        case .none: return ""
        case .bearerToken: return "Token"
        case .basicAuth: return "Password"
        case .customHeader: return "Header value"
        }
    }

    private var hasExistingSecret: Bool {
        guard let originalEndpoint, originalEndpoint.authType != .none else { return false }
        return true
    }

    private var availableGroupSuggestions: [String] {
        EndpointGrouping.suggestedGroupNames(from: suggestedGroupNames, excluding: groupName)
    }

    /// The secret to use for a live "Test Connection" request: whatever's currently typed, or —
    /// for an existing endpoint left blank — the value already stored in the Keychain.
    private var effectiveSecretForTesting: String? {
        let trimmed = authSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let originalEndpoint, originalEndpoint.authType != .none {
            return SecretStore.secret(for: originalEndpoint.id.uuidString)
        }
        return nil
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

            if checkType == .tcp {
                if let testTCPConnected, let testElapsedMs {
                    Text(testTCPConnected ? "Connected · \(testElapsedMs) ms" : "Failed · \(testElapsedMs) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let testStatusCode, let testElapsedMs {
                Text("Status \(testStatusCode) · \(testElapsedMs) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        if checkType == .tcp {
            if let testErrorMessage {
                Text(testErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } else {
            if let testCertificateExpiresAt {
                Label(certificateStatusText(for: testCertificateExpiresAt), systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(certificateStatusColor(for: testCertificateExpiresAt))
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
                                if let index = assertions.firstIndex(where: { $0.path == field.path }) {
                                    assertions[index].expectedValue = field.value
                                } else {
                                    assertions.append(JSONAssertion(path: field.path, expectedValue: field.value))
                                }
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
    }

    private var isURLValid: Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            return false
        }
        if checkType == .tcp {
            return url.host != nil && url.port != nil
        }
        return true
    }

    /// Returns (label, symbol, color) describing whether the current assertions would evaluate as
    /// healthy against the last test response, without firing a new request.
    private var livePreview: (String, String, Color)? {
        let nonBlank = assertions.filter { !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let testJSON, !nonBlank.isEmpty else { return nil }
        let (passed, reason) = HealthCheckService.evaluateAssertions(json: testJSON, assertions: nonBlank)
        return passed
            ? ("Would currently evaluate as Healthy", "checkmark.circle.fill", .green)
            : ("Would currently evaluate as Down (\(reason ?? "assertion failed"))", "xmark.circle.fill", .red)
    }

    private func runTest() async {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            testErrorMessage = "Enter a valid URL first"
            return
        }

        if checkType == .tcp {
            await runTCPTest(url: url)
            return
        }

        isTesting = true
        testErrorMessage = nil
        testCertificateExpiresAt = nil
        defer { isTesting = false }

        let headers = HealthCheckService.authHeaders(type: authType, username: authUsername,
                                                       secret: effectiveSecretForTesting, headerName: authHeaderName)

        switch await HealthCheckService.performRequest(url: url, timeout: Self.testTimeout, headers: headers) {
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
            if url.scheme?.lowercased() == "https", let host = url.host {
                testCertificateExpiresAt = await HealthCheckService.fetchCertificateExpiry(
                    host: host, port: UInt16(url.port ?? 443), timeout: Self.testTimeout)
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

    private func runTCPTest(url: URL) async {
        guard let host = url.host, let port = url.port, let nwPort = UInt16(exactly: port) else {
            testErrorMessage = "Enter a valid host:port, e.g. tcp://db.example.com:5432"
            return
        }
        isTesting = true
        testErrorMessage = nil
        testTCPConnected = nil
        defer { isTesting = false }

        let result = await HealthCheckService.performTCPConnect(host: host, port: nwPort, timeout: Self.testTimeout)
        testTCPConnected = result.success
        testElapsedMs = result.elapsedMs
        testErrorMessage = result.success ? nil : (result.errorMessage ?? "Connection failed")
    }

    private func certificateStatusText(for expiry: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let days = HealthCheckService.daysUntilExpiry(expiry)
        let dateText = formatter.string(from: expiry)
        return days >= 0 ? "Certificate valid until \(dateText) (\(days)d)" : "Certificate expired \(dateText)"
    }

    private func certificateStatusColor(for expiry: Date) -> Color {
        HealthCheckService.isExpiringSoon(expiry, thresholdDays: 14) ? .orange : .secondary
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
            errorMessage = checkType == .tcp ? "Enter a valid host:port, e.g. tcp://db.example.com:5432" : "Enter a valid URL"
            return
        }
        if checkType == .tcp, url.host == nil || url.port == nil {
            errorMessage = "Enter a valid host:port, e.g. tcp://db.example.com:5432"
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
        let trimmedGroupName = EndpointGrouping.normalizedGroupName(groupName)

        var endpoint = originalEndpoint ?? Endpoint(name: trimmedName, url: url)
        endpoint.name = trimmedName
        endpoint.url = url
        endpoint.checkType = checkType
        endpoint.checkIntervalOverride = interval
        endpoint.groupName = trimmedGroupName

        // TCP checks don't use status code / JSON assertions / auth — those are HTTP-only, so
        // saving as .tcp clears them rather than leaving stale HTTP config silently persisted.
        if checkType == .tcp {
            endpoint.jsonAssertions = []
            endpoint.authType = .none
            endpoint.authUsername = nil
            endpoint.authHeaderName = nil
            let secretUpdate: SecretUpdate = hasExistingSecret ? .cleared : .unchanged
            onComplete(.save(endpoint, secret: secretUpdate))
            return
        }

        guard let statusCode = Int(expectedStatusCode) else {
            errorMessage = "Status code must be a number"
            return
        }
        if authType == .customHeader, authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "Enter a header name for custom header auth"
            return
        }

        let trimmedSecret = authSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretUpdate: SecretUpdate
        if authType == .none {
            secretUpdate = hasExistingSecret ? .cleared : .unchanged
        } else if !trimmedSecret.isEmpty {
            secretUpdate = .set(trimmedSecret)
        } else if originalEndpoint == nil || originalEndpoint?.authType != authType {
            errorMessage = "Enter a value for \(secretPlaceholder.lowercased())"
            return
        } else {
            secretUpdate = .unchanged // editing, left blank, auth type unchanged: keep existing secret
        }

        var cleanedAssertions: [JSONAssertion] = []
        for assertion in assertions {
            let path = assertion.path.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = assertion.expectedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty, value.isEmpty { continue } // fully blank row, drop silently
            guard !path.isEmpty, !value.isEmpty else {
                errorMessage = "Each JSON assertion needs both a field path and an expected value"
                return
            }
            cleanedAssertions.append(JSONAssertion(id: assertion.id, path: path, expectedValue: value, matchMode: assertion.matchMode))
        }

        endpoint.expectedStatusCode = statusCode
        endpoint.jsonAssertions = cleanedAssertions
        endpoint.authType = authType
        endpoint.authUsername = authType == .basicAuth ? authUsername.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        endpoint.authHeaderName = authType == .customHeader ? authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        onComplete(.save(endpoint, secret: secretUpdate))
    }
}
