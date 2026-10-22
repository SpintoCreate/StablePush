# Validation record

Date: 2026-10-22. Branch: `feat/trollstore-relay` (initially empty StablePush repository). These are actual results, not predictions.

## Executed in the Linux cloud

| Check | Exact result | What this establishes |
| --- | --- | --- |
| Authenticated Git reads of five source repositories | PASS | Source access and pinned revisions in AUDIT.md; no push/API permission claim |
| Python redactor tests | PASS: 8 tests | Closed output vocabulary, stripping sentinel secrets, status/rejection classification, malformed and oversized input handling; synthetic fixtures only |
| Build script packaging tests | PASS: 3 tests | Real script executed with fake macOS/compiler/signer commands. Fresh ZIP layout, removal of stale artifacts, failure on wrong minimum OS or missing entitlements. No real signing/build claim |
| Swift syntax-tree parsing | PASS: 7 Swift files parsed with tree-sitter-swift 0.7.4 / tree-sitter 0.26.0 | Syntax grammar only; no Swift type checking, linking or API availability validation |
| Xcode project/plist parsing | PASS | OpenStep syntax, relevant source/build references, plist syntax; not Xcode compilation |
| `bash -n build.sh` | PASS | Shell syntax |
| Companion rustpush patch applicability | PASS on pinned source | Forward `git apply --check` on clean pinned files and reverse check on patched files; no Rust compilation |
| `./build.sh` | BLOCKED: exit 2, “Build requires macOS with full Xcode and the iOS SDK. No TIPA was produced.” | Linux platform guard works; no distributable exists |
| JJTech article | Cloud fetch blocked (CONNECT 403); supplied pasted article READ | Conceptual background, no activation evidence |

The Python suite ran 11 tests total, with no skips. Its initially failing multiline-plist fixture exposed leading whitespace before the XML declaration in the offline redactor; trimming the enclosed plist fixed it and the suite passed. No test assertions were disabled.

## Not executed

| Required result | Exact result now | Evidence needed |
| --- | --- | --- |
| Native Swift protocol/backoff tests (16 checks) | NOT RUN — Swift compiler unavailable | `./build.sh` on Mac must print 16 passing checks |
| Xcode arm64 iOS build/signature/package | NOT RUN — Xcode/iOS SDK unavailable | Successful build, correct embedded entitlements/minimum OS, real TIPA checksum |
| TrollStore install and launch on iPhone 7 | NOT RUN — no connected physical device; exact iOS version not supplied | Exact iOS version/build (not identifiers), launch result, protected API access result |
| Pairing with Android OpenBubbles | NOT RUN — phones unavailable | Relay acknowledgement, Android version-info acceptance, relaunch pairing reuse |
| Apple activation response | NOT RUN — no activation attempt made | Redacted HTTP status, fixed rejection class or certificate presence; usable APNs certificate separately |
| Apple ID registration | NOT RUN — no devices/credentials used | Android IDS registration success/failure, distinct from pairing and Albert certification |
| Phone-number registration | NOT RUN — no SIM/Android device | Registered state or redacted stage/error, independently of Apple ID result |
| Later scheduled renewal | NOT RUN — no initial registration or elapsed renewal interval | Android later renewal timestamp/result plus provider request; no pairing reset |
| Real network reconnect / background resume | NOT RUN | Recovery time, saved pairing reuse, observable pause/resume on target phone |
| Bad-certificate rejection | NOT RUN | Real TLS validation failure on a controlled invalid-certificate endpoint; never install a permissive trust handler |
| Android diagnostic patch build/install | NOT RUN — Rust/Android build toolchains unavailable | Android build result, stage logging and DoNotRetry propagation on a controlled rejected response |

No redacted Apple rejection response exists to report. Do not interpret absence of a response as acceptance. The candidate's real iOS compatibility, relay interoperability and registration behavior remain unverified.

## Private device-run template

Keep filled records outside Git in ignored `private-results/`; share only redacted outcomes after reviewing them. Do not record device IDs, serial/IMEI, pairing codes, Apple usernames/passwords/2FA, phone numbers, certificates, validation blobs or message bodies. A clean installation alone is not a registration result.

| Field | Record locally |
| --- | --- |
| Candidate TIPA SHA-256 / build result | Pending |
| iPhone model / exact iOS version and build / TrollStore version | iPhone 7 / pending / pending |
| Android OS / OpenBubbles version and source revision if known | Pending |
| Pairing result / elapsed time | Pending |
| Relaunch preserves pairing / reconnect recovery time | Pending |
| Version-info stage result / validation stage result | Pending / pending |
| Albert HTTP status / fixed rejection class / certificate presence | Pending / pending / pending |
| Apple ID IDS registration result | Pending |
| Phone-number registration result (omit number) | Pending |
| Later scheduled renewal time / elapsed interval / Android result | Pending / pending / pending |
| Foreground/background/locked test result | Pending |
| Any failure's safe diagnostic stage and numeric status | Pending |

On Apple rejection: stop both clients' registration attempts, preserve only safe classification/status, and investigate. Do not alter identity to continue experimenting. The companion patch adds `DoNotRetry`; confirm its propagation on Android before depending on that stop mechanism. Stock OpenBubbles is not changed by installing this iPhone app.
