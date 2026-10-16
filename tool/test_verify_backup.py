"""Tests for tool/verify_backup.py. They build backups exactly as
docs/BACKUP_FORMAT.md describes (independently of the Dart code)."""
import base64
import hashlib
import io
import json
import os
import struct
import unittest
import zipfile

try:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
except ImportError:  # the Python 'cryptography' package is optional
    raise unittest.SkipTest("python 'cryptography' package not installed")

import verify_backup as vb

HAUSA = "Ɓarna ɗan ƙasa ƴar uwa 你好 🌍"


def make_zip(conv_count=2, tamper=False, schema=1):
    convs = []
    for i in range(conv_count):
        cid = f"c{i}"
        convs.append({
            "id": cid, "title": "T", "created_at": "2026-01-01T10:00:00.000Z",
            "updated_at": "2026-01-01T10:01:00.000Z", "message_count": 2, "metadata": {},
            "messages": [
                {"id": f"{cid}-m{j}", "conversation_id": cid, "index": j,
                 "role": "user" if j % 2 == 0 else "assistant", "content": HAUSA,
                 "created_at": "2026-01-01T10:00:00.000Z", "status": "sent",
                 "engine": "DEMO", "attachments": []} for j in range(2)],
        })
    files = {
        "data/conversations.json": json.dumps({"schema_version": 1, "conversations": convs}).encode(),
        "data/memories.json": json.dumps({"schema_version": 1, "memories": []}).encode(),
    }
    manifest = {
        "format": "almus-ai-backup", "schema_version": schema,
        "app": {"name": "ALMUS AI", "version": "0.10.0", "build": "10"},
        "created_at": "2026-01-01T12:00:00.000Z", "encryption": "none",
        "contents": {"conversations": conv_count, "messages": conv_count * 2, "memories": 0,
                     "settings": False, "attachments": 0},
        "files": [{"path": k, "sha256": hashlib.sha256(v).hexdigest(), "bytes": len(v)}
                  for k, v in files.items()],
    }
    if tamper:
        files["data/conversations.json"] = files["data/conversations.json"].replace(b"c0", b"cX")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(manifest))
        for k, v in files.items():
            z.writestr(k, v)
    return buf.getvalue()


def encrypt(plain, password, iterations=1000):
    salt, nonce = os.urandom(16), os.urandom(12)
    header = json.dumps({
        "format": "almus-ai-encrypted-backup", "envelope_version": 1, "cipher": "AES-256-GCM",
        "kdf": "PBKDF2-HMAC-SHA256", "kdf_iterations": iterations,
        "salt": base64.b64encode(salt).decode(), "nonce": base64.b64encode(nonce).decode(),
    }, separators=(",", ":")).encode()
    prefix = vb.MAGIC + b"\x01" + struct.pack(">I", len(header)) + header
    key = PBKDF2HMAC(hashes.SHA256(), 32, salt, iterations).derive(password.encode())
    return prefix + AESGCM(key).encrypt(nonce, plain, prefix)


class VerifyTests(unittest.TestCase):
    def test_valid_zip(self):
        r = vb.verify_file(make_zip(3))
        self.assertEqual((r["conversations"], r["messages"], r["encrypted"]), (3, 6, False))

    def test_empty_backup(self):
        r = vb.verify_file(make_zip(0))
        self.assertEqual((r["conversations"], r["messages"]), (0, 0))

    def test_tampered_data_detected(self):
        with self.assertRaisesRegex(vb.BackupError, "checksum"):
            vb.verify_file(make_zip(tamper=True))

    def test_truncated_zip_detected(self):
        data = make_zip()
        with self.assertRaises(vb.BackupError):
            vb.verify_file(data[: len(data) // 2])

    def test_future_schema_refused(self):
        with self.assertRaisesRegex(vb.BackupError, "schema_version"):
            vb.verify_file(make_zip(schema=9))

    def test_not_a_backup(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("a.txt", "x")
        with self.assertRaisesRegex(vb.BackupError, "manifest"):
            vb.verify_file(buf.getvalue())

    def test_encrypted_round_trip(self):
        enc = encrypt(make_zip(2), "correct horse")
        self.assertNotIn(HAUSA.encode(), enc)
        r = vb.verify_file(enc, "correct horse")
        self.assertTrue(r["encrypted"])
        self.assertEqual(r["messages"], 4)

    def test_wrong_password(self):
        with self.assertRaisesRegex(vb.BackupError, "wrong password"):
            vb.verify_file(encrypt(make_zip(), "right-password"), "wrong-password")

    def test_password_required(self):
        with self.assertRaisesRegex(vb.BackupError, "password required"):
            vb.verify_file(encrypt(make_zip(), "right-password"))

    def test_header_tamper_and_bit_flip_rejected(self):
        enc = bytearray(encrypt(make_zip(), "right-password"))
        flipped = bytes(enc[:-20] + bytes([enc[-20] ^ 1]) + enc[-19:])
        with self.assertRaises(vb.BackupError):
            vb.verify_file(flipped, "right-password")
        text = bytes(enc)
        at = text.index(b'"envelope_version":1') + len('"envelope_version":')
        edited = text[:at] + b"2" + text[at + 1:]
        with self.assertRaises(vb.BackupError):
            vb.verify_file(edited, "right-password")

    def test_truncated_encrypted(self):
        with self.assertRaises(vb.BackupError):
            vb.verify_file(encrypt(make_zip(), "right-password")[:30], "right-password")


if __name__ == "__main__":
    unittest.main()
