#!/usr/bin/env python3
"""Sign or verify a release's SHA256SUMS -- the one format both updaters check.

    sign-release.py sign   <private-key.pem> <SHA256SUMS>   # writes SHA256SUMS.sig
    sign-release.py verify <public-key-b64>  <SHA256SUMS>   # checks SHA256SUMS.sig

The signature is ECDSA P-256 over SHA-256 of the file's exact bytes, written as
base64 of the raw 64-byte r||s pair and a newline. Raw rather than DER because
that is what both verifiers take natively: CryptoKit's
P256.Signing.ECDSASignature(rawRepresentation:) on the Mac and
BCryptVerifySignature on Windows. The public key is base64 of the 65-byte
uncompressed X9.63 point (04 || X || Y). See docs/updates.md.

Needs the `cryptography` package (pip install cryptography).
"""
import base64
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import (
    decode_dss_signature, encode_dss_signature)


def sign(key_path, sums_path):
    with open(key_path, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        sys.exit("the signing key must be an ECDSA P-256 private key")
    data = open(sums_path, "rb").read()
    r, s = decode_dss_signature(key.sign(data, ec.ECDSA(hashes.SHA256())))
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    with open(sums_path + ".sig", "w") as f:
        f.write(base64.b64encode(raw).decode() + "\n")
    print(f"signed {sums_path} -> {sums_path}.sig")


def verify(public_b64, sums_path):
    point = base64.b64decode(public_b64.strip())
    key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), point)
    raw = base64.b64decode(open(sums_path + ".sig").read().strip())
    if len(raw) != 64:
        sys.exit("signature is not 64 bytes")
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    try:
        key.verify(der, open(sums_path, "rb").read(), ec.ECDSA(hashes.SHA256()))
    except InvalidSignature:
        sys.exit("BAD SIGNATURE")
    print("signature OK")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("sign", "verify"):
        sys.exit(__doc__)
    (sign if sys.argv[1] == "sign" else verify)(sys.argv[2], sys.argv[3])
