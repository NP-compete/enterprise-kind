"""Insert a CoreDNS rewrite that maps *.<domain> to the ingress controller.

Reads the Corefile on stdin, writes the patched Corefile on stdout.
Called by scripts/cluster-dns.sh; not meant to be run directly.
"""

import os
import re
import sys

MARKER = "# platform-ingress-rewrite"
TARGET = "ingress-nginx-controller.ingress-nginx.svc.cluster.local"


def main() -> None:
    corefile = sys.stdin.read()
    domain = os.environ["BASE_DOMAIN"]
    escaped = domain.replace(".", r"\.")

    # Drop a block we inserted earlier (the domain may have changed).
    corefile = re.sub(
        r"^[ \t]*" + re.escape(MARKER) + r"\n(?:.*\n)*?[ \t]*\}\n",
        "",
        corefile,
        flags=re.M,
    )

    block = (
        "    " + MARKER + "\n"
        "    rewrite stop {\n"
        # CoreDNS matches the fully-qualified question name, so allow the
        # trailing dot; without `\.?` this silently never matches and the
        # query falls through to the host resolver.
        "      name regex (.*)\\." + escaped + "\\.?$ " + TARGET + "\n"
        "      answer auto\n"
        "    }\n"
    )

    # The rewrite has to run before the kubernetes plugin resolves the name.
    out, count = re.subn(
        r"^(\s*)kubernetes\s", block + r"\1kubernetes ", corefile, count=1, flags=re.M
    )
    if count != 1:
        sys.exit("could not locate the kubernetes plugin in the Corefile")
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
