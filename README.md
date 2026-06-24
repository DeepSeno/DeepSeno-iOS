# DeepSeno iOS

DeepSeno iOS is the mobile companion for the DeepSeno desktop app. It captures audio, photos, video, and text memos, then syncs them to the paired desktop over the local network.

## Features

- Voice recording with live transcription
- Photo, video, and text memo capture
- Local upload queue with retry
- Source browsing and detail views
- Chat and briefing views for paired desktop data
- Optional relay transport when configured by the app distributor

## Tech Stack

- SwiftUI + Swift 6
- SwiftData
- AVFoundation
- Speech framework
- XcodeGen

## Build

Generate the Xcode project after editing `project.yml`:

```bash
xcodegen generate
```

Build for the iOS simulator:

```bash
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

For device builds, set your Apple Developer Team ID locally or in Xcode.

## Configuration

Release credentials are not committed. Copy the template and fill local values only when you need to upload a release:

```bash
cp .env.example .env
```

GitHub Actions releases use repository secrets. See `docs/github-actions-ios-release.md`.

The optional relay server URL is intentionally blank in the open-source project. Distributors can set `RELAY_SERVER_BASE_URL` in `project.yml` or their CI environment.

## Release

The release script builds, signs, exports, and uploads an IPA:

```bash
./scripts/release-testflight.sh
```

GitHub Actions also provides a manual `Build iOS IPA` workflow with the same release path.

## Security

Do not commit `.env`, App Store Connect private keys, provisioning profiles, certificates, or real production service URLs. Keep release credentials in local files or GitHub Actions secrets.

## License

MIT. See `LICENSE`.
