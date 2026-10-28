# Sign the verified Android candidate locally

The hosted candidate remains unsigned and draft-only. The original registered
Google Play upload key is still required. This helper signs an existing hosted AAB;
it does not build Android/native code, generate keys, change the Play upload key,
upload anything, or read `android/keystore.properties`.

The expected upload certificate SHA-256 is
`8B:38:F4:E5:85:88:3A:B7:37:F2:91:8F:49:90:BA:40:17:67:A0:39:37:EB:2A:68:72:88:BD:E3:E9:49:CF:3D`.
The existing private keystore location and alias remain unverified. Have the owner
identify that existing key; do not search credential stores or create a replacement.

The cached official npm Varlock launcher at
`~/.local/varlock/1.23.0/varlock` and JDK 21 signing tools were checked on this Mac
on 2026-10-28. No additional download or installation is required. The wrapper pins
version 1.23.0, uses only the adjacent explicit public `signing.schema`, disables telemetry
and cache, and emits only validation booleans/status. Password variables and the
private path/alias are marked sensitive. No credential value is written to a file.
Pinned Varlock was tested with this custom filename passed through `--path`:
synthetic inputs validate, while omission of each required input is rejected.
No dotfile is needed or published.

Check availability without accessing a keystore:

```sh
python3 -B tools/android-release/sign_aab.py check
```

After the exact reviewed source has passed the hosted workflow, download its three
draft assets and verify the GitHub asset digest and `.sha256` against that exact
draft/source. In your own Mac Terminal, use the existing key's private path, alias
and passwords at these hidden prompts:

```sh
zsh tools/android-release/sign-with-prompts.zsh \
  --bundle /absolute/path/quenderin-android-0.6.0-6-SHORTSHA-unsigned.aab \
  --receipt /absolute/path/quenderin-android-0.6.0-6-SHORTSHA-unsigned.aab.receipt.json \
  --receipt-sha256 VERIFIED_GITHUB_RECEIPT_ASSET_SHA256_WITHOUT_PREFIX \
  --output-dir /absolute/path/new-signed-candidate-directory \
  --source-commit FULL_REVIEWED_40_CHARACTER_SHA \
  --version-name 0.6.0 --version-code 6
```

Replace the placeholders with the exact verified artifact and reviewed commit.
Obtain the expected receipt SHA-256 from that draft's GitHub asset metadata,
independently of the downloaded local receipt.
The hidden prompts export inputs only to this command; the shell clears them on
exit. Alternatively, a human who already exported the four `QUENDERIN_UPLOAD_*`
variables may invoke `sign_aab.py sign` with the same arguments. Never enter actual
values in chat, command arguments, `.env` files, logs or repository files.

Varlock validates/injects the inputs, then `keytool` checks the existing upload
certificate before signing. `jarsigner` receives passwords by environment-variable
name, without password arguments. The wrapper checks the exact source/version,
unsigned AAB digest and Prism/image/Noise/JNA provenance; verifies the final JAR
signature and the actual packaged certificate; and compares every original payload
entry byte-for-byte after signing. Signature metadata is the only allowed addition.
Android upload certificates are self-signed, so the fixed certificate pin and JAR
signature verification are used instead of requiring a public CA trust chain.

The output directory must be new. Successful signing writes exactly the signed
AAB, its SHA-256 and a signing receipt. A rejected operation may leave an incomplete
new output directory; it produces no success receipt and must not be uploaded.
The original candidate and keystore are preserved. No timestamping, network access,
automatic retries, output overwrite or Play upload is performed.

References: [Varlock CLI and `--path`](https://varlock.dev/reference/cli-commands/),
[JDK jarsigner](https://docs.oracle.com/en/java/javase/21/docs/specs/man/jarsigner.html),
[JDK keytool](https://docs.oracle.com/en/java/javase/21/docs/specs/man/keytool.html).
