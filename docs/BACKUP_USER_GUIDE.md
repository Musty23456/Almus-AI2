# Backing up and restoring your ALMUS AI data

## Make a backup
1. Open **Settings → Backup & Restore**.
2. Tap **Create complete backup**.
3. Choose **Protect with a password** (recommended) and type the password twice.
   There is no password recovery: write it down somewhere safe.
4. Android's "save" screen opens. Choose a place **outside** ALMUS AI: *Downloads*, a memory
   card, or a cloud app you already use (Google Drive, etc.). Nothing is uploaded by ALMUS AI.
5. Wait for "Backup saved". The file is `almus-backup-…-ENCRYPTED.almusenc`
   (or `…-unencrypted.zip` if you switched the password off — anyone with that file can read your chats).

Other options: *Export all conversations*, *Export selected conversations* (JSON, Markdown or
text) and *Export personal memory*. These exports are never encrypted.

## Restore after reinstalling the phone or the app
Android deletes the app's private storage (chats, memories) when you uninstall it, and ALMUS AI
switches off Android's automatic backup. Only a file you saved yourself survives.
1. Install ALMUS AI again and open **Settings → Backup & Restore → Import backup**.
2. Pick your backup file in Android's file screen.
3. For an encrypted backup type the password. A wrong password never changes anything.
4. Read the **Restore preview**: what the file contains, what is new and what is already on the phone.
5. Choose **Merge** (keep what is on the phone, add what is missing) or **Replace**
   (delete the selected data on the phone first). Replace asks for confirmation and offers to save a
   safety backup of your current data first.
6. Wait for "Import finished". If anything fails, nothing is changed.

Tip: test your backup once (Import → look at the preview → Cancel).

## Checking a backup on a computer (optional)
`python3 tool/verify_backup.py file.zip` (add `--password '…'` for `.almusenc`, needs `pip install cryptography`).
