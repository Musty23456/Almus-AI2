# Using voice input and attachments (ALMUS AI 0.11.0)

## Voice input
1. Tap the microphone next to the message box. The first time, a short explanation appears: ALMUS AI never records or
   uploads your voice, but your phone's speech service (for example Speech Services by Google) listens and may send
   audio to its provider to turn it into text. Choose "I understand, continue" or "Not now".
2. Allow the microphone when Android asks.
3. Wait for "Listening (English)…" (it says "Starting the microphone…" until the phone is really ready), then speak.
4. Tap **Done** to finish, or **Cancel** to throw the words away. "Processing what you said…" shows while the phone finishes.
5. The recognized words appear in a **"Heard"** box and in the message box. Nothing is sent. Edit them, press **Retry**
   to speak again, **Discard** to remove them, or press Send.
6. Language: tap **EN / HA** next to the microphone. Hausa works only if the speech engine on your phone supports it
   (install or download the Hausa language in the phone's voice-typing settings). ALMUS AI cannot add it.

If it does not work
* "Microphone permission": Android Settings → Apps → ALMUS AI → Permissions → Microphone → Allow.
* "Speech service did not start" / "not available": install or enable **Speech Services by Google** (or another
  voice-typing app) and make sure it is allowed to run in the background; then try again. Emulators often have no
  speech service.
* "Hausa is not installed": switch to English or install Hausa for your phone's speech engine.
* Nothing heard: speak closer, check the phone's microphone, try again.

## Attachments
Tap the paperclip next to the message box and choose: **image**, **take photo**, **document**, **PDF**, **text file**, or
**CSV/spreadsheet**. Up to 5 files per message, 10 MB each.

* Each file shows a thumbnail or icon, its name, type, size and status. The ✕ removes it.
* Files stay on your phone. **Nothing is uploaded until you press Send.** Only the *text* found in a document is sent
  to the AI (never the file itself, never its location on your phone).
* Readable on the phone: TXT, Markdown, LOG, JSON, CSV/TSV, DOCX, XLSX, and PDFs that contain selectable text.
* **Not analyzed**: images (the AI connection only receives text), scanned PDFs (no OCR), password-protected PDFs,
  old .doc/.xls/.ppt files. Before sending, the app lists such files and asks: Cancel, Remove them, or Send anyway.
  With "Send anyway" the AI does not see them, and your message says "NOT analyzed".
* A file whose name does not match its content (for example a Word file renamed to .pdf) is refused. Renaming does
  not convert a file: export it in the right format.
* In DEMO MODE no file is read at all.
* Long documents are shortened (30,000 characters per file, 60,000 per message) and marked "shortened".
* After sending, the chat bubble shows the files and whether each one was read. The stored message also lists them,
  so backups contain that list (not the file contents).
