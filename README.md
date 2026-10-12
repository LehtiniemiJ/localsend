# LocalSend with duplicate checking

This is a personal fork of [LocalSend](https://github.com/localsend/localsend), a free, open-source app for sharing files and messages with nearby devices over a local network.

This fork adds an optional check for files that are already in the receiver's destination. Matching files are removed from the transfer before upload, so their contents are not sent again. The feature is intended for backups whose filenames are 64-character hexadecimal identifiers, such as Signal attachments.

## Skip files already in the destination

Enable the feature on the receiving device:

1. Open **Settings → Receive**.
2. Turn on **Skip duplicate files with hash-based names**.
3. Choose the destination folder before accepting the transfer.

The sending device must have **Settings → Send → Create checksums when sending files** enabled. It is enabled by default in LocalSend.

Before upload, the receiver searches its destination and checks matching files' contents. It checks up to four files at a time. Matches are marked **Already exists** and start unchecked; you can select one again if you want another copy. If every file is already present, closing the offer accepts an empty set and no file data is uploaded.

### What gets checked

- Incoming filenames must be 64 hexadecimal characters, optionally followed by LocalSend's numbered collision suffix such as ` (2)`.
- The receiver compares file size and actual SHA-256 content checksum. The filename identifier itself is not assumed to be a content checksum.
- The destination is searched recursively. Unrelated filenames are not hashed.
- Regular filesystem destinations are supported. Gallery saves and Android content-URI destinations are not scanned.
- The sender still reads its selected files to calculate checksums before sending the offer. Matching file contents are then skipped during network upload.

## Build and run on Linux

The Flutter version is pinned in [.fvmrc](.fvmrc) and included as a Git submodule. Clone the fork with its submodules, install the Flutter Linux desktop build dependencies, then run:

```bash
git clone --recurse-submodules https://github.com/LehtiniemiJ/localsend.git
cd localsend/app
../support/submodules/flutter/bin/flutter pub get
../support/submodules/flutter/bin/flutter run -d linux --no-pub
```

To create a debug build:

```bash
../support/submodules/flutter/bin/flutter build linux --debug --no-pub
```

The executable is `build/linux/x64/debug/bundle/localsend_app`. Linux builds require the standard Flutter Linux desktop toolchain and the AppIndicator development library required by the tray plugin. See the [Flutter Linux setup guide](https://docs.flutter.dev/platform-integration/linux) for system dependencies.

## Upstream LocalSend

This fork is based on the upstream [LocalSend project](https://github.com/localsend/localsend). See upstream for the original app's supported platforms, distribution channels, protocol details, and contribution guide. LocalSend is licensed under [Apache License 2.0](LICENSE).
