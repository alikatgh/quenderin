# Android Google Play update checklist

Use the existing `ai.quenderin.app` record and **Closed testing → Alpha** track
(`4700414835984777148`). The [release record](RELEASE.md) has the console
links and dated observations. Use the live console to confirm the upload
certificate, highest uploaded version code, draft and tester count before
preparing the update for Play.

## Repository preparation

- [ ] **Signer certificate pin.** The [bundle signer](../tools/android-release/sign_aab.py)
      pins the older upload certificate (`8B:38:F4:E5…`). The 22 November 2026
      [release record](RELEASE.md) documents the reset certificate
      (`88:0A:CA:18…`). Wait for Albert to reconfirm the full active upload
      certificate SHA-256 in Play Console. Then update the public pin, the
      [signer test expectation](../tools/android-release/test_generate_upload_key.py)
      and [signer README](../tools/android-release/README.md) together. Keep
      the upload key and credentials in the established private signing setup.
- [ ] **Version and AAB.** Keep the package ID `ai.quenderin.app`. The
      [Gradle source](../android/app/build.gradle.kts) declares `0.6.3`,
      version code `8`, and compile/target SDK 36. Use code 8 only if it is
      unused and greater than the highest code uploaded across all Play
      tracks. If a bump is needed, align the Gradle version, release notes,
      and [candidate workflow](../.github/workflows/android-beta-candidate.yml)
      inputs. Build with `:app:bundleRelease` and verify the packaged
      application ID, version and native runtimes for the exact candidate.
      Follow the [Android build guide](../android/INTEGRATION.md).
- [ ] **16 KiB alignment and ABI.** The current workflows check ELF load
      alignment for every packaged `.so`, enforce `arm64-v8a`, and check
      ZIP alignment for stored native libraries in the APK under test.
      As a CI follow-up, generate release APK splits from the AAB with
      bundletool in the candidate workflow and [CI](../.github/workflows/ci.yml).
      Check ELF load alignment for all libraries in the resulting splits,
      including `libc++_shared.so` if present, and check ZIP alignment for
      uncompressed native entries with the package verifier or `zipalign`
      as appropriate. Preserve compressed/extracted JNI packaging for ggml
      CPU plugin discovery. Keep R8 optional. If enabled in a later release,
      retain the app and Noise/JNA keep rules and verify callbacks and provider
      loading with the minified build.
- [ ] **Listing, Data safety and permissions.** Prepare the
      [listing draft](../appstore/play/LISTING.md) and App access notes against
      the exact AAB. Use the [data-flow inventory](STORE_SUBMISSION.md) and
      [privacy policy](legal/privacy-policy.md) to map downloads and catalog
      requests, optional DeepSeek, My computer, Step 5, and in-app reports
      to their data types, recipients, purposes and retention. Review which
      data is optional, what is collected or shared, what is encrypted in
      transit, and how users can request deletion. Inspect the merged release
      manifest for dependency-added permissions. Confirm the WorkManager
      `dataSync` service type and notification permission, and compare the
      model-download flow with the
      [existing foreground-service demo](../appstore/play/fgs-demo/quenderin-fgs-data-sync-demo.mp4).

## Albert only

1. Reuse the signed-in **Albert - Main - CMax** Chrome profile. In the existing
   Play app, confirm the highest uploaded code across tracks, the current Alpha
   draft, and the full SHA-256 of the active **upload** certificate. Use the
   matching private key through the established signing path. Verify the signed
   AAB signature and upload certificate before attaching it to Alpha.
2. Review the live listing, App access, and Data safety answers against the
   exact bundle. Complete the `dataSync` foreground-service declaration and
   provide the demo if it matches the release. Resolve the trader-status item
   in Play Console. Check Play's bundle validation, review status and actual
   tester availability after submitting the closed-test update.
3. Preserve the existing tester group and share the **Play opt-in link**.
   The production-access gate recorded for this app requires at least **12
   testers opted in for 14 continuous days**. Check opt-in status in Play
   Console and count testers who opted in through Play. Once the gate is met,
   apply for production access with testing and feedback evidence. After
   approval, submit the production release and verify the rollout.

Record hosted compilation and package checks separately from signed-bundle
inspection, 16 KiB runtime behavior, rendered UI, full-weight inference, and
Play review and rollout.
