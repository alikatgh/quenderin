# Sign the verified Android candidate locally

The hosted candidate remains unsigned and draft-only. The signer accepts only the
currently pinned Google Play upload certificate. It signs an existing hosted AAB;
it does not build Android/native code, change the Play upload key, upload anything,
or read `android/keystore.properties`. The separate replacement-key generator below
is for the user's explicitly authorized upload-key reset preparation.

The expected upload certificate SHA-256 is
`8B:38:F4:E5:85:88:3A:B7:37:F2:91:8F:49:90:BA:40:17:67:A0:39:37:EB:2A:68:72:88:BD:E3:E9:49:CF:3D`.
The existing private keystore location and alias remain unverified. On 2026-10-28,
the user explicitly authorized a bounded search and a replacement upload key if
the original could not be found. The bounded follow-up located no usable key;
repository and `github-pages` environment Actions secret counts were both zero.
This does not establish permanent loss of the original key.

The cached official npm Varlock launcher at
`~/.local/varlock/1.23.0/varlock` and JDK 21 signing tools were checked on this Mac
on 2026-10-28. No additional download or installation is required. The wrapper pins
version 1.23.0, uses only the adjacent explicit public `signing.schema`, disables telemetry
and cache, and emits only validation booleans/status. Password variables and the
private path/alias are marked sensitive. No credential value is written to a file.
Pinned Varlock was tested with this custom filename passed through `--path`:
synthetic inputs validate, while omission of each required input is rejected.
No dotfile is needed or published.

## Prepare the authorized replacement upload key

This is an offline private Terminal step; the agent does not receive the password
or invoke real key generation. It creates a replacement **upload** key. Google's
existing **app signing** key, application ID and installed-user update identity
remain unchanged. Nothing is requested or submitted to Google by this helper.

Check the exact installed tools without credentials or a keystore:

```sh
python3 -B tools/android-release/generate_upload_key.py check
```

All three booleans must be true: `varlock1230`, `jdk21`, `keytoolAvailable`.
In your own Mac Terminal, from this checkout, run:

```sh
zsh tools/android-release/generate-with-prompts.zsh
```

Enter a **new absolute directory outside every Git checkout**, with an existing
parent and no symlink components. One suitable location is a new directory under
your existing `~/Library/Application Support/` folder; expand `~` to the absolute
path at the hidden prompt. Enter and confirm one new password of at least 12
characters. Both entries are hidden, passed through pinned Varlock, and cleared
from the wrapper's environment on exit. Keep this password in your existing
password manager through its private interface; never send it in chat or put it
in command arguments, a plaintext file, `.env`, logs or repository files.

The helper creates exactly these files in the new directory:

- `upload-keystore.p12`: private RSA 3072-bit PKCS12 upload key; alias
  `quenderin-upload`, SHA256withRSA certificate, validity 10,000 days. Its subject
  `CN=Quenderin upload key` labels the project and asserts no owner's legal identity.
- `upload_certificate.pem`: **public certificate only**, for Google's reset form.
- `upload-key-reset.receipt.json`: public fingerprint and preparation status;
  `resetRequested` and `registeredForPlay` are both false.

The directory is mode 0700 and files are mode 0600 under umask 077. macOS extended
ACLs are checked through descriptor metadata; any ACL-bearing output is rejected,
including inherited grants hidden by those mode bits. If the new empty directory
inherits an ACL, generation stops before creating a key. Existing ancestors and
their permissions are never changed. Directory descriptors anchor creation and
checks, and fixed relative keytool filenames resolve in that directory; ancestor
identity, Git markers and output privacy are rechecked between phases.

The generator never reads private keystore bytes. Only JDK `keytool`
creates/accesses the key; passwords reach it by environment-variable name. Tool
output is captured and only fixed status is printed. Each command has an owned
process group. Timeout or interruption stops that group with TERM, escalates to
KILL when needed and reaps its direct child. The outer Varlock supervisor gives
the inner generator time to stop its own keytool group before escalating. Signal
handlers are installed before spawning; cancellation during startup is deferred
until the child PID is owned, then its group is stopped before rejection returns.

Existing paths, files and symlinks are rejected before generation. A failed
operation preserves every newly created file. A generated `.p12` remains a private
signing identity even if PEM export, fingerprint checks or receipt writing later
fails: **never delete it as scratch or regenerate over it**. Keep the directory
private and recover the public certificate from that same key after diagnosing
the failure. A partial receipt is not success evidence; do not submit it. There
is no automatic deletion, overwrite, regeneration or retry.

Preflight rejection reports `status: "rejected"` and
`privateOutputMayExist: false`. Once generation can have started, failure reports
`status: "preserved_output_requires_recovery"` and `privateOutputMayExist: true`.
The outer supervisor reports this conservatively after dispatching Varlock,
including a timeout that prevents the child from reporting its exact phase. It
does not prove that key creation completed. Inspect the chosen directory privately
before taking another action. Preserve any `.p12` there and its password; recover
its public certificate from the same key rather than rerunning generation. Send
only the public certificate location or fingerprint when recovery is complete.

After successful private entry, share only the public certificate location or its
public SHA-256 fingerprint. Do not upload or send the `.p12` file or password.

### Register the replacement with Google

Use the existing Quenderin `ai.quenderin.app` Play Console record and the correct
signed-in profile. Open **Protected with Play → Play Store protection → Manage
Play app signing**, then **Upload key certificate → Request upload key reset**.
Select the truthful reason that the existing upload key could not be located,
upload only `upload_certificate.pem`, and submit the already-authorized reset.
Do not choose an app signing key upgrade or create another app record.

Record the reset receipt and the effective date/time Google displays or confirms.
The current official help does not specify a guaranteed completion interval; do
not promise a fixed 48-hour wait. Verify the effective **upload certificate**
fingerprint in Play against the new receipt before enabling it in the signer.
Only after that verification, update the public `CERT_SHA256` pin and its focused
tests to the confirmed certificate. The current pin stays unchanged during key
generation and reset preparation, so the signer intentionally rejects the new key
until that separate change is verified. Then use the signing command below with
the new `.p12` location, alias `quenderin-upload`, and the same password twice.

Official references: [Google's upload-key reset procedure](https://support.google.com/googleplay/android-developer/answer/9842756?hl=en),
[upload key versus app signing key](https://developer.android.com/studio/publish/app-signing#reset-upload-key).

## Sign the exact hosted candidate

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
