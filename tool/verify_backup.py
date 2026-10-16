#!/usr/bin/env python3
"""Independent checker for ALMUS AI backups (see docs/BACKUP_FORMAT.md).

It re-implements the file format from the documentation, separately from the
Dart code, so a backup can be inspected on a computer without the app.

  python3 tool/verify_backup.py backup.zip
  python3 tool/verify_backup.py backup.almusenc --password 'your password'

Encrypted files need:  pip install cryptography
"""
import argparse
import base64
import hashlib
import io
import json
import struct
import sys
import zipfile

MAGIC = b"ALMUSENC"
SCHEMA = 1


class BackupError(Exception):
    pass


def decrypt_envelope(data: bytes, password: str) -> bytes:
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

    if not data.startswith(MAGIC) or len(data) < 8 + 5 + 16:
        raise BackupError("not an ALMUS encrypted backup")
    if data[8] != 1:
        raise BackupError("unsupported envelope version")
    (hlen,) = struct.unpack(">I", data[9:13])
    if hlen <= 0 or hlen > 4096 or 13 + hlen + 16 > len(data):
        raise BackupError("damaged header")
    prefix = data[: 13 + hlen]
    header = json.loads(data[13 : 13 + hlen].decode("utf-8"))
    if header.get("cipher") != "AES-256-GCM" or header.get("kdf") != "PBKDF2-HMAC-SHA256":
        raise BackupError("unsupported algorithm")
    iterations = header["kdf_iterations"]
    if not isinstance(iterations, int) or not 1000 <= iterations <= 5_000_000:
        raise BackupError("unreasonable iteration count")
    salt = base64.b64decode(header["salt"])
    nonce = base64.b64decode(header["nonce"])
    key = PBKDF2HMAC(hashes.SHA256(), 32, salt, iterations).derive(password.encode("utf-8"))
    try:
        # AESGCM expects ciphertext || tag, which is exactly how the file ends.
        return AESGCM(key).decrypt(nonce, data[13 + hlen :], prefix)
    except InvalidTag:
        raise BackupError("wrong password or damaged file")


def verify_zip(data: bytes) -> dict:
    try:
        zf = zipfile.ZipFile(io.BytesIO(data))
        bad = zf.testzip()
    except zipfile.BadZipFile as e:
        raise BackupError(f"damaged ZIP: {e}")
    if bad:
        raise BackupError(f"damaged ZIP entry: {bad}")
    try:
        manifest = json.loads(zf.read("manifest.json"))
    except KeyError:
        raise BackupError("manifest.json is missing")
    if manifest.get("format") != "almus-ai-backup":
        raise BackupError("not an ALMUS AI backup")
    if not isinstance(manifest.get("schema_version"), int) or manifest["schema_version"] > SCHEMA:
        raise BackupError("unsupported schema_version")
    docs = {}
    for item in manifest["files"]:
        try:
            raw = zf.read(item["path"])
        except KeyError:
            raise BackupError(f"missing {item['path']}")
        if hashlib.sha256(raw).hexdigest() != item["sha256"].lower() or len(raw) != item["bytes"]:
            raise BackupError(f"checksum mismatch: {item['path']}")
        docs[item["path"]] = json.loads(raw.decode("utf-8"))
    convs = docs.get("data/conversations.json", {}).get("conversations", [])
    mems = docs.get("data/memories.json", {}).get("memories", [])
    messages = sum(len(c["messages"]) for c in convs)
    c = manifest["contents"]
    if (c["conversations"], c["messages"], c["memories"]) != (len(convs), messages, len(mems)):
        raise BackupError("manifest counts do not match the data")
    ids = [m["id"] for conv in convs for m in conv["messages"]]
    if len(ids) != len(set(ids)):
        raise BackupError("duplicate message ids")
    for conv in convs:
        for m in conv["messages"]:
            if m["conversation_id"] != conv["id"] or m["role"] not in ("user", "assistant"):
                raise BackupError("broken relationship or role")
    return {
        "schema_version": manifest["schema_version"],
        "app_version": manifest.get("app", {}).get("version"),
        "created_at": manifest.get("created_at"),
        "conversations": len(convs),
        "messages": messages,
        "memories": len(mems),
        "has_settings": "data/settings.json" in docs,
    }


def verify_file(data: bytes, password: str = None) -> dict:
    encrypted = data.startswith(MAGIC)
    if encrypted:
        if not password:
            raise BackupError("password required")
        data = decrypt_envelope(data, password)
    result = verify_zip(data)
    result["encrypted"] = encrypted
    return result


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("file")
    p.add_argument("--password")
    args = p.parse_args(argv)
    try:
        with open(args.file, "rb") as f:
            result = verify_file(f.read(), args.password)
    except BackupError as e:
        print(f"INVALID: {e}")
        return 1
    print("OK", json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
