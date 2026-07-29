# A host that is not SolStream, to see what the client says to it.
#
# Two cases, and the second is the one that matters:
#   with-challenge  -> the client must send a proof and never the token
#   no-challenge    -> the client must REFUSE, because an agent with no challenge
#                      and an impersonator with no challenge are indistinguishable
import socket, sys, json, secrets, hmac, hashlib

mode = sys.argv[1]
TOKEN = "00112233445566778899aabbccddeeff"
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 47630)); srv.listen(1)
print(f"[fake host] listening, mode={mode}", flush=True)
conn, _ = srv.accept()
challenge = secrets.token_hex(32)
hello = {"type": "hello", "version": 2, "host": "FAKEHOST",
         "needsAuth": True, "sunshineInstance": "0"}
if mode == "with-challenge":
    hello["challenge"] = challenge
conn.sendall((json.dumps(hello) + "\n").encode())

conn.settimeout(6)
buf = b""
try:
    while b"\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            print("[fake host] client closed without sending anything", flush=True)
            break
        buf += chunk
except socket.timeout:
    print("[fake host] client sent NOTHING in 6s", flush=True)

line = buf.split(b"\n")[0].decode(errors="replace") if buf else ""
print(f"[fake host] client sent: {line}", flush=True)
if line:
    print(f"[fake host] CONTAINS THE TOKEN: {TOKEN in line}", flush=True)
    try:
        msg = json.loads(line)
        if "proof" in msg and "cnonce" in msg:
            want = hmac.new(bytes.fromhex(TOKEN),
                            b"SolStream agent auth v2" + bytes.fromhex(challenge)
                            + bytes.fromhex(msg["cnonce"]), hashlib.sha256).hexdigest()
            print(f"[fake host] proof verifies: {want == msg['proof']}", flush=True)
    except Exception as e:
        print(f"[fake host] not JSON: {e}", flush=True)
conn.close(); srv.close()
