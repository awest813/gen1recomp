#!/usr/bin/env python3
"""Split a love.js web build's game.data into <chunk-size chunks and patch
game.js to fetch+reassemble them client-side. Run after every love.js
invocation (build love.js straight into dist/web/). Custom player
theme/branding (background + CSS) lives in scripts/web-theme/,  copy it into
the love.js output dir's theme/ folder and set
<link rel="stylesheet" href="theme/love.css"> in index.html.
"""
import argparse
import os
import re
import sys

FETCH_REMOTE_PACKAGE_RE = re.compile(
    r"    function fetchRemotePackage\(packageName, packageSize, callback, errback\) \{.*?\n    \};\n",
    re.DOTALL,
)

def make_patched_fetch(chunk_size):
    if chunk_size <= 0:
        raise ValueError("chunk size must be positive")
    return f"""    function fetchRemotePackage(packageName, packageSize, callback, errback) {{
      var CHUNK_SIZE = {chunk_size};
      var numChunks = Math.ceil(packageSize / CHUNK_SIZE);
      var buffer = new Uint8Array(packageSize);
      var loadedChunks = 0;
      var hadError = false;
      var nextChunk = 0;
      var requests = [];

      function fail(error) {{
        if (hadError) return;
        hadError = true;
        requests.forEach(function(xhr) {{ if (xhr) xhr.abort(); }});
        errback(error);
      }}

      function chunkURL(i) {{
        var queryAt = packageName.indexOf('?');
        var path = queryAt < 0 ? packageName : packageName.slice(0, queryAt);
        var query = queryAt < 0 ? '' : packageName.slice(queryAt);
        return path + '.part' + String(i).padStart(3, '0') + query;
      }}

      function onChunkLoaded(i, data) {{
        if (hadError) return;
        var expected = Math.min(CHUNK_SIZE, packageSize - i * CHUNK_SIZE);
        if (!data || data.byteLength !== expected) {{
          fail(new Error('Invalid data size for: ' + chunkURL(i)));
          return;
        }}
        buffer.set(new Uint8Array(data), i * CHUNK_SIZE);
        loadedChunks++;
        if (Module['setStatus']) Module['setStatus']('Downloading data... (' + loadedChunks + '/' + numChunks + ' parts)');
        if (loadedChunks === numChunks && !hadError) {{
          callback(buffer.buffer);
        }} else {{
          startNext();
        }}
      }}

      function startNext() {{
        if (hadError || nextChunk >= numChunks) return;
        (function(i) {{
          var xhr = new XMLHttpRequest();
          requests[i] = xhr;
          xhr.open('GET', chunkURL(i), true);
          xhr.responseType = 'arraybuffer';
          xhr.timeout = 120000;
          xhr.onload = function() {{
            requests[i] = null;
            if (xhr.status == 200 || xhr.status == 304 || xhr.status == 206 || (xhr.status == 0 && xhr.response)) {{
              onChunkLoaded(i, xhr.response);
            }} else {{
              fail(new Error(xhr.statusText + " : " + chunkURL(i)));
            }}
          }};
          xhr.onerror = function() {{
            fail(new Error("NetworkError for: " + chunkURL(i)));
          }};
          xhr.ontimeout = function() {{ fail(new Error('Timeout for: ' + chunkURL(i))); }};
          xhr.send(null);
        }})(nextChunk++);
      }}
      if (numChunks === 0) {{ callback(buffer.buffer); return; }}
      // Bound transient response buffers and network contention on phones.
      for (var i = 0; i < Math.min(4, numChunks); i++) startNext();
    }};
"""

def split_file(src_path, chunk_size):
    parts = []
    with open(src_path, 'rb') as f:
        i = 0
        while True:
            data = f.read(chunk_size)
            if not data:
                break
            part_path = f"{src_path}.part{i:03d}"
            with open(part_path, 'wb') as out:
                out.write(data)
            parts.append(part_path)
            i += 1
    return parts

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('outdir', help='love.js output directory (e.g. .bazinga/online)')
    ap.add_argument('--chunk-size-mb', type=int, default=20, help='max chunk size in MB (default 20, keep under host cap e.g. 25MB)')
    args = ap.parse_args()
    if args.chunk_size_mb <= 0:
        ap.error('--chunk-size-mb must be positive')

    chunk_size = args.chunk_size_mb * 1024 * 1024
    game_data = os.path.join(args.outdir, 'game.data')
    game_js = os.path.join(args.outdir, 'game.js')

    if not os.path.isfile(game_data):
        sys.exit(f"error: {game_data} not found,  run love.js first")
    if not os.path.isfile(game_js):
        sys.exit(f"error: {game_js} not found,  run love.js first")

    # Validate before changing any files; keep the usable build on failure.
    with open(game_js, 'r', encoding='utf-8') as f:
        src = f.read()
    if not FETCH_REMOTE_PACKAGE_RE.search(src):
        sys.exit("error: could not find fetchRemotePackage() in game.js,  love.js template may have changed")
    patched = FETCH_REMOTE_PACKAGE_RE.sub(make_patched_fetch(chunk_size), src, count=1)

    # clean up any stale parts from a previous run
    for name in os.listdir(args.outdir):
        if re.match(r"^game\.data\.part\d{3,}$", name):
            os.remove(os.path.join(args.outdir, name))

    parts = split_file(game_data, chunk_size)
    with open(game_js, 'w', encoding='utf-8') as f:
        f.write(patched)
    os.remove(game_data)

    sizes = [os.path.getsize(p) for p in parts]
    print(f"split game.data into {len(parts)} parts (chunk size {args.chunk_size_mb}MB):")
    for p, s in zip(parts, sizes):
        print(f"  {os.path.basename(p)}: {s / 1024 / 1024:.1f} MB")
    print("patched game.js fetchRemotePackage() to fetch+reassemble parts")

if __name__ == '__main__':
    main()
