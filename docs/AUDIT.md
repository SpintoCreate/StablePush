# Audit before registration changes

Inspected 2026-10-22; source evidence only. No device logs supplied, no Apple activation attempted.

| Component | Inspected revision |
| --- | --- |
| JJTech0130/ValidationRelay | e1b74fbc92a1664dd4fafec526f59acd8f5e6425 |
| OpenBubbles/relayserver | 630721fef21e3d072e72d92df957a66c0b2b0851 |
| OpenBubbles/openbubbles-app | eed1b6332efbb17adbf5ebfa2263ad770169f75e |
| OpenBubbles/rustpush (app's pinned submodule) | a7fab473e7a33325a760635285db2860de8e1cb0 |
| ziggy416/OpenBubblesProxy | 40ee8e8fd06f35ced3dc57a598800dcd612c7080 |

Source links below pin the inspected revisions. Changes in this branch address app transport/lifecycle/error handling; activation identity and registration payload semantics are preserved.

## Confirmed failure paths

- [ValidationRelay Relay.swift](https://github.com/JJTech0130/ValidationRelay/blob/e1b74fbc92a1664dd4fafec526f59acd8f5e6425/ValidationRelay/Relay.swift): `webSocketDidConnect` logs code, secret and complete register JSON. `webSocketDidReceiveMessage` prints all incoming JSON, version fields including serial/UDID, and validation data. Malformed JSON, absent request IDs, and unavailable MobileGestalt fields hit `try!`/forced unwraps. Clean disconnect only logs; reconnection is triggered by errors, not clean closes. Viability changes are ignored. Replacing a connection does not explicitly disconnect the previous delegate. No application registration deadline or missed-pong deadline exists.
- [ValidationData.swift](https://github.com/JJTech0130/ValidationRelay/blob/e1b74fbc92a1664dd4fafec526f59acd8f5e6425/ValidationRelay/ValidationData.swift): certificate uses plaintext HTTP; synchronous requests run directly from a socket callback; no explicit HTTP status handling. Network/parse errors crash via `try!`; NAC errors rely on assertions, which may be removed in optimized builds. Session requests/responses/signatures are logged. No NAC context destruction is declared in its MIG interface; do not invent an unsupported teardown call.
- [ContentView.swift](https://github.com/JJTech0130/ValidationRelay/blob/e1b74fbc92a1664dd4fafec526f59acd8f5e6425/ValidationRelay/ContentView.swift) and App.swift: connection starts in View initialization, and the App constructs a manager inside `body`; lifecycle can recreate/reconnect it. Keep Awake is independent of scene state; no foreground reconnection policy. Background `processing` in Info.plist is not a continuously running service.
- [relayserver](https://github.com/OpenBubbles/relayserver/tree/630721fef21e3d072e72d92df957a66c0b2b0851): `relay-package/layout/Library/LaunchDaemons/dev.copper.relayserver.plist` and Debian package scripts implement a daemon deployment; unsuitable for this TrollStore-only app. `src/relay.rs` describes the register/code+secret, get-version-info and get-validation-data wire protocol. It sends application JSON `ping`, in addition to WebSocket transport behavior. EOF in `poll` uses `continue`, potentially spinning on a closed stream. This daemon is not included or packaged here.

## Current OpenBubbles path and identity mismatch

- [hw_inp.dart](https://github.com/OpenBubbles/openbubbles-app/blob/eed1b6332efbb17adbf5ebfa2263ad770169f75e/lib/app/layouts/setup/pages/rustpush/hw_inp.dart) `handleBeeper` posts to bridge/get-version-info with the pairing code. For `software_name == "iPhone OS"`, it calls `configFromRelay`; the Mac path instead fetches validation data and builds a Mac config. `lastCheckedCode` is assigned before the request; a failed request with the same code may be skipped on retry in that screen.
- [api.rs](https://github.com/OpenBubbles/openbubbles-app/blob/eed1b6332efbb17adbf5ebfa2263ad770169f75e/rust/src/api/api.rs) `config_from_relay` fetches versions and creates a relay config; app-generated UUIDs belong to the Android configuration, not the iPhone hardware. This app does not change them.
- [rustpush relay.rs](https://github.com/OpenBubbles/rustpush/blob/a7fab473e7a33325a760635285db2860de8e1cb0/src/relay.rs) `build_activation_info` hardcodes `device_class = MacOS`, `product_type = iMac13,1`, while taking version, build, serial and UDID from the iPhone. `get_activation_device` returns MacOS. `get_adi_mme_info(require_mac)` also constructs Mac metadata. The mixed identity is directly evidenced. Its causal role in any Apple failure is NOT proven. Changing only a serial cannot establish coherent identity or working registration; no substitution is made here.
- [activation.rs](https://github.com/OpenBubbles/rustpush/blob/a7fab473e7a33325a760635285db2860de8e1cb0/src/activation.rs) posts to albert.apple.com, extracts `<Protocol>` then `DeviceCertificate`; absent fields become `AlbertCertParseError`. That error alone does not identify Apple's rejection reason. This request runs on Android, outside the provider protocol. The iPhone cannot see its HTTP response, Apple ID result, phone result or renewal result. There is no activation-result/renewal-result event in the inspected provider handlers. Do not invent those events or report successful registration after delivering a validation blob.
- [ids/user.rs](https://github.com/OpenBubbles/rustpush/blob/a7fab473e7a33325a760635285db2860de8e1cb0/src/ids/user.rs): `calculate_rereg_time_s` uses the server heartbeat interval or certificate expiry minus 300s. Registration requests call `config.generate_validation_data()`. `identity_manager.rs` schedules re-registration. Keeping the provider available permits fresh validation requests; the iPhone cannot initiate or certify Android renewal. Repeated validation requests are labeled repeat requests, never proof of renewal.
- Phone-number setup has a separate SIM/SMS authentication path in `lib/app/layouts/setup/pages/rustpush/phone_number.dart`; relay pairing does not prove phone-number registration.

## TrollStore and delivery limits

The existing app uses protected MobileGestalt reads and Apple's absd MIG client with `abs-client` and protected-key entitlements. These are private APIs already in ValidationRelay, not proof they work on every iOS 15 build. Test their entitlement/access behavior on the exact device. No new daemon, root command, jailbreak library, hardware mutation or background execution exploit is introduced.

The app can keep its foreground display awake. iOS can suspend it when backgrounded or locked; TrollStore alone does not grant guaranteed always-on execution. Reliable unattended renewal while suspended cannot be promised. The existing public relay service is still required by the protocol; no additional self-hosted server is introduced.

This Linux cloud has no Xcode, iOS SDK, Swift compiler or connected phones. A genuine iOS binary and physical-device test results cannot be produced here. Build instructions and checks are provided; TIPA delivery remains blocked on a Mac build and device verification. No trust-all TLS fallback is permitted.

## OpenBubblesProxy audit (after exact URL supplied)

[proxy.py](https://github.com/ziggy416/OpenBubblesProxy/blob/40ee8e8fd06f35ced3dc57a598800dcd612c7080/proxy.py): `_is_rust_client` guesses client identity from absence of User-Agent and Content-Type. In hybrid mode only those get-version-info responses have serial/UDID replaced. `new_identity` generates synthetic iMac-format serial + UUID; `identity_for` persists them keyed by real UDID. These are wire substitutions, not hardware writes. README/comment assertions about Apple accepting them, rejecting iPhones or activating each serial once are author claims, not verified logs in this audit. No test suite or captured activation response is present in the checkout.

`load_registry` treats any read/parse failure as an empty registry, permitting identity changes after corruption/permission failures. Registry load and save are individually locked but the read-modify-write operation in `identity_for` is not; concurrent requests can race or lose mappings. The registry persists real UDID and serial; logging includes a UDID prefix. `_is_rust_client` is a brittle request-header heuristic, not authenticated client detection. Python's upstream HTTPS request uses default verification (no trust-all found), but ThreadingHTTPServer listens over plaintext; TLS depends on an external tunnel/reverse proxy. Error strings and paths are logged without strict redaction. `serve_forever`, Docker and the tunnel require an always-on host and are not a TrollStore-only solution. None is packaged here.

## Additional reference

User supplied https://jjtech.dev/reverse-engineering/imessage-explained/ . Retrieval was blocked by the cloud egress proxy (CONNECT 403). The user subsequently supplied the article as pasted text, which was read. It distinguishes Albert/APNs client certification, IDS authentication/registration, validation data and message delivery, and warns that validation properties are device-dependent. This supports testing those stages separately; it is not a current iPhone 7 activation result or proof for identity substitution. Source findings above stand independently.

## Secure storage prerequisite found during review

TrollStore RootHelper/main.m at 88424f683b2a08f34a3f88985f790f97d84ce1df supplies fallback application/Keychain entitlements only when the executable has no entitlements. ValidationRelay already has private entitlements, so relying on that fallback for new Keychain storage would be unsafe. The candidate explicitly declares a single per-app application identifier/Keychain access group and uses that exact group in queries; no wildcard/shared-token group is requested. These are ordinary application storage entitlements, not jailbreak privileges. Actual Keychain access/migration still needs a device test.
