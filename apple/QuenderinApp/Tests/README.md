# Bounded Xcode Cloud checks

The shared `Quenderin` and `QuenderinMac` schemes reference the iOS and macOS
Cloud test plans. Use **Debug** Test actions on one supported iPhone simulator
and one supported macOS destination, one worker each, without repetitions or
automatic retries. The iOS app supports iPhone only. These tests require a fresh,
ephemeral Cloud install/user; they never reset an existing app profile. An
unexpected welcome, saved connection, or conversation state fails the journey.
Never execute these plans on a personal Mac or an existing simulator/device.
Fresh-state assertions run after the app initializes; they do not prevent its
startup persistence access. The execution boundary is the verified ephemeral
Xcode Cloud environment, not an asserted test sandbox. A scheme pre-action is
not installed as a fail-closed guard because its abort-before-host-launch and
build-for-testing semantics have not been verified. Hosted `build-for-testing`
may compile these targets without launching the app or executing the plans.

`CloudCredentialStoreTests` runs in the actual app test host and checks the
production DeepSeek and computer credential stores against the real Keychain.
Every item uses a new UUID account, is asserted absent before creation, and gets
an exact service/account cleanup registered only after creation. No existing
credential is queried. DeepSeek load, update, recreated-store reload, removal,
and an older accessibility variant are covered. The computer store has no public
removal API, so its test uses an exact Security deletion of its own synthetic
item and then verifies absence through a recreated production store.

`CloudJourneyTests` keeps passing screenshots for first entry and AI consent,
the default local route, disconnected DeepSeek/computer forms, opt-in validation
consent, locally rejected input and recovery, local draft navigation, a canned
reply, settings, saved history and relaunch. On Mac it checks both last-window
paths: main alone, and Settings remaining after main closes. Closing the final
window must quit, and relaunch must restore a usable main window and saved chat.
With Settings alone, Window > Show Main Window and Command-0 must recover the
same saved conversation without duplicate main windows. Command-N must recover
one main window with an empty, focused composer and retain the previous chat.
The app-hosted Mac delegate tests check reopen dispatch intent; the UI journey
does not label application activation or that dispatch test as a real Dock click.
The form submissions contain deliberate invalid syntax rejected before HTTP;
the tests never authorize a provider, pair a Host, or send a cloud inference call.
The secure runtime's connection form is required; a missing SDK is a failure.

The app's existing **Debug-only** `QUENDERIN_MOCK_UI=1` seam supplies the fake
downloader/engine. Its empty model placeholder is not model-weight evidence, and
its canned reply identifies itself. The mock completes synchronously, so these
journeys cannot reliably assert streaming Stop/Continue. They do not establish
real model inference, external provider/Host connectivity, Dock activation,
physical hardware behavior, or exact signed Release authentication. No production
source, entitlement, Keychain group, or signing permission is changed for tests.

Preparation is source-only until the bounded Cloud execution exception is
authorized. A generated project and parse/configuration checks are not a Cloud
build, executed XCTest result, rendered screenshot review, or signed release check.
