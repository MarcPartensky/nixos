"""P-256 ECDSA verification, DER signatures, CBOR + COSE keys. Stdlib only.

Serves two channels of the broker:
  - Secure Enclave (Mac): verifies an ECDSA-SHA256 DER signature over a nonce.
  - WebAuthn (phone): parses the COSE public key from attestation and verifies
    the assertion signature over authData || sha256(clientDataJSON).

No openssl, no cryptography package: the whole curve is implemented here so the
broker stays dependency-free on NixOS.
"""

import hashlib
import hmac
import struct

# --- curve ------------------------------------------------------------------

P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
A = P - 3
B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5


def _inv(a, m=P):
    return pow(a, -1, m)


def _add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        lam = (3 * x1 * x1 + A) * _inv(2 * y1) % P
    else:
        lam = (y2 - y1) * _inv(x2 - x1) % P
    x3 = (lam * lam - x1 - x2) % P
    return (x3, (lam * (x1 - x3) - y1) % P)


def _mul(k, point):
    result = None
    addend = point
    while k:
        if k & 1:
            result = _add(result, addend)
        addend = _add(addend, addend)
        k >>= 1
    return result


G = (GX, GY)


def point_from_bytes(raw):
    """Uncompressed SEC1 point (0x04 || X || Y), 65 bytes."""
    if len(raw) == 65 and raw[0] == 4:
        return (int.from_bytes(raw[1:33], "big"), int.from_bytes(raw[33:], "big"))
    if len(raw) == 64:
        return (int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    raise ValueError("bad point encoding (%d bytes)" % len(raw))


def point_to_bytes(point):
    return b"\x04" + point[0].to_bytes(32, "big") + point[1].to_bytes(32, "big")


def on_curve(point):
    x, y = point
    return (y * y - (x * x * x + A * x + B)) % P == 0


# --- DER ---------------------------------------------------------------------


def parse_der_signature(der):
    """ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }"""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER sequence")
    total = der[1]
    if total & 0x80:
        nbytes = total & 0x7F
        total = int.from_bytes(der[2 : 2 + nbytes], "big")
        off = 2 + nbytes
    else:
        off = 2
    if der[off] != 0x02:
        raise ValueError("expected INTEGER for r")
    rlen = der[off + 1]
    r = int.from_bytes(der[off + 2 : off + 2 + rlen], "big")
    off = off + 2 + rlen
    if der[off] != 0x02:
        raise ValueError("expected INTEGER for s")
    slen = der[off + 1]
    s = int.from_bytes(der[off + 2 : off + 2 + slen], "big")
    return r, s


def encode_der_signature(r, s):
    def enc(v):
        b = v.to_bytes((v.bit_length() + 7) // 8 or 1, "big")
        if b[0] & 0x80:
            b = b"\x00" + b
        return b"\x02" + bytes([len(b)]) + b

    body = enc(r) + enc(s)
    return b"\x30" + bytes([len(body)]) + body


# --- verify ------------------------------------------------------------------


def verify_digest(point, digest, r, s):
    if not (1 <= r < N and 1 <= s < N):
        return False
    if point is None or not on_curve(point):
        return False
    w = _inv(s, N)
    u1 = int.from_bytes(digest, "big") * w % N
    u2 = r * w % N
    pt = _add(_mul(u1, G), _mul(u2, point))
    if pt is None:
        return False
    return pt[0] % N == r


def verify_ecdsa_sha256(point, message, der_signature):
    """Verify an ECDSA P-256 / SHA-256 signature (DER encoded)."""
    try:
        r, s = parse_der_signature(der_signature)
    except ValueError:
        return False
    return verify_digest(point, hashlib.sha256(message).digest(), r, s)


# --- CBOR (minimal, sufficient for WebAuthn) --------------------------------

class CBORError(ValueError):
    pass


def cbor_decode(data, offset=0):
    """Returns (value, next_offset). Supports the subset WebAuthn emits."""
    if offset >= len(data):
        raise CBORError("truncated")
    initial = data[offset]
    major, info = initial >> 5, initial & 0x1F
    offset += 1

    def read_len(info, offset):
        if info < 24:
            return info, offset
        if info == 24:
            return data[offset], offset + 1
        if info == 25:
            return int.from_bytes(data[offset : offset + 2], "big"), offset + 2
        if info == 26:
            return int.from_bytes(data[offset : offset + 4], "big"), offset + 4
        if info == 27:
            return int.from_bytes(data[offset : offset + 8], "big"), offset + 8
        if info == 31:
            return None, offset
        raise CBORError("reserved length info %d" % info)

    if major in (0, 1):
        value, offset = read_len(info, offset)
        return (value if major == 0 else -1 - value), offset
    if major in (2, 3):
        length, offset = read_len(info, offset)
        if length is None:  # indefinite
            chunks = []
            while True:
                if data[offset] == 0xFF:
                    offset += 1
                    break
                chunk, offset = cbor_decode(data, offset)
                chunks.append(chunk)
            joined = b"".join(chunks) if major == 2 else "".join(chunks)
            return joined, offset
        raw = data[offset : offset + length]
        if len(raw) != length:
            raise CBORError("truncated string")
        return (raw if major == 2 else raw.decode("utf-8")), offset + length
    if major == 4:
        length, offset = read_len(info, offset)
        if length is None:
            items = []
            while True:
                if data[offset] == 0xFF:
                    offset += 1
                    break
                item, offset = cbor_decode(data, offset)
                items.append(item)
            return items, offset
        items = []
        for _ in range(length):
            item, offset = cbor_decode(data, offset)
            items.append(item)
        return items, offset
    if major == 5:
        length, offset = read_len(info, offset)
        out = {}
        for _ in range(length or 0):
            key, offset = cbor_decode(data, offset)
            value, offset = cbor_decode(data, offset)
            out[key] = value
        return out, offset
    if major == 6:  # tag: skip it, return the tagged value
        _, offset = read_len(info, offset)
        return cbor_decode(data, offset)
    if major == 7:
        if info == 20:
            return False, offset
        if info == 21:
            return True, offset
        if info in (22, 23):
            return None, offset
        if info == 25:
            return struct.unpack(">e", data[offset : offset + 2])[0], offset + 2
        if info == 26:
            return struct.unpack(">f", data[offset : offset + 4])[0], offset + 4
        if info == 27:
            return struct.unpack(">d", data[offset : offset + 8])[0], offset + 8
        if info == 24:
            return data[offset], offset + 1
        raise CBORError("simple value %d unsupported" % info)
    raise CBORError("major type %d unsupported" % major)


def cose_to_point(cose):
    """COSE_Key (EC2 / ES256) dict -> P-256 point."""
    kty = cose.get(1)
    if kty != 2:
        raise ValueError("only EC2 keys accepted (kty=%r)" % (kty,))
    alg = cose.get(3)
    if alg is not None and alg != -7:
        raise ValueError("only ES256 accepted (alg=%r)" % (alg,))
    crv = cose.get(-1)
    if crv != 1:
        raise ValueError("only P-256 accepted (crv=%r)" % (crv,))
    x, y = cose.get(-2), cose.get(-3)
    if not isinstance(x, bytes) or not isinstance(y, bytes):
        raise ValueError("missing x/y")
    return (int.from_bytes(x, "big"), int.from_bytes(y, "big"))


# --- self test ---------------------------------------------------------------


def _selftest():
    # RFC 6979 A.2.5 vector: P-256, message "sample", key below.
    d = 0xC9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721
    point = _mul(d, G)
    assert point_to_bytes(point).hex() == (
        "04" "60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6"
        "7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299"
    ), point_to_bytes(point).hex()

    # Deterministic-ish sign check: k from a fixed value, compare to expected r,s
    # computed independently by the reference vector is not reproducible here,
    # so instead round-trip: sign with fixed k then verify with the library.
    msg = b"sample"
    digest = hashlib.sha256(msg).digest()
    k = 0xA6E3C57DD01ABE90086538398355DD4C3B17AA873382B0F24D6129493D8AAD60
    r = (_mul(k, G)[0]) % N
    s = (_inv(k, N) * (int.from_bytes(digest, "big") + r * d)) % N
    sig = encode_der_signature(r, s)
    assert verify_ecdsa_sha256(point, msg, sig), "round-trip verify failed"
    assert not verify_ecdsa_sha256(point, b"sampl3", sig), "must reject tampered message"
    assert not verify_ecdsa_sha256(_mul(2, G), msg, sig), "must reject wrong key"

    # Signature malleability guard: s and N-s are both valid ECDSA; we accept
    # both (WebAuthn and the Secure Enclave do not normalise), documented here.
    assert verify_ecdsa_sha256(point, msg, encode_der_signature(r, N - s))

    # CBOR: {"a": h'0102', "b": [1, -1], 3: true}
    raw = bytes.fromhex("a3" "6161" "420102" "6162" "820120" "03" "f5")
    value, used = cbor_decode(raw)
    assert value == {"a": b"\x01\x02", "b": [1, -1], 3: True}, value
    assert used == len(raw)

    # COSE key decoding round trip.
    key_cose = {1: 2, 3: -7, -1: 1, -2: point[0].to_bytes(32, "big"), -3: point[1].to_bytes(32, "big")}
    assert cose_to_point(key_cose) == point

    print("p256 self-test: OK")


if __name__ == "__main__":
    _selftest()
