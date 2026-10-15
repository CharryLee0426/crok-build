import XCTest

@testable import Crok

/// The HTTP API envelope and the shapes the Convex functions return (numbers arrive as floats: `2.0`).
final class RelayDecodingTests: XCTestCase {
    func testDecodesASuccessEnvelope() throws {
        let body = Data(
            #"{"status":"success","value":{"deviceCode":"crd_x","expiresAt":1792098432719.0,"interval":2.0,"userCode":"ZPWP-MDQJ","verificationUrl":"http://localhost:3000/link","verificationUrlComplete":"http://localhost:3000/link?code=ZPWP-MDQJ"}}"#
                .utf8)
        let start = try ConvexHTTPResponse.decode(DeviceAuthStart.self, from: body, httpStatus: 200)
        XCTAssertEqual(start.userCode, "ZPWP-MDQJ")
        XCTAssertEqual(start.interval, 2)
        XCTAssertEqual(start.verificationUrlComplete, "http://localhost:3000/link?code=ZPWP-MDQJ")
    }

    func testDecodesAConvexErrorWithItsCode() {
        let body = Data(
            #"{"status":"error","errorMessage":"[Request ID: ddfc190565c96c65] Server Error\nUncaught ConvexError: {\"code\":\"REVOKED\",\"message\":\"This device was signed out.\"}\n    at fail (../../convex/lib/auth.ts:18:0)","errorData":{"code":"REVOKED","message":"This device was signed out."}}"#
                .utf8)
        XCTAssertThrowsError(try ConvexHTTPResponse.decode(DeviceAccessToken.self, from: body, httpStatus: 400)) { error in
            XCTAssertEqual(error as? RelayError, RelayError(.revoked, "This device was signed out."))
            XCTAssertTrue((error as? RelayError)?.isRevoked ?? false)
        }
    }

    func testAServerErrorWithoutDataKeepsOnlyTheFirstLine() {
        let body = Data(
            #"{"status":"error","errorMessage":"[Request ID: 9b7e390d488077f9] Server Error\nArgumentValidationError: Value does not match validator.\nPath: .deviceCode"}"#
                .utf8)
        XCTAssertThrowsError(try ConvexHTTPResponse.decode(DeviceAuthPoll.self, from: body, httpStatus: 400)) { error in
            let relayError = error as? RelayError
            XCTAssertEqual(relayError?.code, .server)
            XCTAssertFalse(relayError?.message.contains("Request ID") ?? true)
        }
    }

    func testANonRelayResponseIsReported() {
        XCTAssertThrowsError(try ConvexHTTPResponse.decode(Nothing.self, from: Data("<html>".utf8), httpStatus: 404)) { error in
            XCTAssertEqual((error as? RelayError)?.code, .notConfigured)
        }
    }

    func testARejectedRequestKeepsConvexsReason() {
        let body = Data(
            #"{"code":"InvalidClientVersion","message":"Failed to parse client version string: 'Crok iOS 1.0 (1)'."}"#.utf8)
        XCTAssertThrowsError(try ConvexHTTPResponse.decode(DeviceAuthStart.self, from: body, httpStatus: 400)) { error in
            XCTAssertEqual((error as? RelayError)?.code, .server)
            XCTAssertTrue((error as? RelayError)?.message.hasPrefix("InvalidClientVersion") ?? false)
        }
    }

    func testTheConvexClientHeaderIsNameDashSemver() {
        XCTAssertEqual(AppInfo.convexClientHeader(version: "1.0"), "crok-ios-1.0.0")
        XCTAssertEqual(AppInfo.convexClientHeader(version: "2"), "crok-ios-2.0.0")
        XCTAssertEqual(AppInfo.convexClientHeader(version: "1.2.3.4"), "crok-ios-1.2.3")
        XCTAssertEqual(AppInfo.convexClientHeader(version: "1.5b"), "crok-ios-1.5.0")
    }

    func testNullValueDecodesAsNothing() throws {
        let body = Data(#"{"status":"success","value":null}"#.utf8)
        XCTAssertEqual(try ConvexHTTPResponse.decode(Nothing.self, from: body, httpStatus: 200), Nothing())
    }

    func testPollResults() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(DeviceAuthPoll.self, from: Data(#"{"status":"pending"}"#.utf8)), .pending)
        XCTAssertEqual(try decoder.decode(DeviceAuthPoll.self, from: Data(#"{"status":"denied"}"#.utf8)), .denied)
        let approved = try decoder.decode(
            DeviceAuthPoll.self,
            from: Data(
                #"{"status":"approved","deviceId":"k57abc","refreshToken":"crr_1","accessToken":"a.b.c","accessTokenExpiresAt":1792098432719.0,"user":{"name":"Ada","email":null,"imageUrl":null}}"#
                    .utf8))
        guard case .approved(let approval) = approved else { return XCTFail("expected approved") }
        XCTAssertEqual(approval.refreshToken, "crr_1")
        XCTAssertEqual(approval.user.name, "Ada")
        XCTAssertNil(approval.user.email)
    }

    func testConvexErrorDataFromTheWebSocketClient() {
        XCTAssertEqual(
            RelayError.fromConvexData(#"{"code":"OFFLINE","message":"This session is not running on its computer right now."}"#).code,
            .offline)
        XCTAssertEqual(RelayError.fromConvexData(#""plain text""#), RelayError(.server, "plain text"))
        XCTAssertEqual(RelayError.fromConvexData(#"{"code":"SOMETHING_NEW","message":"m"}"#).code, .server)
    }

    func testSessionRowDecodesFloatsAndIds() throws {
        let json = #"""
            [{"_id":"jd7abc","sessionId":"0199e2e0","title":"Fix it","cwd":"/Users/me/src/crok-build","model":null,
              "status":"running","online":true,"app":"tui","deviceId":"k57x","deviceName":"MacBook Pro","deviceOnline":true,
              "preview":"Looking","previewKind":"assistant","lastActivityAt":1792098432719.0,"pinned":false,"archived":false,
              "unread":2.0,"plan":{"done":3.0,"total":7.0}}]
            """#
        let rows = try JSONDecoder().decode([SessionRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.first?.id, "jd7abc")
        XCTAssertEqual(rows.first?.unreadCount, 2)
        XCTAssertEqual(rows.first?.folderName, "crok-build")
        XCTAssertEqual(rows.first?.isRunning, true)
        XCTAssertNil(rows.first?.model)
        XCTAssertEqual(rows.first?.plan, PlanProgress(done: 3, total: 7))
    }

    func testInfoResultAcceptsNestedOrFlatUsage() throws {
        let nested = try JSONDecoder().decode(
            SessionInfoResult.self,
            from: Data(
                #"{"model":"grok-code","usage":{"inputTokens":1200.0,"costUsd":0.01},"context":{"used":5000.0,"window":256000.0},"createdAt":"2026-10-15T10:00:00Z"}"#
                    .utf8))
        XCTAssertEqual(nested.usage?.inputTokens, 1200)
        XCTAssertEqual(nested.contextUsed, 5000)
        XCTAssertEqual(nested.contextWindow, 256000)
        XCTAssertNotNil(nested.createdAt)

        let flat = try JSONDecoder().decode(
            SessionInfoResult.self, from: Data(#"{"model":"grok-code","inputTokens":1200,"costUsd":0.01}"#.utf8))
        XCTAssertEqual(flat.model, "grok-code")
        XCTAssertEqual(flat.usage?.inputTokens, 1200)
        XCTAssertEqual(flat.usage?.costUsd, 0.01)
    }

    func testForSessionRowsCarryMine() throws {
        let rows = try JSONDecoder().decode(
            [PromptCommand].self,
            from: Data(
                #"[{"_id":"c1","clientId":"x","text":"hi","status":"delivered","error":null,"fromLabel":"Web","fromDeviceId":null,"mine":false,"createdAt":1.0,"updatedAt":2.0},{"_id":"c2","clientId":null,"text":"yo","status":"done","error":null,"fromLabel":"iPhone","createdAt":1.0,"updatedAt":2.0}]"#
                    .utf8))
        XCTAssertEqual(rows[0].isMine, false)
        XCTAssertNil(rows[0].fromDeviceId)
        XCTAssertEqual(rows[1].isMine, true, "an older relay without `mine`")
    }

    func testEventsCarryTheSendersLabel() throws {
        let event = try JSONDecoder().decode(
            TranscriptEvent.self,
            from: Data(
                #"{"_id":"e1","seq":4.0,"key":"u2","kind":"user","text":"Run it","origin":"remote","commandId":"c1","fromLabel":"Charlie's iPhone","at":1792098432719.0}"#
                    .utf8))
        XCTAssertEqual(event.fromLabel, "Charlie's iPhone")
        XCTAssertTrue(event.isRemote)
    }

    func testCommandRecordToleratesAnyResult() throws {
        let record = try JSONDecoder().decode(
            CommandRecord.self, from: Data(#"{"_id":"c1","type":"info","status":"done","result":"not an object"}"#.utf8))
        XCTAssertEqual(record.status, .done)
        XCTAssertNil(record.result)
    }
}
