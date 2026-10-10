import SwiftUI

struct EndpointFormView: View {
    enum FormResult {
        /// `versionSecret` targets `VersionCheckConfig.secretAccount(for:)`, separate from the
        /// endpoint's own auth secret.
        case save(Endpoint, secret: SecretUpdate, versionSecret: SecretUpdate)
        case cancel
    }

    private static let testTimeout: TimeInterval = 10

    let originalEndpoint: Endpoint?
    let onComplete: (FormResult) -> Void

    @EnvironmentObject var endpointStore: EndpointStore
    @EnvironmentObject var historyStore: HealthHistoryStore

    @State private var name: String
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
    @State private var group: String
    /// Never prefilled from the Keychain — left blank on edit means "keep the existing secret".
    @State private var authSecret: String = ""

    /// Set (Add mode only) when `urlString` matches a `RetainedEndpointRecord` — surfaced as an
    /// info banner near the URL field and, unless dismissed via `ignoreRetainedMatch`, reattached
    /// to the saved endpoint by reusing its `id`.
    @State private var matchedRetainedEndpoint: RetainedEndpointRecord?
    @State private var ignoreRetainedMatch = false

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

    @State private var isAdvancedExpanded: Bool
    @State private var versionDraft: VersionCheckDraft
    @State private var isVersionTesting = false
    @State private var versionTestResult: VersionCheckResult?
    @State private var versionTestFields: [HealthCheckService.FlattenedJSONField] = []

    init(endpoint: Endpoint?, onComplete: @escaping (FormResult) -> Void) {
        self.originalEndpoint = endpoint
        self.onComplete = onComplete
        _name = State(initialValue: endpoint?.name ?? "")
        _urlString = State(initialValue: endpoint?.url.absoluteString ?? "")
        _checkType = State(initialValue: endpoint?.checkType ?? .http)
        _expectedStatusCode = State(initialValue: String(endpoint?.expectedStatusCode ?? 200))
        _useCustomInterval = State(initialValue: endpoint?.checkIntervalOverride != nil)
        _customInterval = State(initialValue: endpoint?.checkIntervalOverride.map { String(Int($0)) } ?? "")
        _assertions = State(initialValue: endpoint?.jsonAssertions ?? [])
        _authType = State(initialValue: endpoint?.authType ?? .none)
        _authUsername = State(initialValue: endpoint?.authUsername ?? "")
        _authHeaderName = State(initialValue: endpoint?.authHeaderName ?? "")
        _group = State(initialValue: endpoint?.group ?? "")
        _versionDraft = State(initialValue: VersionCheckDraft(config: endpoint?.versionCheck))
        // Collapsed by default, but opened when editing an endpoint that already uses it, so the
        // configured feature isn't hidden.
        _isAdvancedExpanded = State(initialValue: endpoint?.versionCheck?.isEnabled == true)
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
                        .accessibilityIdentifier("EndpointNameField")
                    groupField
                    Picker("Check Type", selection: $checkType) {
                        ForEach(CheckType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField(checkType == .tcp ? "Host:Port" : "URL", text: $urlString,
                              prompt: Text(checkType == .tcp ? "tcp://db.example.com:5432" : "https://api.example.com/health"))
                        .accessibilityIdentifier("EndpointURLField")
                    retainedMatchBanner
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
                        assertionRows($assertions)
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

                Section {
                    DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                        advancedSectionContent
                    } label: {
                        // macOS only toggles a DisclosureGroup from its chevron; make the whole
                        // label clickable too, which is where people actually click.
                        Label("Advanced", systemImage: "slider.horizontal.3")
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation { isAdvancedExpanded.toggle() } }
                    }
                    // No accessibilityIdentifier here: on a DisclosureGroup it propagates to every
                    // child and would override the identifiers of the fields inside.
                }
            }
            .formStyle(.grouped)
            .onChange(of: urlString) { _ in updateRetainedMatch() }
            .onAppear { updateRetainedMatch() }

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

    // MARK: - Assertion rows (shared by health and version check)

    @ViewBuilder
    private func assertionRows(_ list: Binding<[JSONAssertion]>) -> some View {
        ForEach(list) { $assertion in
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
                    list.wrappedValue.removeAll { $0.id == assertion.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove assertion")
            }
        }
        Button {
            list.wrappedValue.append(JSONAssertion(path: "", expectedValue: ""))
        } label: {
            Label("Add Assertion", systemImage: "plus")
        }
    }

    // MARK: - Advanced: version check

    @ViewBuilder
    private var advancedSectionContent: some View {
        Toggle("Version check", isOn: $versionDraft.isEnabled)
            .accessibilityIdentifier("VersionCheckToggle")
        Text("Every N health checks, fetch JSON from a separate URL and read a version field from it. Changes are recorded and notified; a failing version check shows a warning but never marks the endpoint down.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if versionDraft.isEnabled {
            TextField("Version URL", text: $versionDraft.urlString, prompt: Text("https://api.example.com/version"))
                .accessibilityIdentifier("VersionURLField")
            TextField("Run every N health checks", text: $versionDraft.everyNChecks, prompt: Text("5"))
                .accessibilityIdentifier("VersionEveryNField")
            TextField("Version field", text: $versionDraft.versionFieldPath, prompt: Text("data.version"))
                .accessibilityIdentifier("VersionFieldPathField")

            Picker("Auth", selection: $versionDraft.authType) {
                ForEach(AuthType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            switch versionDraft.authType {
            case .none:
                EmptyView()
            case .bearerToken:
                SecureField(versionDraft.authType.secretFieldLabel, text: $versionDraft.secret)
            case .basicAuth:
                TextField("Username", text: $versionDraft.authUsername)
                SecureField(versionDraft.authType.secretFieldLabel, text: $versionDraft.secret)
            case .customHeader:
                TextField("Header name", text: $versionDraft.authHeaderName, prompt: Text("X-API-Key"))
                SecureField(versionDraft.authType.secretFieldLabel, text: $versionDraft.secret)
            }
            if versionDraft.authType != .none {
                Text(hasExistingVersionSecret
                    ? "Separate from the endpoint's own auth. Stored in the macOS Keychain — leave blank to keep the current value."
                    : "Separate from the endpoint's own auth. Stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Version assertions (optional, all must match)")
                .font(.caption.bold())
            assertionRows($versionDraft.assertions)

            versionTestContent
        }
    }

    private var hasExistingVersionSecret: Bool {
        guard let original = originalEndpoint?.versionCheck else { return false }
        return original.authType != .none && original.authType == versionDraft.authType
    }

    @ViewBuilder
    private var versionTestContent: some View {
        HStack {
            Button {
                Task { await runVersionTest() }
            } label: {
                if isVersionTesting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Test Version Check")
                }
            }
            .disabled(versionDraft.parsedURL == nil || isVersionTesting)
            .accessibilityIdentifier("VersionTestButton")

            if let versionTestResult {
                if versionTestResult.isSuccess {
                    Label("Version \(versionTestResult.version ?? "?")", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                } else {
                    Label(versionTestResult.failureReason ?? "Failed", systemImage: "xmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
        }

        if !versionTestFields.isEmpty {
            Text("Use a field as the version, or add it as an assertion:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(versionTestFields) { field in
                        HStack {
                            Text(field.path)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(field.value)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Button("Version") { versionDraft.versionFieldPath = field.path }
                                .controlSize(.mini)
                                .accessibilityLabel("Use \(field.path) as version field")
                            Button("Assert") {
                                if let index = versionDraft.assertions.firstIndex(where: { $0.path == field.path }) {
                                    versionDraft.assertions[index].expectedValue = field.value
                                } else {
                                    versionDraft.assertions.append(JSONAssertion(path: field.path, expectedValue: field.value))
                                }
                            }
                            .controlSize(.mini)
                            .accessibilityLabel("Add assertion for \(field.path)")
                        }
                        .disabled(!field.isSelectable)
                        .opacity(field.isSelectable ? 1 : 0.4)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    /// The secret for a live version test: whatever's typed, or the stored one when editing with
    /// the same auth type and the field left blank.
    private var effectiveVersionSecretForTesting: String? {
        let trimmed = versionDraft.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard hasExistingVersionSecret, let originalEndpoint else { return nil }
        return SecretStore.secret(for: VersionCheckConfig.secretAccount(for: originalEndpoint.id))
    }

    private func runVersionTest() async {
        guard let config = versionDraft.testConfig else { return }
        isVersionTesting = true
        defer { isVersionTesting = false }

        let headers = HealthCheckService.authHeaders(type: config.authType, username: config.authUsername,
                                                       secret: effectiveVersionSecretForTesting, headerName: config.authHeaderName)
        switch await HealthCheckService.performRequest(url: config.url, timeout: Self.testTimeout, headers: headers) {
        case .success(let raw):
            let json = try? JSONSerialization.jsonObject(with: raw.data)
            versionTestFields = json.map { HealthCheckService.flatten(json: $0) } ?? []
            if json != nil, config.versionFieldPath.isEmpty {
                versionTestResult = VersionCheckResult(timestamp: Date(), isSuccess: false, version: nil,
                                                       failureReason: "Pick a version field below",
                                                       responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode)
            } else {
                versionTestResult = HealthCheckService.evaluateVersionResponse(raw, config: config)
            }
        case .failure(let error):
            versionTestFields = []
            versionTestResult = VersionCheckResult(timestamp: Date(), isSuccess: false, version: nil,
                                                   failureReason: error.displayMessage, responseTimeMs: error.elapsedMs, statusCode: nil)
        }
    }

    // MARK: - Group

    @ViewBuilder
    private var groupField: some View {
        TextField("Group (optional)", text: $group, prompt: Text("e.g. Production"))
        if !groupSuggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(groupSuggestions, id: \.self) { suggestion in
                        Button { group = suggestion } label: { GroupBadge(name: suggestion) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Existing group names filtered against what's typed; hidden once the field already exactly
    /// matches an existing group.
    private var groupSuggestions: [String] {
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = endpointStore.allGroups
        guard !all.isEmpty else { return [] }
        if trimmed.isEmpty { return all }
        if all.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return [] }
        return all.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    // MARK: - Retained history match (add mode only)

    @ViewBuilder
    private var retainedMatchBanner: some View {
        if let matchedRetainedEndpoint {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Previous history found for this URL — \(retainedRangeDescription(for: matchedRetainedEndpoint))")
                        .font(.caption)
                    Text("Saving will reattach it to this endpoint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Start fresh instead") {
                        ignoreRetainedMatch = true
                        self.matchedRetainedEndpoint = nil
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Looks up a retained-deleted-endpoint match for the current `urlString` (add mode only —
    /// editing an existing endpoint already has its own history under its own id).
    private func updateRetainedMatch() {
        guard originalEndpoint == nil, !ignoreRetainedMatch,
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            matchedRetainedEndpoint = nil
            return
        }
        matchedRetainedEndpoint = endpointStore.matchingRetainedEndpoint(forURL: url)
    }

    private func retainedRangeDescription(for record: RetainedEndpointRecord) -> String {
        let results = historyStore.results(for: record.id)
        guard let first = results.first?.timestamp, let last = results.last?.timestamp else {
            let formatter = RelativeDateTimeFormatter()
            return "deleted \(formatter.localizedString(for: record.deletedAt, relativeTo: Date()))"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return "\(results.count) checks on \(formatter.string(from: first))"
        }
        return "\(results.count) checks, \(formatter.string(from: first)) – \(formatter.string(from: last))"
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
        authType.secretFieldLabel
    }

    private var hasExistingSecret: Bool {
        guard let originalEndpoint, originalEndpoint.authType != .none else { return false }
        return true
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

        let versionOutput: VersionCheckDraft.Output
        switch versionDraft.validate(original: originalEndpoint?.versionCheck) {
        case .success(let output):
            versionOutput = output
        case .failure(let error):
            errorMessage = error.message
            isAdvancedExpanded = true
            return
        }

        var endpoint = originalEndpoint ?? Endpoint(id: matchedRetainedEndpoint?.id ?? UUID(), name: trimmedName, url: url)
        endpoint.versionCheck = versionOutput.config
        endpoint.name = trimmedName
        endpoint.url = url
        endpoint.checkType = checkType
        endpoint.checkIntervalOverride = interval
        let trimmedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint.group = trimmedGroup.isEmpty ? nil : trimmedGroup

        // TCP checks don't use status code / JSON assertions / auth — those are HTTP-only, so
        // saving as .tcp clears them rather than leaving stale HTTP config silently persisted.
        if checkType == .tcp {
            endpoint.jsonAssertions = []
            endpoint.authType = .none
            endpoint.authUsername = nil
            endpoint.authHeaderName = nil
            let secretUpdate: SecretUpdate = hasExistingSecret ? .cleared : .unchanged
            reclaimRetainedMatchIfNeeded()
            onComplete(.save(endpoint, secret: secretUpdate, versionSecret: versionOutput.secretUpdate))
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

        guard let cleanedAssertions = JSONAssertion.cleaned(assertions) else {
            errorMessage = "Each JSON assertion needs both a field path and an expected value"
            return
        }

        endpoint.expectedStatusCode = statusCode
        endpoint.jsonAssertions = cleanedAssertions
        endpoint.authType = authType
        endpoint.authUsername = authType == .basicAuth ? authUsername.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        endpoint.authHeaderName = authType == .customHeader ? authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        reclaimRetainedMatchIfNeeded()
        onComplete(.save(endpoint, secret: secretUpdate, versionSecret: versionOutput.secretUpdate))
    }

    /// Clears the retained record once its history/stats are about to go live again under the
    /// reused id (see `EndpointStore.reclaimRetainedEndpoint`). No-op outside add mode / no match.
    private func reclaimRetainedMatchIfNeeded() {
        guard originalEndpoint == nil, let matchedRetainedEndpoint else { return }
        endpointStore.reclaimRetainedEndpoint(id: matchedRetainedEndpoint.id)
    }
}
