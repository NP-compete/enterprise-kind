"""Add --authentication-config to the kube-apiserver static pod manifest.

Reads the manifest on stdin, writes the patched manifest on stdout. Idempotent:
if the flag is already present with the same value, the output is identical to
the input (the caller uses that to detect a no-op).

Deliberately line-based rather than a YAML round-trip: the kubelet re-reads this
file whenever it changes, so preserving the original formatting keeps the diff
to exactly the line being added.
"""

import os
import sys

FLAG = "--authentication-config"


def main() -> None:
    manifest = sys.stdin.read()
    desired = f"{FLAG}={os.environ['CONFIG_PATH']}"

    lines = manifest.splitlines(keepends=True)
    out, inserted = [], False

    for line in lines:
        stripped = line.strip()
        if stripped.startswith(f"- {FLAG}="):
            # Replace an existing value rather than adding a duplicate flag.
            indent = line[: len(line) - len(line.lstrip())]
            out.append(f"{indent}- {desired}\n")
            inserted = True
            continue
        out.append(line)

    if not inserted:
        for i, line in enumerate(out):
            stripped = line.strip()
            # The command list starts with the binary; put the flag right after.
            if stripped == "- kube-apiserver":
                indent = line[: len(line) - len(line.lstrip())]
                out.insert(i + 1, f"{indent}- {desired}\n")
                inserted = True
                break

    if not inserted:
        sys.exit("could not find the kube-apiserver command in the manifest")

    sys.stdout.write("".join(out))


if __name__ == "__main__":
    main()
