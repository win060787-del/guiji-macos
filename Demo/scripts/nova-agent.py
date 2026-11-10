#!/usr/bin/env python3
"""Nova Context local client. Requires Python 3; no external packages or TCP access."""
import argparse
import json
import os
import socket
import stat
import sys
import uuid


def fail(code):
    print(json.dumps({"version": 1, "ok": False, "error": code}))
    return 1


def main():
    parser = argparse.ArgumentParser(description="Call the local Nova Context credential service")
    parser.add_argument("--grant", required=True, help="Private Agent authorization JSON file")
    parser.add_argument("--request-id", help="UUID; duplicate requests are rejected")
    args = parser.parse_args()
    try:
        fd = os.open(args.grant, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                return fail("insecureGrantFile")
            raw = source.read(16385)
        if len(raw) > 16384:
            return fail("invalidGrantFile")
        grant = json.loads(raw)
        if grant.get("version") != 1 or grant.get("operation") != "github.identity":
            return fail("invalidGrantFile")
        request_id = str(uuid.UUID(args.request_id)) if args.request_id else str(uuid.uuid4())
        request = {"version": 1, "requestID": request_id, "token": grant["token"],
                   "project": grant["project"], "operation": "github.identity"}
        payload = json.dumps(request).encode() + b"\n"
        if len(payload) > 4097:
            return fail("invalidGrantFile")
        path = grant["socket"]
        info = os.lstat(path)
        parent = os.lstat(os.path.dirname(path))
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            return fail("insecureSocket")
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
            return fail("insecureSocket")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(22)
            client.connect(path)
            client.sendall(payload)
            response = bytearray()
            while b"\n" not in response:
                part = client.recv(4096)
                if not part:
                    return fail("serviceUnavailable")
                response.extend(part)
                if len(response) > 16384:
                    return fail("invalidResponse")
        reply = json.loads(response.split(b"\n", 1)[0])
        if reply.get("version") != 1 or reply.get("requestID", "").lower() != request_id.lower():
            return fail("invalidResponse")
        print(json.dumps(reply, ensure_ascii=False))
        return 0 if reply.get("ok") else 1
    except (OSError, KeyError, ValueError, TypeError, AttributeError):
        return fail("serviceUnavailable")


if __name__ == "__main__":
    sys.exit(main())
