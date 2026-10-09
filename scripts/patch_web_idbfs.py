"""Yield between IDBFS local inventory batches so large mods do not freeze RAF."""
import argparse
from pathlib import Path

OLD = 'getLocalSet:function(mount,callback){var entries={};function isRealDir(p){return p!=="."&&p!==".."}function toAbsolute(root){return function(p){return PATH.join2(root,p)}}var check=FS.readdir(mount.mountpoint).filter(isRealDir).map(toAbsolute(mount.mountpoint));while(check.length){var path=check.pop();var stat;try{stat=FS.stat(path)}catch(e){return callback(e)}if(FS.isDir(stat.mode)){check.push.apply(check,FS.readdir(path).filter(isRealDir).map(toAbsolute(path)))}entries[path]={"timestamp":stat.mtime}}return callback(null,{type:"local",entries:entries})}'
NEW = '''getLocalSet:function(mount,callback){/* g1r-idbfs-sliced-inventory */
var entries={},check=[];
function children(root){return FS.readdir(root).filter(function(p){return p!=="."&&p!==".."}).map(function(p){return PATH.join2(root,p)})}
try{check=children(mount.mountpoint)}catch(e){return callback(e)}
function pump(){var count=0,start=Date.now();
try{while(check.length&&count<64){var path=check.pop(),stat;count++;
try{stat=FS.stat(path)}catch(e){if(e.errno===44)continue;throw e}
if(FS.isDir(stat.mode)){var next=children(path);for(var i=0;i<next.length;i++)check.push(next[i])}
entries[path]={"timestamp":stat.mtime};if(Date.now()-start>=2)break;
}}catch(e){return callback(e)}
if(check.length){setTimeout(pump,0)}else{callback(null,{type:"local",entries:entries})}
}pump()}'''


def patch_source(source):
    if source.count(NEW) == 1 and OLD not in source:
        return source
    if source.count(OLD) != 1:
        raise ValueError("Unrecognized IDBFS local inventory implementation")
    return source.replace(OLD, NEW)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    original = args.path.read_text(encoding="utf-8")
    patched = patch_source(original)
    if original != patched:
        args.path.write_text(patched, encoding="utf-8")
    print("IDBFS cooperative inventory verified:", args.path)
