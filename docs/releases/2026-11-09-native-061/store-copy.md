# Native 0.6.1 store drafts

Prepared 9 November 2026 from main `2875d5174e6d3249bbfd3f7aed906f254f6f1a3f`.
An editable draft is not a submitted update. These notes were not pasted into
App Store Connect or Play Console.

Public iOS and macOS **0.6.0** is already on the App Store (1 November 2026).
This text is only for the next version. It does not claim tested inference,
a signed archive, or a store submission.

## Apple description

Keep the live 0.6.0 description. This increment does not add a destination.

## What's new

Local chat opens without an account or a setup tour. An explicit model choice stays selected. A chat can keep one name next to the model, and one reply owns that conversation at a time.

Calculator, units, and dates can be turned off. A tool that is off does not run. A local reply that mentions a sensitive action is held on the device and is not shown.

Cancelling a model download returns to the model choice. Optional DeepSeek, Step 5, and Remote Harness paths are unchanged and still send data only when you choose them.

## App Review notes

0.6.1 is a local-chat increment on the already released 0.6.0 app. No Quenderin account is required. Choose and download a small compatible model over Wi-Fi for ordinary local chat. No model download or server provisioning starts automatically.

DeepSeek, My computer, and Step 5 are the same optional destinations as 0.6.0. Each sends data only after the person chooses it. This build does not add a network destination.

The new behavior is source-reviewed and covered by host fixtures. It is not tested full-weight inference, and this preparation did not run a simulator or a physical device. Record the exact signed build before submission. Do not submit while the gates in RELEASE.md are closed.

## Google Play release notes

Local chat opens without an account or a setup tour. An explicit model stays selected, a chat can keep one name, and one reply owns that conversation. Calculator, units, and dates can be turned off. A sensitive local reply is held on the device. Cancelling a download returns to the model choice. Optional remote destinations are unchanged.

The existing available track is Closed testing - Alpha. A draft or unsigned bundle is not a published Google Play update.
