#!/usr/bin/env python3
"""Packaging is intentionally unavailable; this source is not an installable product."""
import sys

def main():
    print("REFUSED: no verified RootHide packaging/signing scheme or privilege integration. "
          "Run build.sh for local unsigned compile-validation artifacts only. "
          "No Debian package will be created.", file=sys.stderr)
    return 2

if __name__ == "__main__":
    sys.exit(main())
