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

    /// `sessions:groups` as relay/convex/sessions.ts returns it, with a session listed from the computer's disk.
    func testGroupsDecodeWithProjectFieldsAndHistoryState() throws {
        let json = #"""
            [{"key":"k57x:/Users/me/src/crok-build","deviceId":"k57x","deviceName":"MacBook Pro","deviceOnline":true,
              "path":"/Users/me/src/crok-build","name":"crok-build","placed":true,"lastActivityAt":1792098432719.0,
              "sessions":[
                {"_id":"jd7abc","sessionId":"0199e2e0","title":"Fix it","cwd":"/Users/me/src/crok-build/relay","model":null,
                 "status":"idle","online":false,"app":"tui","deviceId":"k57x","deviceName":"MacBook Pro","deviceOnline":true,
                 "preview":null,"previewKind":null,"lastActivityAt":1792098432719.0,"pinned":true,"archived":false,
                 "unread":0.0,"plan":null,"projectKey":"k57x:/Users/me/src/crok-build",
                 "projectPath":"/Users/me/src/crok-build","projectName":"crok-build","historyState":"none"},
                {"_id":"jd7def","sessionId":"0199e2e1","title":"Live","cwd":"/Users/me/src/crok-build","model":"grok-4",
                 "status":"running","online":true,"app":"desktop","deviceId":"k57x","deviceName":"MacBook Pro",
                 "deviceOnline":true,"preview":"Working","previewKind":"tool","lastActivityAt":1792098400000.0,
                 "pinned":false,"archived":false,"unread":3.0,"plan":{"done":1.0,"total":2.0},
                 "projectKey":"k57x:/Users/me/src/crok-build","projectPath":"/Users/me/src/crok-build",
                 "projectName":"crok-build","historyState":null},
                {"_id":"jd7ghi","sessionId":"0199e2e2","title":"Asked","cwd":"/tmp/x","model":null,"status":"idle",
                 "online":false,"app":"cli","deviceId":"k57x","deviceName":"MacBook Pro","deviceOnline":true,"preview":null,
                 "previewKind":null,"lastActivityAt":1.0,"pinned":false,"archived":false,"unread":0.0,"plan":null,
                 "projectKey":"k57x:/Users/me/src/crok-build","projectPath":"/Users/me/src/crok-build",
                 "projectName":"crok-build","historyState":"requested"}
              ]}]
            """#
        let groups = try JSONDecoder().decode([ProjectGroup].self, from: Data(json.utf8))
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.id, "k57x:/Users/me/src/crok-build")
        XCTAssertEqual(group.name, "crok-build")
        XCTAssertTrue(group.placed)
        XCTAssertEqual(group.unreadCount, 3)
        XCTAssertEqual(group.sessions.map(\.historyState), [.notFetched, nil, .requested])
        XCTAssertEqual(group.sessions[0].folderIfNotProject, "relay")
        XCTAssertNil(group.sessions[1].folderIfNotProject)
        XCTAssertTrue(group.sessions[0].historyState?.isOnComputerOnly ?? false)
        XCTAssertTrue(group.sessions[2].historyState?.isOnComputerOnly ?? false)
        XCTAssertEqual(group.sessions[1].plan, PlanProgress(done: 1, total: 2))

        // A state this build does not know still decodes.
        XCTAssertEqual(try JSONDecoder().decode(HistoryState.self, from: Data(#""archived""#.utf8)), .unknown)
    }

    func testSessionDetailCarriesTheProjectAndHistoryState() throws {
        let json = #"""
            {"_id":"jd7abc","sessionId":"0199e2e0","title":"Fix it","cwd":"/a/b","model":null,"effort":null,
             "gitBranch":null,"status":"idle","online":false,"app":"tui","deviceId":"k57x","deviceName":"Studio",
             "devicePlatform":"macOS","deviceOnline":false,"createdAt":1.0,"lastActivityAt":2.0,"plan":[],"usage":null,
             "pinned":false,"archived":false,"unread":0.0,"eventSeq":0.0,"projectKey":"k57x:/a","projectPath":"/a",
             "projectName":"a","historyState":"none"}
            """#
        let detail = try JSONDecoder().decode(SessionDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.historyState, .notFetched)
        XCTAssertEqual(detail.projectName, "a")
        XCTAssertFalse(detail.deviceOnline)
        XCTAssertNil(detail.pending, "a relay from before permission requests")
    }

    /// `sessions:get` while the session waits on a permission request (relay/convex/schema.ts `pendingInteraction`).
    func testSessionDetailDecodesAPendingPermissionRequest() throws {
        let fields = #"""
            {"_id":"jd7abc","sessionId":"0199e2e0","title":"Fix it","cwd":"/a/b","model":null,"effort":null,
             "gitBranch":null,"status":"waiting","online":true,"app":"tui","deviceId":"k57x","deviceName":"Studio",
             "devicePlatform":"macOS","deviceOnline":true,"createdAt":1.0,"lastActivityAt":2.0,"plan":[],"usage":null,
             "pinned":false,"archived":false,"unread":0.0,"eventSeq":4.0,"projectKey":"k57x:/a","projectPath":"/a",
             "projectName":"a","historyState":null,
            """#
        func decode(pending: String) throws -> SessionDetail {
            try JSONDecoder().decode(SessionDetail.self, from: Data((fields + #""pending":"# + pending + "}").utf8))
        }
        let detail = try decode(
            pending: #"""
                {"id":"call_7#1","kind":"permission","title":"Run npm test","detail":"npm test -- auth",
                 "toolKind":"execute","at":1792098432719.0,"options":[
                   {"optionId":"allow-once","name":"Allow once","kind":"allow_once"},
                   {"optionId":"allow-always","name":"Always allow npm test","kind":"allow_always"},
                   {"optionId":"reject-once","name":"","kind":"reject_once"}]}
                """#)
        let pending = try XCTUnwrap(detail.pending)
        XCTAssertEqual(pending.id, "call_7#1")
        XCTAssertEqual(pending.title, "Run npm test")
        XCTAssertEqual(pending.detail, "npm test -- auth")
        XCTAssertEqual(pending.toolKind, "execute")
        XCTAssertEqual(pending.options.map(\.optionId), ["allow-once", "allow-always", "reject-once"])
        XCTAssertEqual(pending.options.map(\.isAllow), [true, true, false])
        XCTAssertEqual(pending.options[2].label, "reject-once", "a choice without a name shows its id")
        XCTAssertEqual(detail.presence, .waiting)

        // `null` once the computer took an answer; a sparse request still decodes.
        XCTAssertNil(try decode(pending: "null").pending)
        let minimal = try XCTUnwrap(try decode(pending: #"{"id":"x#2","title":"Allow this?"}"#).pending)
        XCTAssertEqual(minimal.kind, "permission")
        XCTAssertEqual(minimal.options, [])
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
        XCTAssertFalse(flat.stored)
    }

    /// `commands:requestInfo` for a session nobody runs: settled at once with the relay's stored values.
    func testInfoResultMarksStoredValues() throws {
        let record = try JSONDecoder().decode(
            CommandRecord.self,
            from: Data(
                #"{"_id":"c1","type":"info","status":"done","result":{"sessionId":"0199e2e0","title":"Fix it","model":"grok-4","cwd":"/a","createdAt":1.0,"usage":{"inputTokens":10.0,"costUsd":0.5},"context":{"used":100.0,"window":1000.0},"stored":true}}"#
                    .utf8))
        let result = try XCTUnwrap(record.result)
        XCTAssertTrue(result.stored)
        XCTAssertEqual(result.model, "grok-4")
        XCTAssertEqual(result.usage?.costUsd, 0.5)
        XCTAssertEqual(result.contextWindow, 1000)
        XCTAssertNil(result.messages)
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
