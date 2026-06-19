# Second Brain Capture

A tiny iOS app that captures a thought — typed or spoken — and commits it as a
markdown note straight into the `Inbox/` folder of the second-brain vault on
GitHub (`crystalfruit2/second_brain`). The Mac's Obsidian Git plugin then
auto-pulls it into the vault.

**Flow:** open app → talk or type → **Capture** → a new file lands in `Inbox/` on GitHub.

## What's here
- `SecondBrainCapture/` — SwiftUI source (no third-party packages)
  - `ContentView.swift` — capture screen (text editor + record + capture)
  - `SpeechRecognizer.swift` — on-device dictation (Speech + AVFoundation)
  - `GitHubService.swift` — writes notes via the GitHub Contents API
  - `KeychainStore.swift` / `AppConfig.swift` — secure token + repo settings
  - `SettingsView.swift` — paste token, set repo, test connection
- `project.yml` — XcodeGen spec; generates the `.xcodeproj`

## First-time setup

### 1. Install Xcode
From the Mac App Store (a few GB). This is required to build/run iOS apps.

### 2. Generate the Xcode project
```bash
brew install xcodegen          # one time
cd ~/Documents/Projects/SecondBrainCapture
xcodegen generate
open SecondBrainCapture.xcodeproj
```
> Don't have/want XcodeGen? In Xcode: File ▸ New ▸ Project ▸ iOS App (SwiftUI),
> name it `SecondBrainCapture`, then drag the files from `SecondBrainCapture/`
> into the project and add the two usage strings (mic + speech) under the
> target's Info tab.

### 3. Create a GitHub token
GitHub ▸ Settings ▸ Developer settings ▸ **Fine-grained tokens** ▸ Generate:
- Repository access: **only** `second_brain`
- Permissions ▸ Repository ▸ **Contents: Read and write**
- Copy the token (starts with `github_pat_…`).

### 4. Run it
- In Xcode, select your iPhone (or a simulator), set the **Signing Team** to your
  Apple ID (Signing & Capabilities tab), and press ▶︎.
- In the app: **⚙︎ Settings** → paste the token → **Test connection** (expect
  ✅) → Done.
- Type or record a note → **Capture**. Check `Inbox/` on GitHub.

### 5. Enable auto-pull on the Mac
In Obsidian ▸ Community plugins ▸ **Git** ▸ enable *Pull on startup* and set an
*Auto pull interval* so phone captures appear in the vault automatically.

## Notes
- Free Apple provisioning works, but apps expire after 7 days and must be
  re-run from Xcode. The $99/yr Apple Developer Program removes that for daily use.
- The app only ever **creates new files** in `Inbox/`, so it never conflicts with
  the Mac's auto-commits.

## Reliability
Captures are **offline-first**. Tapping **Capture** writes the note to an on-device
queue (persisted to disk) *before* any network call, so nothing is lost on a flaky
connection or if the app is killed mid-commit. The queue auto-syncs when the network
returns, when the app foregrounds, and on launch. The status line shows how many notes
are still waiting to sync. Queued notes keep their original capture time.

## Roadmap
- **Phase 2:** ~~offline queue + retry~~ ✅ · App Intent/Shortcut for Back Tap & Siri; widget.
- **Phase 3:** optional AI auto-title / tags / routing.

## License
[Apache License 2.0](LICENSE) © 2026 Alp Eldam
