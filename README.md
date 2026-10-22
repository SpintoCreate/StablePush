# StablePush — ValidationRelay reliability candidate

A foreground TrollStore provider app based on [JJTech0130/ValidationRelay](https://github.com/JJTech0130/ValidationRelay), for an arm64 iPhone 7 running a TrollStore-supported iOS 15 version. No jailbreak, root access, LaunchDaemon or additional always-on proxy/server. The existing public registration relay remains part of the OpenBubbles protocol.

**Status: source candidate only. No genuine TIPA has been compiled in this Linux environment, and no physical-device registration tests have run.** Setting the deployment target to iOS 15 is not proof that protected APIs work on your exact iOS build. There is no claim that this fixes Apple activation rejection.

Read [the pinned-source audit](docs/AUDIT.md) first. It covers ValidationRelay, OpenBubbles/relayserver, ziggy416/OpenBubblesProxy, the current OpenBubbles app and its pinned rustpush dependency. See [exact validation results and outstanding tests](docs/TEST-RESULTS.md).

## Changes

- Native URLSession WebSocket with default system TLS verification; only `wss://` provider endpoints, no credential-bearing URLs or redirects. Apple certificate retrieval uses HTTPS; there is no plaintext or trust-all fallback.
- Reconnects on close/error, detects missing pongs, bounds connection/pairing deadlines, waits for network restoration, and uses capped exponential delay with jitter. Old socket callbacks cannot replace a new connection.
- One persistent SwiftUI manager, explicit foreground resume/background pause, foreground Keep Awake and reversible dimming. No unsupported claim of continuous background execution.
- Pairing code/secret/URL saved as one Keychain record. Legacy defaults migrate only after a successful secure save. No raw protocol JSON, version identifiers, validation blobs or Apple response bodies in diagnostics. The pairing code appears only where the user needs to read it.
- Serial validation work off the UI thread, fresh validation for each request, HTTP/plist/NAC errors instead of forced unwraps/assertions, bounded HTTPS and MIG waits, and copied MIG buffer cleanup. Rejections stop the provider pending investigation.
- Bounded in-memory redacted stage diagnostics, exportable from the app. Repeat validation is labeled as a repeat request, not successful renewal. Android activation/renewal visibility requires the separate diagnostic patch below.
- Actual iPhone identity is read without modification; no synthetic Mac serial/UDID or hardware writes.

## Build on a Mac

1. Install full Xcode 15 or newer, launch it once, and let it install its iOS components. In Xcode → Settings → Locations select its Command Line Tools. A paid developer account is not needed for the unsigned build/ad-hoc TrollStore signature.
2. Install [Homebrew](https://brew.sh/) if needed. In Terminal run `brew install ldid python`. This supplies the ad-hoc entitlement signer and Python checks. If Xcode asks to accept its license, complete that through Xcode.
3. Copy this complete repository folder to the Mac or push this branch to your own GitHub repository and clone it there. Do not copy any private-results folder or device logs. In Terminal, type `cd `, drag the repository folder onto Terminal, and press Return.
4. Run:

   ```bash
   python3 -m unittest discover -s tests -v
   ./build.sh
   ```

   The script runs 16 native Swift protocol/backoff checks, builds arm64 for iOS 15.0, checks the built minimum OS and entitlements, ad-hoc signs the executable, and creates `dist/ValidationRelay.tipa` plus a SHA-256 file. It stops on errors. Python packaging tests use fake tools; only the Xcode build makes a real iOS executable.
5. Keep the complete error output if compilation fails, but review it for local paths before sharing. Do not bypass TLS checks, remove required entitlements, raise the minimum OS above your phone, or label a renamed ZIP as a working TIPA.

An optional manual GitHub Actions workflow is included. After you push the branch yourself, open Actions → Build TrollStore candidate → Run workflow on this branch. A successful run uploads the TIPA candidate. No workflow has been run or artifact downloaded here. CI success still does not verify TrollStore or registration.

## Install on the iPhone 7

1. In Settings → General → About check **iOS Version**, without sharing serial/IMEI/UDID. Confirm that TrollStore is already installed and functioning on that exact build. The app targets iOS 15.0; iPhone 7 does not support iOS 16/17. Do not update or jailbreak the phone for this project.
2. Transfer the built `dist/ValidationRelay.tipa` to the phone using AirDrop or Files. Open it in TrollStore and choose Install. Install through TrollStore, not normal App Store signing. Required private entitlements come from the original app; a standard application-scoped Keychain group is added for pairing storage.
3. This candidate keeps the upstream bundle identifier to allow pairing migration. Installing can replace an existing ValidationRelay app. Keep its original installer so you can return to it; do not uninstall it merely to try migration. Never export its app data or Keychain contents for sharing.
4. Open the app. If it crashes, or the redacted log reports protected identity or NAC access failure, stop and record the stage. These private APIs need verification on the exact OS; no jailbreak-only fallback is provided.
5. Choose the existing relay (Beeper by default), enable Relay and Keep Awake, and keep the app foreground, unlocked and charging. Use a comfortable dim setting; backgrounding or locking can suspend the provider. Opening Android on another phone does not require backgrounding the iPhone app.

## Pair and test separately

Use the same relay service on both phones: the iPhone uses its `wss://.../api/v1/provider` endpoint; Android uses the corresponding `https://...` base URL. The custom provider endpoint is not an OpenBubblesProxy HTTP endpoint.

1. **Pairing:** enter the iPhone code in OpenBubbles on Android, using its existing relay flow. Confirm version-info and validation stages in the iPhone diagnostics. Do not record the code. Force-close/reopen the iPhone app and check privately that the pairing is reused. Toggle Wi-Fi off/on and verify reconnection with the saved pairing. Record pass/fail and elapsed recovery time.
2. **Apple activation and Apple ID:** use OpenBubbles' supported Apple ID flow; enter credentials and 2FA only in that app. Distinguish receipt of an Albert/APNs certificate from IDS/Apple ID registration. For redacted activation evidence, use the companion patch described below; the iPhone has no activation-response event. Do not infer success from a pairing code or validation blob.
3. **Phone number:** use the Android OpenBubbles phone-number setup with its supported SIM/SMS requirements. Record whether the number becomes registered separately from Apple ID. Do not log the number, SMS activation payload or messages. Follow OpenBubbles' current documented donor-phone preparation; this repository does not change the iPhone's Apple ID, SIM or iMessage settings automatically.
4. **Later renewal:** leave the iPhone provider available. Wait until Android's real scheduled renewal (heartbeat interval or expiry minus five minutes); do not reset pairing or pretend an immediate repeat validation is a later renewal. Verify a new validation request plus Android registration completion and continued registered status. Record timestamp/interval and stage outcomes without identifiers. See the test matrix for fields.
5. **Foreground limitation:** background/lock and later reopen the iPhone; record its pause/resume behavior. Keep Awake prevents idle display sleep only while foreground; it does not bypass manual locking or iOS suspension. Unattended renewal while suspended is unsupported under the stated constraints.

If Apple rejects activation, **stop the attempt**: disable the iPhone Relay, stop Android registration/retry attempts, save only the redacted stage/status/classification, and investigate. Do not reset identity, try serial variants or repeatedly submit credentials. There is no proven identity-spoofing fix here.

## Android diagnostics (advanced, optional separate build)

The iPhone protocol exposes version and validation requests; it never carries the Android Albert response or IDS renewal result. For those stages the repository includes `patches/rustpush-redacted-diagnostics.patch` against rustpush **a7fab473e7a33325a760635285db2860de8e1cb0**, the inspected OpenBubbles app's pinned submodule. It is not bundled into the TIPA and does not instrument a stock Play Store APK.

A developer building OpenBubbles from source can apply it inside that submodule:

```bash
# In a checkout of OpenBubbles/openbubbles-app at the revision in docs/AUDIT.md,
# after initializing its submodules using its own build instructions:
git -C rustpush rev-parse HEAD
# Proceed only when this is the exact pinned SHA above.
git -C rustpush apply --check /absolute/path/to/StablePush/patches/rustpush-redacted-diagnostics.patch
git -C rustpush apply /absolute/path/to/StablePush/patches/rustpush-redacted-diagnostics.patch
```

Then follow that repository's Android build/install instructions. This companion Rust/Android build has **not** been compiled here. The patch does not change activation identity or request fields. It adds fixed-vocabulary `registration-diagnostic` log lines for HTTP status, known rejection class, protocol/certificate presence and registration/renewal results. Rejection/missing certificate becomes `DoNotRetry`, requiring investigation instead of repeated activation. It also replaces one raw renewal error log. Review any other OpenBubbles log output locally: the rest of upstream logging has not been audited for safe export. The renewal stage can also run during initial registration; only a later scheduled event proves renewal. A certificate-presence log precedes certificate parsing and does not prove the certificate is usable.

For an already captured local Albert response, `tools/redact_activation.py` emits only a closed diagnostic schema:

```bash
# Input must remain local and outside Git; supply the actual HTTP status.
python3 tools/redact_activation.py --http-status 403 < /private/local/path/response.txt
```

This command makes no Apple request. Its output strips bodies, identifiers, certificates and arbitrary text. Do not capture a raw response just to use this tool, enable a trust-all MITM, or upload the input. Unknown errors remain `unclassified`; they are not guessed. Stop on rejection. The Python tool tolerates multiline Protocol blocks; the upstream Rust parser retains its original pattern, so the two are not identical parsers.

## Privacy and project state

Work is on `feat/trollstore-relay`. Generated installers, dist, private-results, proxy registries, credentials and device material are ignored. `.gitignore` is not a redaction mechanism: review every staged file. The upstream app's diagnostic history may already contain identifiers; do not export it. The candidate creates a new bounded in-memory diagnostic list; it does not erase old device/OS logs.

For source provenance and private API caveats see [UPSTREAM.md](docs/UPSTREAM.md). No external services were deployed and no code was pushed from this environment.
