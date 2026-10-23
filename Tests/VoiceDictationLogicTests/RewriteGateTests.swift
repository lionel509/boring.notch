import XCTest
@testable import VoiceDictationLogic

/// #13 r5 / U2: the single go/skip decision for the rewrite. Every take that is not rewritten has a reason.
final class RewriteGateTests: XCTestCase {
    private func field(
        bundle: String? = "com.apple.TextEdit", secure: Bool = false, caret: Int = 5,
        rangeSettable: Bool = false, textSettable: Bool = true
    ) -> FocusedField {
        FocusedField(
            pid: 42, bundle: bundle, role: secure ? "AXSecureTextField" : "AXTextArea",
            secure: secure, caret: caret, rangeSettable: rangeSettable, textSettable: textSettable
        )
    }

    func testNoFieldSkipsWithAReason() {
        let d = RewriteGate.decide(field: nil, cloudOn: true, hasKey: true, cleanupOn: true, keyAbortLive: true)
        XCTAssertEqual(d, .skip(.noField))
    }

    func testSecureFieldSkips() {
        let d = RewriteGate.decide(field: field(secure: true), cloudOn: true, hasKey: true, cleanupOn: true, keyAbortLive: true)
        XCTAssertEqual(d, .skip(.secureField))
    }

    func testNoCloudNoCleanupSkips() {
        let d = RewriteGate.decide(field: field(), cloudOn: false, hasKey: true, cleanupOn: false, keyAbortLive: true)
        XCTAssertEqual(d, .skip(.cleanupOff))
    }

    func testCloudWithoutKeyStillRunsWhenCleanupOn() {
        let d = RewriteGate.decide(field: field(), cloudOn: true, hasKey: false, cleanupOn: true, keyAbortLive: false)
        XCTAssertEqual(d, .run(.ax))
    }

    func testNoCaretNoAbortSkips() {
        let d = RewriteGate.decide(field: field(caret: -1), cloudOn: true, hasKey: true, cleanupOn: true, keyAbortLive: false)
        XCTAssertEqual(d, .skip(.noAbortSource))
    }

    func testVSCodeWithCaretRuns() {
        let f = field(bundle: "com.microsoft.VSCode", caret: 5, textSettable: false)
        let d = RewriteGate.decide(field: f, cloudOn: false, hasKey: false, cleanupOn: true, keyAbortLive: false)
        XCTAssertEqual(d, .run(.axSelectType))
    }

    /// Invariant over every field the helper can report, crossed with every setting: a take is rewritten (audio
    /// goes to the cloud and text is retyped) only through `.run`, a skip always has a reason, a nil or secure
    /// field never runs, and `.run` holds exactly when the pre-gate expression held (no rewrite lost).
    func testEveryTakeIsRewrittenOrHasAReason() {
        var fields: [FocusedField?] = [nil]
        for bundle in ["com.apple.TextEdit", "com.microsoft.VSCode", "dev.warp.Warp-Stable", nil] as [String?] {
            for secure in [true, false] {
                for caret in [-1, 0, 7] {
                    for rangeSettable in [true, false] {
                        for textSettable in [true, false] {
                            fields.append(field(bundle: bundle, secure: secure, caret: caret,
                                                rangeSettable: rangeSettable, textSettable: textSettable))
                        }
                    }
                }
            }
        }
        var cases = 0
        for f in fields {
            for cloudOn in [true, false] {
                for hasKey in [true, false] {
                    for cleanupOn in [true, false] {
                        for keyAbortLive in [true, false] {
                            cases += 1
                            let d = RewriteGate.decide(field: f, cloudOn: cloudOn, hasKey: hasKey,
                                                       cleanupOn: cleanupOn, keyAbortLive: keyAbortLive)
                            let label = "field=\(String(describing: f)) cloud=\(cloudOn) key=\(hasKey) "
                                + "cleanup=\(cleanupOn) abort=\(keyAbortLive)"
                            switch d {
                            case .run(let m):
                                XCTAssertNotEqual(m, .none, label)
                                XCTAssertNotNil(f, label)
                                XCTAssertFalse(f?.secure ?? true, label)
                            case .skip(let s):
                                XCTAssertNotEqual(s, .none, label)
                            }
                            // The pre-gate expression from the r4 code (VoiceDictationManager.insertAndRefine).
                            var legacy = false
                            if let f {
                                let chosen = RewriteMechanism.choose(field: f)
                                legacy = chosen != .none
                                    && ((cloudOn && hasKey) || cleanupOn)
                                    && RewriteMechanism.effective(chosen, caretReadable: f.caret >= 0,
                                                                  keyAbortLive: keyAbortLive) != nil
                            }
                            if case .run = d {
                                XCTAssertTrue(legacy, label)
                            } else {
                                XCTAssertFalse(legacy, label)
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, fields.count * 16)
    }

    /// #17 U1 step 7: a labelled take is never rewritten, on-device or cloud, and the reason is logged.
    func testLabelledModeSkipsTheRewrite() {
        let d = RewriteGate.decide(field: field(), cloudOn: true, hasKey: true, cleanupOn: true,
                                   keyAbortLive: true, mode: .everyoneLabelled, takeSeconds: 5)
        XCTAssertEqual(d, .skip(.labelled))
    }

    /// Plain modes are unaffected by the labelled skip.
    func testPlainModesStillRun() {
        for mode in [SpeakerMode.onlyMe, .everyoneButMe] {
            let d = RewriteGate.decide(field: field(), cloudOn: true, hasKey: true, cleanupOn: true,
                                       keyAbortLive: true, mode: mode, takeSeconds: 5)
            XCTAssertEqual(d, .run(.ax), "\(mode)")
        }
    }

    /// The WAV is truncated at CloudConfig.maxTakeSeconds, so a longer take is not rewritten.
    func testTakeLongerThanTheCloudCapSkips() {
        let over = RewriteGate.decide(field: field(), cloudOn: true, hasKey: true, cleanupOn: true,
                                      keyAbortLive: true, mode: .onlyMe, takeSeconds: 181)
        XCTAssertEqual(over, .skip(.tooLong))
        let atCap = RewriteGate.decide(field: field(), cloudOn: true, hasKey: true, cleanupOn: true,
                                       keyAbortLive: true, mode: .onlyMe, takeSeconds: 180)
        XCTAssertEqual(atCap, .run(.ax))
    }
}
