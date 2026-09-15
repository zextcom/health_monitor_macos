import XCTest
import UserNotifications
@testable import ProjeHealthMonitor

private final class MockNotificationCenter: UserNotificationCentering, @unchecked Sendable {
    var statusToReturn: UNAuthorizationStatus = .notDetermined
    var requestAuthorizationResult: Result<Bool, Error> = .success(true)

    private(set) var authorizationStatusCallCount = 0
    private(set) var requestAuthorizationCallCount = 0
    private(set) var requestedOptions: UNAuthorizationOptions?
    private(set) var addedRequests: [UNNotificationRequest] = []

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusCallCount += 1
        return statusToReturn
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestAuthorizationCallCount += 1
        requestedOptions = options
        return try requestAuthorizationResult.get()
    }

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }
}

final class NotificationServiceTests: XCTestCase {
    private var center: MockNotificationCenter!
    private var service: NotificationService!

    override func setUp() {
        super.setUp()
        center = MockNotificationCenter()
        service = NotificationService(center: center)
    }

    override func tearDown() {
        center = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Authorization

    func testRequestAuthorizationIfNeededRequestsWhenNotDetermined() async {
        center.statusToReturn = .notDetermined
        await service.requestAuthorizationIfNeededAsync()
        XCTAssertEqual(center.requestAuthorizationCallCount, 1)
        XCTAssertEqual(center.requestedOptions, [.alert, .sound])
    }

    func testRequestAuthorizationIfNeededSkipsWhenAlreadyAuthorized() async {
        center.statusToReturn = .authorized
        await service.requestAuthorizationIfNeededAsync()
        XCTAssertEqual(center.requestAuthorizationCallCount, 0)
    }

    func testRequestAuthorizationIfNeededSkipsWhenDenied() async {
        center.statusToReturn = .denied
        await service.requestAuthorizationIfNeededAsync()
        XCTAssertEqual(center.requestAuthorizationCallCount, 0)
    }

    func testRequestAuthorizationIfNeededSwallowsFailure() async {
        center.statusToReturn = .notDetermined
        center.requestAuthorizationResult = .failure(URLError(.unknown))
        await service.requestAuthorizationIfNeededAsync()
        XCTAssertEqual(center.requestAuthorizationCallCount, 1)
    }

    // MARK: - notifyDown

    func testNotifyDownUsesFailureReasonAsBody() async {
        await service.notifyDownAsync(endpointName: "API", reason: "Connection refused")
        XCTAssertEqual(center.addedRequests.count, 1)
        let content = center.addedRequests[0].content
        XCTAssertEqual(content.title, "API down!")
        XCTAssertEqual(content.body, "Connection refused")
    }

    func testNotifyDownFallsBackToDefaultBodyWhenReasonIsNil() async {
        await service.notifyDownAsync(endpointName: "API", reason: nil)
        XCTAssertEqual(center.addedRequests[0].content.body, "Health check failed.")
    }

    // MARK: - notifyRecovered

    func testNotifyRecoveredSetsTitleAndBody() async {
        await service.notifyRecoveredAsync(endpointName: "API")
        let content = center.addedRequests[0].content
        XCTAssertEqual(content.title, "API is back up")
        XCTAssertEqual(content.body, "Health check succeeded again.")
    }

    // MARK: - notifyCertificateExpiringSoon

    func testNotifyCertificateExpiringSoonUsesPluralDaysWording() async {
        await service.notifyCertificateExpiringSoonAsync(endpointName: "API", daysRemaining: 5)
        XCTAssertEqual(center.addedRequests[0].content.body, "TLS certificate expires in 5 days.")
    }

    func testNotifyCertificateExpiringSoonUsesSingularDayWording() async {
        await service.notifyCertificateExpiringSoonAsync(endpointName: "API", daysRemaining: 1)
        XCTAssertEqual(center.addedRequests[0].content.body, "TLS certificate expires in 1 day.")
    }

    func testNotifyCertificateExpiringSoonReportsAlreadyExpired() async {
        await service.notifyCertificateExpiringSoonAsync(endpointName: "API", daysRemaining: -1)
        XCTAssertEqual(center.addedRequests[0].content.body, "TLS certificate has expired.")
    }
}
