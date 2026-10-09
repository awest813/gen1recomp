"""Repair Emscripten 2.0.0's vector OpenAL source operations in love.js."""
import argparse
from pathlib import Path
import re

BAD = re.compile(r"AL\.setSourceState\((HEAP32\[pSourceIds\+i\*4>>2\]),(411[456])\)")
GOOD = re.compile(r"AL\.setSourceState\(AL\.currentCtx\.sources\[HEAP32\[pSourceIds\+i\*4>>2\]\],411[456]\)")


def patch_source(source):
    # setSourceState expects the source object, whereas these three generated
    # vector entry points pass its numeric id. Their validation already checks
    # every id before dispatch, so retain that behavior and resolve each object.
    count = len(BAD.findall(source))
    if count == 0 and len(GOOD.findall(source)) == 3:
        return source
    if count != 3:
        raise ValueError("Unrecognized OpenAL vector dispatch; expected three id calls")
    return BAD.sub(r"AL.setSourceState(AL.currentCtx.sources[\1],\2)", source)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    original = args.path.read_text(encoding="utf-8")
    patched = patch_source(original)
    if patched != original:
        args.path.write_text(patched, encoding="utf-8")
    print("OpenAL vector source dispatch verified:", args.path)
