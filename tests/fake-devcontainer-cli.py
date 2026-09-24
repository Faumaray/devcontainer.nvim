#!/usr/bin/env python3
"""Stand-in for @devcontainers/cli: `up` prints log noise then the result JSON line,
`read-configuration` returns a merged configuration."""
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ.get("FAKE_DOCKER_LOG", "/tmp/fake-docker.log"), "a") as f:
    f.write(json.dumps(["<cli>"] + args) + "\n")

CID = "cc0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd"
remote = os.environ["FAKE_CLI_REMOTE"]

if args[:1] == ["--version"]:
    print("0.0.0-fake")
elif args[:1] == ["up"]:
    print('[2 ms] @devcontainers/cli 0.0.0-fake. Node.js v22.')
    print('{"type":"text","level":2,"text":"Start: Run: docker run ..."}')
    print(json.dumps({"outcome": "success", "containerId": CID, "remoteUser": "vscode",
                      "remoteWorkspaceFolder": remote}))
elif args[:1] == ["read-configuration"]:
    print(json.dumps({
        "configuration": {"name": "e2e"},
        "mergedConfiguration": {
            "name": "e2e-cli",
            "remoteEnv": {"FROM_CLI": "${containerWorkspaceFolder}"},
            "postAttachCommand": "touch /tmp/dc-e2e/post-attach-ran",
        },
    }))
else:
    sys.stderr.write("fake cli: unsupported %r\n" % args)
    sys.exit(1)
