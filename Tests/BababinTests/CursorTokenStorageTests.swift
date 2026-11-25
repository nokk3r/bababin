import XCTest
@testable import Bababin

final class CursorTokenStorageTests: XCTestCase {
    func testPlaintextTokenPassesThrough() {
        let token = "eyJhbGciOiJIUzI1NiJ9.payload.sig"
        XCTAssertEqual(try CursorTokenStorage.resolve(token).get(), token)
    }

    func testSealedTokenRoundTrips() throws {
        let token = "eyJhbGciOiJIUzI1NiJ9.payload.signature"
        let sealed = try XCTUnwrap(CursorTokenStorage.seal(token, password: "cursor-safe-storage-password"))
        XCTAssertTrue(sealed.hasPrefix(CursorTokenStorage.sealedPrefix))
        XCTAssertEqual(CursorTokenStorage.unwrap(sealed, password: "cursor-safe-storage-password"), token)
        XCTAssertNil(CursorTokenStorage.unwrap(sealed, password: "wrong-password"))
    }

    func testMissingToken() {
        XCTAssertEqual(CursorTokenStorage.resolve(nil), .failure(.noToken))
        XCTAssertEqual(CursorTokenStorage.resolve(""), .failure(.noToken))
    }

    func testEpochMillisAcceptsLegacyAndRFC3339() {
        XCTAssertEqual(UsageSnapshot.epochMillis(from: "1700000000000"), 1_700_000_000_000, accuracy: 0.001)
        XCTAssertEqual(UsageSnapshot.epochMillis(from: "1700000000"), 1_700_000_000_000, accuracy: 0.001)
        let millis = UsageSnapshot.epochMillis(from: "2026-10-18T06:32:13.504Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: millis / 1000)
        XCTAssertEqual(calendar.component(.year, from: date), 2026)
        XCTAssertEqual(calendar.component(.month, from: date), 10)
        XCTAssertEqual(calendar.component(.day, from: date), 18)
        XCTAssertEqual(calendar.component(.hour, from: date), 6)
        XCTAssertEqual(calendar.component(.minute, from: date), 32)
        XCTAssertEqual(UsageSnapshot.epochMillis(from: nil), 0, accuracy: 0.001)
    }

    func testUsageResponseDecodesStringAndNumericFields() throws {
        let json = """
        {
          "billingCycleStart": "2026-10-18T06:32:13.504Z",
          "billingCycleEnd": 1792287133504,
          "planUsage": {
            "totalPercentUsed": "12.5",
            "autoPercentUsed": 10,
            "apiPercentUsed": 2.5
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PeriodUsageResponse.self, from: json)
        XCTAssertEqual(decoded.billingCycleStart, "2026-10-18T06:32:13.504Z")
        XCTAssertEqual(decoded.billingCycleEnd, "1792287133504")
        XCTAssertEqual(decoded.planUsage?.totalPercentUsed ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(decoded.planUsage?.autoPercentUsed ?? 0, 10, accuracy: 0.001)
    }
}
