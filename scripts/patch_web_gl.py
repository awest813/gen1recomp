"""Preserve shader program status/log queries after failed WebGL linking."""
import argparse
from pathlib import Path

OLD = 'var ptable=GL.programInfos[program];if(!ptable){GL.recordError(1282);return}if(pname==35716)'
NEW = 'var ptable=GL.programInfos[program];if(!ptable&&pname!=35716&&pname!=35714&&pname!=35713&&pname!=35712){GL.recordError(1282);return}if(pname==35716)'


def patch_source(source):
    # Uniform metadata is populated only for a successfully linked program.
    # LINK_STATUS, VALIDATE_STATUS, DELETE_STATUS and INFO_LOG_LENGTH still
    # need to reach WebGL when linking failed, especially its actual error log.
    if source.count(NEW) == 1 and OLD not in source:
        return source
    if source.count(OLD) != 1:
        raise ValueError("Unrecognized WebGL program-query dispatch")
    return source.replace(OLD, NEW)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    source = args.path.read_text(encoding="utf-8")
    patched = patch_source(source)
    if patched != source:
        args.path.write_text(patched, encoding="utf-8")
    print("WebGL program status/log queries verified:", args.path)
