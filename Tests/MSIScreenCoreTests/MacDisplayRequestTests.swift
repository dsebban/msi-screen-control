import XCTest
@testable import MSIScreenCore

final class MacDisplayRequestTests: XCTestCase {
    func testRemoteMainRequestRoundtripsTheExpectedStateAndTarget() throws {
        let state = MacDisplayState(computerName: "Test Mac", displays: [])
        let request = try MacDisplayRequest(action: .main, expected: state, target: .monitor)
        let decoded = try JSONDecoder().decode(MacDisplayRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
    }

    func testRequestRejectsUnknownFieldsVersionsAndMissingRequiredState() {
        let invalid = [
            #"{"schemaVersion":1,"action":"status","command":"anything"}"#,
            #"{"schemaVersion":2,"action":"status"}"#,
            #"{"action":"status"}"#,
            #"{"schemaVersion":1,"action":"main","target":"monitor"}"#,
            #"{"schemaVersion":1,"action":"main","expected":null,"target":"monitor"}"#,
            #"{"schemaVersion":1,"action":"main","expected":{"computerName":"Test","displays":[]},"target":null}"#,
            #"{"schemaVersion":1,"action":"status","expected":null}"#,
            #"{"schemaVersion":1,"action":"status","target":"monitor"}"#,
            #"{"schemaVersion":1,"action":"arrange","laptopPosition":"right"}"#,
            #"{"schemaVersion":1,"action":"arrange","expected":{"computerName":"Test","displays":[]},"laptopPosition":"right","target":"monitor"}"#
        ]
        for json in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(MacDisplayRequest.self, from: Data(json.utf8)), json)
        }
    }

    func testArrangeRequestCarriesExpectedStateWithoutChangingMainRole() throws {
        let request = try MacDisplayRequest(action: .arrange,
            expected: MacDisplayState(computerName: "Test Mac", displays: []), laptopPosition: .right)
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(MacDisplayRequest.self, from: encoded), request)
        XCTAssertThrowsError(try MacDisplayRequest(action: .arrange, expected: request.expected,
                                                   target: .monitor, laptopPosition: .right))
    }
}
