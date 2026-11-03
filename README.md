# J.A.R.V.I.S

Personal AI assistant apps for **iPhone** and **Mac**.

| | iPhone app (`.ipa`) | Mac app |
|---|---|---|
| Brain | Google Gemini (your API key). Claude API is optional | Gemini, Claude API key, **or your Claude Pro/Max subscription** through Claude Code |
| Main job | You say "make me X" and it creates the file in its own folder in the **Files app** | Watches your screen, **suggests what to do next**, and can act on your Mac |

---

## iPhone: what it does

You open the app, type or say a request, and JARVIS creates the file. Everything is saved in
**Files › On My iPhone › JARVIS**.

**Requested features**
- Gemini API key (stored in the iOS Keychain)
- Makes real files in its own folder: `.txt`, `.md`, `.csv`, `.json`, `.html`, code, and anything else text-based
- Makes pictures with Gemini's image model
- The folder shows up in the iOS Files app

**Extra features**
- 🖼 **Image editing**: "remove the background", "make it watercolour", or use your photos as references
- 📄 **PDF documents** (reports, CVs, letters, worksheets) with real formatting
- 📊 **Charts** (bar, line, area, pie, donut, scatter) saved as PNG
- 🔊 **Audio files**: text-to-speech WAV with 30 Gemini voices
- 🔳 **QR codes** for links, Wi-Fi, contacts
- 📅 `.ics` calendar events and 👤 `.vcf` contacts you can tap to add
- 🗜 Zip folders, and move, copy, rename, edit or append to files
- 🌐 **Web search** with sources, read web pages, download files into the folder
- 🎙 **Voice**: push-to-talk, spoken replies, and **hands-free mode** that listens again after each answer. Arabic and 12 more languages
- 📎 Attach photos and files for JARVIS to read, describe or edit
- 🗂 Built-in file browser with Quick Look preview, share, rename, delete, "Save to Photos" and "Ask JARVIS about this"
- 🗣 **Siri & Shortcuts**: "Hey Siri, ask JARVIS" works without opening the app. Other apps can use `jarvis://ask?q=...`
- 💬 Saved conversation history, retry on errors, stop button
- 🔐 Optional Face ID lock
- 🤖 Choose the model automatically (newest your key supports) or pick one yourself, plus a connection test

## Mac: what it does

**Requested features**
- Works with **Claude (API key)**, **Claude subscription** (via the official Claude Code CLI), or **Gemini**
- **Sees your screen** and **suggests things to do**
- Agent that can take actions

**Extra features**
- 👁 **Screen Watch**: checks your screen on a timer (30 s to 10 min) and gives 1–3 specific suggestions, each with a one-click action: open a link, open an app, copy text, run a command, run an AppleScript, or "Ask JARVIS"
  - Skips the check when the screen hasn't changed or you've been away, to save tokens
  - Privacy list of apps it never captures (password managers by default). JARVIS's own windows are never captured
  - Optional "current goal" so suggestions stay on topic
  - Notifications and spoken suggestions
- ⌨️ **Global hotkeys**: `⌃⌥J` opens a floating command bar, `⌃⌥S` analyzes the screen now, `⌃⌥V` starts talking
- 🧰 **Mac agent tools**: screenshot, current app and window, zsh commands, AppleScript (to control Safari, Notes, Mail, Music, Finder…), open URLs and apps, show in Finder, notifications, clipboard
- ✅ Risky actions need your approval (auto-approve is optional)
- 🍔 Menu-bar control centre, main window with chat, Screen Watch, Files and Settings
- Every iPhone file-making tool too (images, PDFs, charts, audio…), saved to `~/Documents/JARVIS`

---

## Getting the apps

### Option A: download from GitHub Actions (no Mac needed for the IPA)

Every push builds both apps on a macOS runner.

1. Open the repo on GitHub, then **Actions › Build JARVIS**, then the latest green run.
2. Download the **JARVIS-builds** artifact. It contains:
   - `JARVIS-iOS-unsigned.ipa`
   - `JARVIS-macOS.dmg` and `JARVIS-macOS.zip`

Pushing a tag such as `v1.0.0` also attaches these files to a GitHub Release.

### Installing the IPA on your iPhone

The IPA is **unsigned**, so a sideloading tool has to sign it with your Apple ID:

- **AltStore / SideStore**: open the IPA with AltStore on your phone. A free Apple ID needs a re-sign every 7 days, which AltStore does automatically
- **Sideloadly** (Windows/Mac): drag in the IPA, enter your Apple ID, click Start
- **TrollStore** (supported iOS versions only): install permanently
- **Paid Apple Developer account**: build from Xcode instead (Option B)

When it's installed, open **Settings › Developer Mode** if iOS asks, then trust the profile under **Settings › General › VPN & Device Management**.

### Installing the Mac app

Open the DMG and drag **JARVIS** to Applications. The build is ad-hoc signed, not notarized, so the first time:
**right-click JARVIS › Open › Open**. You can also run `xattr -dr com.apple.quarantine /Applications/JARVIS.app`.

### Option B: build it yourself in Xcode

```bash
brew install xcodegen
xcodegen generate        # creates JARVIS.xcodeproj
open JARVIS.xcodeproj
```

- Scheme **JARVIS** builds the iPhone app. Pick your Team under *Signing & Capabilities* and run it on your phone.
- Scheme **JARVISMac** builds the Mac app.

Requirements: Xcode 16 or newer, iOS 17+, macOS 14 (Sonoma) or newer.

---

## Setup

### Gemini API key (iPhone and Mac)
1. Get a free key at <https://aistudio.google.com/apikey>.
2. In JARVIS go to **Settings › Google Gemini** and paste it (there's a paste button), then tap **Test connection**.

The chat, image and speech models default to **Automatic**: JARVIS asks Google which models your key can use and picks the newest. You can choose specific models in Settings.

### Claude API key (optional, iPhone and Mac)
Create a key at <https://console.anthropic.com/settings/keys>, paste it under **Settings › Claude**, and choose **Claude** as the brain.
The default model is `claude-opus-5-5`, and you can set model and effort. Image generation still uses Gemini if you've added a Gemini key.

### Claude subscription (Mac)
1. Install Claude Code: <https://docs.claude.com/en/docs/claude-code/setup>
2. Run `claude` once in Terminal and sign in with your Claude Pro/Max account.
3. In JARVIS: **Settings › AI › Claude Code**, click **Check installation**, then choose **Claude Code** as the brain.

JARVIS runs the official `claude` CLI in your JARVIS folder, so requests use your subscription. Screenshots are passed to it as image files.

### Mac permissions
- **Screen Recording**: System Settings › Privacy & Security › Screen & System Audio Recording › JARVIS. Turn it back on after updating the app, because each unsigned build has a new signature.
- **Microphone & Speech Recognition**: requested the first time you talk.
- **Automation**: macOS asks the first time JARVIS controls another app.

---

## Example requests

- "Make a weekly meal plan and a shopping list CSV"
- "Draw a minimalist logo for a coffee shop called Ember, then a 16:9 banner version"
- "Turn this photo into a Ghibli-style painting" (attach a photo)
- "Write my CV as a PDF. I'm a nurse with 5 years experience…"
- "Read the story in Notes/story.txt and record it as audio with a warm voice"
- Mac: "What's wrong in this error on my screen?" or "Summarise this web page into a PDF"
- Mac: "Open my last download in Preview" or "Create a reminder for 5pm to call mum"

---

## Project layout

```
Shared/             code used by both apps
  AI/               Gemini + Claude clients, agent loop, prompts
  Core/             models, settings, Keychain, workspace folder, history
  Tools/            files, images, PDFs, charts, QR, speech, web, clipboard, calculator
  Voice/            speech recognition + speech output
  UI/               chat, message views, file browser, settings sections, theme
iOS/                iPhone app (tabs, Face ID, Photos, Siri intent, Info.plist)
macOS/              Mac app (screen capture, Screen Watch, Mac tools, hotkeys,
                    command bar, Claude Code provider, menu bar)
project.yml         XcodeGen project spec
scripts/make_icons.py  regenerates the app icons
.github/workflows/  CI that builds the IPA + Mac app
```

## Privacy
- API keys are kept in the Keychain on your device.
- Requests go straight from your device to Google or Anthropic. There is no server in between.
- Conversations are stored on-device in Application Support. Files go only to your JARVIS folder.
- On the Mac, screenshots are sent to the AI only when you turn on "see my screen", use Screen Watch, or JARVIS calls `capture_screen`.
