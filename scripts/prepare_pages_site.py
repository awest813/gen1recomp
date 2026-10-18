#!/usr/bin/env python3
"""Finish a love.js site so GitHub Pages can serve it.

Other LÖVE web ports (Forgotten Saga, LÖVE Window Kit) publish a static
directory and add an empty ``.nojekyll`` so Pages does not run Jekyll over
the build. This script does that, copies the project-site 404, and can
refuse a file larger than GitHub's per-file publish limit.
"""
import argparse
import sys
from pathlib import Path


SHELL = Path(__file__).resolve().parents[1] / "ports" / "web" / "shell"
# GitHub rejects a Pages file at 100 MiB. Stay under that after any split.
PAGES_FILE_LIMIT = 100 * 1024 * 1024


def prepare(directory, max_bytes=None):
    directory = Path(directory)
    if not (directory / "index.html").is_file():
        raise ValueError("web site is missing index.html")
    source = SHELL / "404.html"
    if not source.is_file():
        raise ValueError("ports/web/shell/404.html is missing")
    if max_bytes is not None:
        too_big = []
        for path in sorted(directory.iterdir()):
            if path.is_file() and path.name != "404.html" and path.stat().st_size > max_bytes:
                too_big.append(path.name)
        if too_big:
            raise ValueError(
                "GitHub Pages file limit exceeded (%d bytes): %s"
                % (max_bytes, ", ".join(too_big))
            )
    (directory / ".nojekyll").write_bytes(b"")
    (directory / "404.html").write_bytes(source.read_bytes())
    return []


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument(
        "--max-bytes",
        type=int,
        default=None,
        help="fail when any published file is larger than this (use %d for Pages)"
        % PAGES_FILE_LIMIT,
    )
    args = parser.parse_args(argv)
    try:
        prepare(args.directory, args.max_bytes)
    except ValueError as err:
        print("error: %s" % err, file=sys.stderr)
        return 1
    print("Prepared GitHub Pages site: %s" % args.directory)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
