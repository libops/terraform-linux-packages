#!/usr/bin/env python3

from datetime import datetime
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: package-lock-age.py UPDATED_AT NOW_EPOCH", file=sys.stderr)
        return 2

    updated = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    now = int(sys.argv[2])
    print(max(0, now - int(updated.timestamp())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
