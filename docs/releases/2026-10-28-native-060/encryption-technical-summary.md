# Quenderin 0.6.0 — encryption technical annex

Prepared 28 October 2026 for owner/export-compliance review. This is a source-backed
technical description, not a filed declaration, legal classification or exemption.
It contains no owner identity, credentials or cryptographic key material.

## Product, source and signed-artifact boundary

Quenderin is an iOS/macOS application for local-model work, with optional direct
DeepSeek access and an optional “My computer” connection to a configured Host.
This annex covers the Apple 0.6.0 source at
`32bcb0cd3c26ad217abb339c389f9857596eaedb`. Its remote-crypto sources, Swift package
integration and app project settings are unchanged from Cloud 28 source
`1761d8430ff51212c4bdca3a8bd45eb071471dca`.

As recorded in [RELEASE.md](../../RELEASE.md), Cloud 26 and 28 passed both signed
archive actions and their SDK inclusion gates. Those gates check the SDK receipt,
source provenance and real linked entry-point/proof definitions for iOS arm64 and
macOS arm64/x86_64. This establishes inclusion in those signed exports; it does
not establish a successful live Host handshake, encrypted remote session, model
inference or completed store submission. Final declarations must identify the
actual build selected for distribution, not assume a later source is that build.

## Cryptographic inventory

| Function | Implementation and purpose |
| --- | --- |
| Host secure session | Fixed `Noise_IK_25519_ChaChaPoly_SHA256`; X25519 identity/key agreement, ChaCha20-Poly1305 authenticated encryption, SHA-256 handshake hashing/key derivation. Identity private/public inputs are 32 bytes; transport authentication tags are 16 bytes. |
| Bundled library | Rust `quenderin-remote-crypto` 0.1.0; [Snow pinned to `4bb43f50370bdb3e8b1b57814ac662864db2704f`](https://github.com/mcginty/snow/tree/4bb43f50370bdb3e8b1b57814ac662864db2704f), with explicit default-resolver/curve25519/chacha20poly1305/sha2/getrandom features. Generated Swift bindings use [UniFFI pin `7bc621ee9d0d15371d792612707ba5ed4111f950`](https://github.com/mozilla/uniffi-rs/tree/7bc621ee9d0d15371d792612707ba5ed4111f950). |
| Algorithm providers | The selected [Snow default resolver](https://github.com/mcginty/snow/blob/4bb43f50370bdb3e8b1b57814ac662864db2704f/src/resolvers/default.rs) uses `curve25519-dalek`, RustCrypto `chacha20poly1305` and `sha2`. These are bundled implementations, not CryptoKit calls. `GuardedResolver` delegates to them and rejects all-zero DH results. Extra lockfile dependencies do not establish selected algorithms. |
| OS facilities | URLSession HTTPS/WSS for network transport; nonsynchronizing Apple Keychain credential/identity storage, using an iOS device-only accessibility class and the local macOS Keychain; Security `SecRandomCopyBytes` for the 32-byte enrollment seed; OS randomness through Snow/getrandom. CryptoKit SHA-256 also checks model integrity and computes public-identity fingerprints. No OS TLS cipher suite is asserted here. |

The app introduces no new cipher, hash or key-agreement primitive. It adds the
product-specific protocol context, enrollment checks, framing, counters and error
policy around published implementations. That observation alone does not decide
the legal classification of the complete protocol/product.

## Actual data flow and invocation

The user configures a server origin and explicitly authorizes “My computer”. New
device registration generates a local private seed and calls the Rust X25519
public-key derivation. The private seed is saved in Apple Keychain; the public
identity is registered. Account login and bearer-token exchange use HTTPS to the
configured server; this account traffic is not described as Host end-to-end
encrypted traffic.

After Host identity selection/verification, the production client creates a Noise
IK initiator bound to the connection, Host and client device identifiers and the
enrolled peer public key. The secure link encrypts fragmented business messages
before relay transmission and authenticates/decrypts received messages before
dispatch. These messages support remote workspace/session operations and their
results. The relay still processes control traffic and routing metadata. Local
model chat does not invoke this Noise path. The Rust library supports both Noise
roles; this native client selects the initiator role.

Source anchors: [Cargo.toml](../../../native/remote-crypto/Cargo.toml),
[facade](../../../native/remote-crypto/src/lib.rs),
[resolver](../../../native/remote-crypto/src/resolver.rs),
[Swift package](../../../apple/QuenderinKit/Package.swift), and the
`RemoteHarnessCryptoBackend`, `RemoteHarnessClientAccount`,
`RemoteHarnessClientGateway`, `RemoteHarnessClientStorage` and
`RemoteHarnessSecureLink` files in
[QuenderinKit sources](../../../apple/QuenderinKit/Sources/QuenderinKit).
The release profile requires the verified real SDK; a missing SDK cannot silently
select the unavailable adapter.

## Difference from Apple 0.5.0 (22)

Cloud 22's recorded source is `53994b799eb021bed10e2b58a727539283f02559`.
Its Apple sources use system HTTPS and CryptoKit SHA-256 integrity checks; neither
the native Noise crate nor its Swift SDK target exists at that revision. Both
targets declared `ITSAppUsesNonExemptEncryption=false`. Noise was introduced in
`7c3f7a45`, native integration in `26df619d`, and mandatory release packaging in
`73920fd9`, after the prior release. The 0.6 source removes the earlier assertion.
Prior store approval and the old OS-only answer do not classify this new payload.
The old signed binary has not been independently re-inspected for this annex.

## Official review/filing route and unresolved owner inputs

Apple's current [documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
separates OS-only encryption from industry-standard algorithms implemented outside
the OS. For the latter it specifies a French declaration when distributing in
France. Its separate proprietary-algorithm row additionally specifies CCATS;
this annex does not infer that row merely from Noise or application wrappers.
France is enabled according to the dated release record. No applicable exemption
or existing filing reference has been established; open-source licensing alone
is not proof of exemption. Use the exact artifact and territories in Apple's
[assessment/document-upload workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/).

ANSSI's current [forms page](https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/controle-reglementaire-cryptographie-formulaires/)
directs applicants to **[Déclaration relative à un moyen de cryptologie — procedure 127585](https://demarche.numerique.gouv.fr/commencer/declaration-relative-a-un-moyen-de-cryptologie)**.
The public page assigns the declaration to the supplier or first importer and
lists company presentation, recent registration extract/foreign equivalent,
commercial brochure and technical brochure, plus user/admin guides if available.
It offers FranceConnect or a demarche.numerique.gouv.fr account for sign-in and
warns the form is still being developed. No account, draft or filing was created
during this preparation.

Owner review must supply/confirm the declarant's legal capacity (individual or
entity; supplier/first importer), legal identity/contact and any applicable
registration evidence, intended distribution operations/territories, existing
ANSSI receipt/exemption evidence if any, and the final release/build reference.
Those facts are unresolved and have not been inferred from private sources.
The authenticated form's exact identity fields were not inspected. This annex can
support the technical brochure; it does not replace the owner's other attachments,
attestations or an ANSSI receipt. Complete that determination before setting an
exemption flag or distributing the affected artifact.
