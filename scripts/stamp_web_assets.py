"""Give each complete web build content-derived asset URLs."""
import argparse
import hashlib
from pathlib import Path
import re


def stamp(directory):
    directory = Path(directory)
    assets = [directory / name for name in ("game.js", "love.js", "love.wasm")]
    payload = [directory / "game.data"] if (directory / "game.data").exists() else sorted(directory.glob("game.data.part*"))
    if not payload:
        raise ValueError("Web build has no data payload")
    digest = hashlib.sha256()
    for path in assets + payload:
        digest.update(path.name.encode())
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    token = digest.hexdigest()[:16]
    index = directory / "index.html"
    source = index.read_text(encoding="utf-8")
    patterns = [
        (r'(<meta name="g1r-build" content=")[^"]*(">)', r'\g<1>' + token + r'\g<2>'),
        (r'(<script src=")game\.js(?:\?[^"]*)?(" onerror="g1rDataFailed\(\)">)', r'\g<1>game.js?g1r-build=' + token + r'\g<2>'),
        (r'(<script async src=")love\.js(?:\?[^"]*)?(" onload=)', r'\g<1>love.js?g1r-build=' + token + r'\g<2>'),
    ]
    for pattern, replacement in patterns:
        source, count = re.subn(pattern, replacement, source)
        if count != 1:
            raise ValueError("Unrecognized web page asset template")
    index.write_text(source, encoding="utf-8")
    return token


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    print("Stamped web assets:", stamp(parser.parse_args().directory))
