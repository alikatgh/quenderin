# Apple encryption export compliance

Local chat works offline after model setup. The optional **My computer**
connection uses bundled Snow and Noise IK (`Noise_IK_25519_ChaChaPoly_SHA256`)
to protect remote session payloads. Its X25519, ChaCha20-Poly1305 and SHA-256
implementations run outside Apple's OS crypto. The final App Store Connect
encryption declaration and France filing or exemption determination remain
pending with Albert for the selected iOS and macOS builds.
[Encryption technical annex](releases/2026-10-28-native-060/encryption-technical-summary.md) · [Issue #217](https://github.com/alikatgh/quenderin/issues/217)

On 1 November 2026, App Store Connect showed France as
“Processing to Not Available”. Storefront removal remains unverified.
[Issue #217](https://github.com/alikatgh/quenderin/issues/217)

## Owner checklist

- [ ] Identify the exact iOS and macOS builds and intended distribution
      territories. Verify the archived plists and linked SDK for each build.
      [Store submission checklist](STORE_SUBMISSION.md#5-apple-encryption-inventory-and-classification)
- [ ] Establish and retain the basis for the France filing or exemption
      determination, including any required filing evidence.
- [ ] Complete the App Store Connect encryption declaration for the selected
      builds. Retain any required documentation and acceptance evidence.
- [ ] When the determination supports French distribution, restore France in
      App Store Connect and verify the French storefront for the intended
      release before closing issue #217.
