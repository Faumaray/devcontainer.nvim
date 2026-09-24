#!/usr/bin/env python3
"""Tiny debug adapter (stdio, or TCP with --port N): answers initialize/launch/stackTrace/disconnect and asks the client
to runInTerminal, so tests/e2e.lua can check the proxy's path translation."""
import json
import os
import sys

inp, out = sys.stdin.buffer, sys.stdout.buffer
if "--port" in sys.argv:
    # server mode (like codelldb / delve): speak DAP over one TCP connection
    import socket
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])))
    srv.listen(1)
    print("listening", flush=True)
    conn, _ = srv.accept()
    inp, out = conn.makefile("rb"), conn.makefile("wb")
seq = 0


def send(msg):
    global seq
    seq += 1
    msg["seq"] = seq
    body = json.dumps(msg).encode()
    out.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    out.flush()


def read():
    length = None
    while True:
        line = inp.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        k, _, v = line.decode().partition(":")
        if k.lower() == "content-length":
            length = int(v)
    return json.loads(inp.read(length))


while True:
    msg = read()
    if msg is None:
        break
    if msg.get("type") != "request":
        if msg.get("type") == "response" and msg.get("command") == "runInTerminal":
            send({"type": "event", "event": "output", "body": {"output": json.dumps(msg.get("body"))}})
        continue
    cmd = msg["command"]
    reply = {"type": "response", "request_seq": msg["seq"], "command": cmd, "success": True}
    if cmd == "initialize":
        reply["body"] = {"supportsConfigurationDoneRequest": True}
    elif cmd == "launch":
        a = msg["arguments"]
        send(reply)
        # "output" is passed verbatim by the proxy: shows what the adapter really received
        send({"type": "event", "event": "output",
              "body": {"category": "seen", "output": json.dumps({"args": a, "cwd": os.environ.get("PWD", os.getcwd())})}})
        send({"type": "request", "command": "runInTerminal",
              "arguments": {"kind": "integrated", "cwd": a.get("cwd", ""), "args": [a["program"], "--flag"]}})
        continue
    elif cmd == "stackTrace":
        reply["body"] = {"stackFrames": [
            {"id": 1, "name": "main", "line": 3, "column": 1,
             "source": {"path": os.path.join(os.environ.get("PWD", os.getcwd()), "main.cpp")}},
            {"id": 2, "name": "std::vector", "line": 1, "column": 1,
             "source": {"path": "/usr/include/stdio.h"}},
        ], "totalFrames": 2}
    elif cmd == "disconnect":
        send(reply)
        break
    send(reply)
