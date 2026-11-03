# J.A.R.V.I.S

Personal AI assistant apps for **iPhone** and **Mac**.

| | iPhone app (`.ipa`) | Mac app |
|---|---|---|
| Brain | Google Gemini (your API key), plus optional Claude, **OpenAI**, **local models** (Ollama, LM Studio…) or **Apple's on-device model** | Gemini, Claude API key, **your Claude Pro/Max subscription** (via Claude Code), **OpenAI**, **local models**, or Apple's on-device model |
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

**Voice & video calls** (pick an engine from the menu at the top of the call screen)
- 🎙 **Gemini Live**: a real-time spoken conversation. You can interrupt JARVIS mid-sentence, echo cancellation keeps it from hearing itself, and it can create files, add events and search while you talk. Transcripts are saved to your history.
  - Calls reconnect seamlessly when Google rotates the connection (session resumption).
  - Camera frames are sent at low resolution and only when the scene changes, so video calls last much longer and use far less quota.
- ⚡️ **OpenAI Realtime** (`gpt-realtime`): the alternative when Gemini's free limits are too tight. Natural voices (Cedar, Marin…), tool use during the call, and the camera view is sent each time you start talking.
- 💬 **Classic**: works with **every brain** (Claude, GPT, local models, on-device). It listens, thinks, and answers in a natural voice. With the camera on, a photo of what you're looking at goes with every sentence.
- 📷 **Live vision**: turn on the camera during a call and ask "what am I looking at?"
- 🗣 **Natural voice** for spoken replies (Gemini neural voices, e.g. Charon, Kore, Puck), with an automatic fallback to the best device voice
- 👂 **"Hey JARVIS" wake word** while the app is open (on-device recognition when available)
- Push-to-talk, hands-free mode, typing during a call, and 14 listening languages including Arabic

**Siri & Shortcuts**
- "Hey Siri, **talk to JARVIS**" opens live voice
- "**Ask JARVIS**" handles any request, speaks the answer and shows created images in a Siri card
- "**JARVIS briefing**" covers today's calendar, reminders, weather and headlines
- "**Generate an image with JARVIS**" returns the image to Shortcuts too
- "**Add a note to JARVIS**", "**Tell JARVIS to remember…**", "**Scan a document with JARVIS**"
- Shortcuts actions **Make Files with JARVIS** (returns the files for chaining) and **Process File with JARVIS** (use it from the share sheet: summarise, translate, extract text from any photo or PDF)
- Assign "Talk to JARVIS" to the **Action button**. Home-screen **quick actions** (long-press the icon). Links: `jarvis://voice`, `jarvis://briefing`, `jarvis://ask?q=…`

**Choose your brain**
- **Gemini** (default): chat, images, voices, Live voice
- **Claude** (API key)
- **OpenAI** (API key): GPT models picked automatically, plus OpenAI images and voices when there's no Gemini key
- **Local / custom server**, any OpenAI-compatible endpoint:
  - **Ollama**, **LM Studio**, **llama.cpp**, **Jan**, **vLLM**
  - or clouds like **OpenRouter, Groq, DeepSeek, Mistral, xAI, Together**
  - Presets and a **Detect servers** button are included. Models without native tool calling still make files through **prompted tools** (`<tool_call>` tags), and `<think>` reasoning is hidden.
- **On-device (Apple Intelligence)**: free, private and offline on iOS 26 / macOS 26 devices that support Apple Intelligence
- No key at all? Web search falls back to DuckDuckGo, and spoken replies use the device voice.

**Personal assistant**
- 📅 **Calendar**: add events and read your schedule. ✅ **Reminders**: add, list and complete them
- ⏲ **Timers** ("remind me in 20 minutes") as notifications
- 🌦 **Weather** for where you are or any city (Open-Meteo, no key needed)
- 🧠 **Long-term memory**: it remembers your preferences and facts ("remember I'm vegetarian"). You can view and edit them in Settings
- 🎭 **Modes**: JARVIS, Tutor, Interpreter (live translation), Writer, Coder, Life coach, Brainstorm, Chef
- 🏠 **Run your Shortcuts**: "JARVIS, run Good Night" covers HomeKit scenes, automations and anything you've built in Shortcuts
- ✉️ **Email & iMessage** drafts with attachments ("email the PDF to Sam"), with 👤 **contact lookup**
- 🎵 **Music control**: play, pause, skip, what's playing, or play an artist from your library
- 📤 **Export chats** as Markdown or PDF, and 🔎 **search** your conversation history

**Making files**
- 🖼 Images, plus **image editing** ("remove the background", "make it watercolour") with your photos as references
- 📄 **PDF documents**, 📊 **charts**, 🔊 **audio files** (30 voices), 🔳 **QR codes**, 📅 `.ics` and 👤 `.vcf`
- 📑 **Document scanner** with edge detection that saves a PDF and the text, using **on-device OCR** (`extract_text` reads text from any photo or scan)
- 📸 Take a photo or attach photos and files. **"Share to JARVIS"** from any app's share sheet
- 🗜 Zip folders, and move, copy, rename, edit or append to files
- 🌐 Web search with sources, read web pages, download files

**Limits & reliability**
- Waits and retries automatically when a service says "slow down", using the delay the server suggests
- Gemini drops to its **Lite** model (much higher free limits) when the main model is rate-limited
- **Backup brain**: when one brain is out of quota, another takes over (e.g. a local Ollama model, which has no limits). Choose it under Settings › Limits
- **Usage meter**: requests and tokens per brain, today and for the last 7 days

**App**
- 👋 First-run setup: pick a brain, paste a key, test it
- ⚡️ **Streaming replies**: text appears as it's written
- Message actions: copy, read aloud, share, regenerate
- File browser with list and **gallery** views, Quick Look, share, rename, "Save to Photos" and "Ask JARVIS about this"
- Conversation history, retry, stop, optional Face ID lock, automatic model choice

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
- ⌨️ **Global hotkeys**: `⌃⌥J` opens a floating command bar, `⌃⌥S` analyzes the screen now, `⌃⌥V` starts talking, `⌃⌥C` gets help with whatever is on your clipboard
- 🦙 **Local models**: point JARVIS at Ollama or LM Studio on `localhost` (auto-detected) for fully private chat and Screen Watch
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

Requirements: Xcode 16 or newer (Xcode 26 to include Apple's on-device model), iOS 17+, macOS 14 (Sonoma) or newer.

---

## Setup

### Gemini API key (iPhone and Mac)
1. Get a free key at <https://aistudio.google.com/apikey>.
2. In JARVIS go to **Settings › Google Gemini** and paste it (there's a paste button), then tap **Test connection**.

The chat, image and speech models default to **Automatic**: JARVIS asks Google which models your key can use and picks the newest. You can choose specific models in Settings.

### Claude API key (optional, iPhone and Mac)
Create a key at <https://console.anthropic.com/settings/keys>, paste it under **Settings › Claude**, and choose **Claude** as the brain.
The default model is `claude-opus-5-5`, and you can set model and effort. Image generation still uses Gemini if you've added a Gemini key.

### OpenAI (optional)
Create a key at <https://platform.openai.com/api-keys>, paste it under **Settings › OpenAI**, and choose **OpenAI** as the brain. "Automatic" picks the newest GPT chat model your key can use.

### Local models: Ollama, LM Studio, etc. (optional)
1. Mac: install [Ollama](https://ollama.com) and run `ollama pull qwen3` (any tool-capable model works). Or start LM Studio's local server.
2. In JARVIS go to **Settings › Local & custom models**, click **Detect servers** (or pick a preset), then **Load models**. Choose **Local** as the brain.
3. **From iPhone**: run Ollama on your Mac with `OLLAMA_HOST=0.0.0.0 ollama serve` and enter `http://<your-Mac-IP>:11434/v1`. iOS asks for Local Network permission the first time.
4. If a model can't call tools natively, set **Tool use** to *Prompted*. JARVIS also switches to prompted mode automatically when the server says tools aren't supported.

### Apple Intelligence (optional)
On an Apple Intelligence–capable iPhone or Mac running iOS/macOS 26 with Apple Intelligence on, choose **On-device** as the brain. It needs no key and works offline.

### Claude subscription (Mac)
1. Install Claude Code: <https://docs.claude.com/en/docs/claude-code/setup>
2. Run `claude` once in Terminal and sign in with your Claude Pro/Max account.
3. In JARVIS: **Settings › AI › Claude Code**, click **Check installation**, then choose **Claude Code** as the brain.

JARVIS runs the official `claude` CLI in your JARVIS folder, so requests use your subscription. Screenshots are passed to it as image files.

### If calls or limits are a problem
- **Video calls cut out**: update to this version. Gemini Live calls now resume automatically and the camera uses about 8× fewer tokens. If your key's live quota is used up, switch the call to **OpenAI Realtime** or **Classic** from the menu at the top of the call screen.
- **"Rate-limited" or "quota" errors**: set a **backup brain** under Settings › Limits. A local model via Ollama has no limits. A paid Gemini or OpenAI key raises limits a lot.
- Settings › Usage shows how many requests each brain used today. Each tool step counts as a request.

### iPhone permissions
JARVIS asks for permission the first time it needs each one: microphone and speech, camera, Photos (to save images), Calendars, Reminders, Contacts, Media library (music), Location (weather), Local Network (local model servers) and Notifications (timers). Live voice keeps running if you lock the screen during a call.

### Mac permissions
- **Screen Recording**: System Settings › Privacy & Security › Screen & System Audio Recording › JARVIS. Turn it back on after updating the app, because each unsigned build has a new signature.
- **Microphone & Speech Recognition**: requested the first time you talk.
- **Automation**: macOS asks the first time JARVIS controls another app.

---

## Example requests

- "Make a weekly meal plan and a shopping list CSV"
- "Draw a minimalist logo for a coffee shop called Ember, then a 16:9 banner version"
- "Turn this photo into a watercolour painting" (attach a photo)
- "Add dentist on Friday at 3pm and remind me the day before"
- "What's the weather this weekend in Dubai?"
- Voice mode with camera: "What plant is this and how often should I water it?"
- "Write my CV as a PDF. I'm a nurse with 5 years experience…"
- "Read the story in Notes/story.txt and record it as audio with a warm voice"
- Mac: "What's wrong in this error on my screen?" or "Summarise this web page into a PDF"
- Mac: "Open my last download in Preview" or "Create a reminder for 5pm to call mum"

---

## Tests

CI runs a macOS unit-test suite (`Tests/`) before building. It covers:
- the Gemini and Claude request and response formats, including tool-call round trips and thinking and thought-signature replay
- workspace path safety and the calculator
- the file tools (create, append, edit, move, zip)
- PDF, chart and QR generation

To also run **live API round trips** on every push, add repository secrets named
`GEMINI_API_KEY` and/or `ANTHROPIC_API_KEY` (Settings › Secrets and variables › Actions). Without them those tests are skipped.

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
Tests/              macOS unit tests + optional live API tests
project.yml         XcodeGen project spec
scripts/make_icons.py  regenerates the app icons
.github/workflows/  CI that builds the IPA + Mac app
```

## Privacy
- API keys are kept in the Keychain on your device.
- Requests go straight from your device to Google or Anthropic. There is no server in between.
- Conversations are stored on-device in Application Support. Files go only to your JARVIS folder.
- On the Mac, screenshots are sent to the AI only when you turn on "see my screen", use Screen Watch, or JARVIS calls `capture_screen`.
