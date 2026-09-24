#!/usr/bin/env python3
"""Minimal stand-in for the docker CLI used by tests/e2e.lua.

The "container" is the host itself; `exec` runs the command in a private mount namespace where
the host workspace is bind-mounted at the container workspace path (FAKE_DOCKER_BIND).
Every invocation is appended to $FAKE_DOCKER_LOG.
"""
import hashlib
import json
import os
import sys

STATE = os.environ.get("FAKE_DOCKER_STATE", "/tmp/fake-docker-state.json")
LOG = os.environ.get("FAKE_DOCKER_LOG", "/tmp/fake-docker.log")
CID = "fc0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd"

args = sys.argv[1:]
with open(LOG, "a") as f:
    f.write(json.dumps(args) + "\n")


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save(s):
    with open(STATE, "w") as f:
        json.dump(s, f)


cmd = args[0] if args else ""
rest = args[1:]

if cmd == "ps":
    s = load()
    if s.get("id"):
        print(f"{s['id'][:12]} {'running' if s.get('running') else 'exited'}")
elif cmd == "run":
    # a distinct id per workspace (the labels contain the local folder)
    cid = CID if not os.environ.get("FAKE_DOCKER_UNIQUE") else hashlib.sha256(" ".join(rest).encode()).hexdigest()
    s = {"id": cid, "running": True, "run_args": rest}
    save(s)
    print(cid)
elif cmd in ("start", "stop"):
    s = load()
    s["running"] = cmd == "start"
    save(s)
elif cmd == "rm":
    save({})
elif cmd == "build":
    print("fake build ok")
elif cmd == "inspect":
    fmt = rest[rest.index("-f") + 1]
    if "devcontainer.metadata" in fmt:
        print(json.dumps([{"remoteUser": "vscode", "remoteEnv": {"FROM_META": "${containerEnv:HOME}/meta"}}]))
    elif ".Mounts" in fmt:
        print("[]")
    elif "State.Running" in fmt:
        print("true" if load().get("running") else "false")
    else:
        print("")
elif cmd == "exec":
    env = dict(os.environ)
    cwd = None
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in ("-i", "-t", "-it", "-ti"):
            i += 1
        elif a == "-u":
            i += 2
        elif a == "-w":
            cwd = rest[i + 1]
            i += 2
        elif a == "-e":
            k, _, v = rest[i + 1].partition("=")
            env[k] = v
            i += 2
        else:
            break
    argv = rest[i + 1:]  # skip container id
    env["PWD"] = cwd or "/"
    binds = [b.split(":") for b in os.environ.get("FAKE_DOCKER_BIND", "").split(";") if b]  # "host:ctr;host2:ctr2"
    if binds:
        # private mount namespace: host workspaces appear at the container paths, like bind mounts
        mounts = "".join('mount --bind "%s" "%s" || exit 125; ' % (src, dst) for src, dst in binds)
        script = mounts + 'cd "$1" || exit 126; shift; exec "$@"'
        os.execvpe("unshare", ["unshare", "-m", "sh", "-c", script, "sh", cwd or "/"] + argv, env)
    if cwd:
        os.chdir(cwd)
    os.execvpe(argv[0], argv, env)
elif cmd == "version":
    print("fake")
else:
    sys.stderr.write(f"fake docker: unsupported {args}\n")
    sys.exit(1)
