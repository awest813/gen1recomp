#!/usr/bin/env node
// Browser smoke test for the love.js build (scripts/build_web.sh output).
//
//   node ports/web/smoke_test.mjs --site dist/web [--rom path/to/rom.gb]
//        [--out dir] [--timeout-s 240] [--play]
//
// Without --rom (CI has none): boots the page, presses Start, and requires the
// launcher to come up with no Lua error, no uncaught page error, and the
// `lovejs` bridge installed.
//
// With --rom: also feeds the ROM through the page's real <input type=file>
// (the path love.system.pickFile drives), waits for the import to publish
// its cache marker into the IndexedDB-backed save directory, reloads the page
// to prove the cache survived, and (with --play) presses through to the game.
//
// Screenshots and the console log land in --out.  Needs Playwright's
// Chromium (PLAYWRIGHT_BROWSERS_PATH); WebGL runs on SwiftShader headless.

import { createRequire } from "node:module";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

// A local install wins; otherwise CommonJS require honours NODE_PATH, which
// reaches a globally installed Playwright (ES-module imports do not).
let chromium;
try {
  ({ chromium } = await import("playwright"));
} catch {
  ({ chromium } = createRequire(import.meta.url)("playwright"));
}

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : true]);
  return acc;
}, []));
const site = path.resolve(args.site || "dist/web");
const out = path.resolve(args.out || "dist/web-smoke");
const rom = args.rom ? path.resolve(args.rom) : null;
const timeoutMs = Number(args["timeout-s"] || 240) * 1000;
const identity = "pokemon-love2d";
const saveDir = `/home/web_user/love/${identity}`;
fs.mkdirSync(out, { recursive: true });

const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm",
  ".data": "application/octet-stream", ".css": "text/css", ".png": "image/png",
};
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  let file = path.join(site, decodeURIComponent(url.pathname));
  if (!file.startsWith(site)) { res.writeHead(403).end(); return; }
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, "index.html");
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404).end(); return; }
    res.writeHead(200, { "Content-Type": MIME[path.extname(file)] || "application/octet-stream" });
    res.end(data);
  });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}/`;

const log = [];
const failures = [];
const t0 = Date.now();
const stamp = () => ((Date.now() - t0) / 1000).toFixed(1).padStart(6) + "s";
function note(line) { const l = `${stamp()} ${line}`; log.push(l); console.log(l); }
function fail(why) { failures.push(why); note("FAIL " + why); }

const browser = await chromium.launch({
  args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist",
    "--autoplay-policy=no-user-gesture-required"],
});
const context = await browser.newContext({ viewport: { width: 960, height: 720 } });
let page = null;
async function openPage() {
  const p = await context.newPage();
  p.on("console", (m) => note(`[console.${m.type()}] ${m.text()}`));
  p.on("pageerror", (e) => fail(`page error: ${e.message}`));
  page = p;
  return p;
}
await openPage();

let shot = 0;
async function screenshot(label) {
  const file = path.join(out, `${String(++shot).padStart(2, "0")}-${label}.png`);
  await page.screenshot({ path: file });
  note(`screenshot ${path.basename(file)}`);
}

const fsCall = (fn, ...a) => page.evaluate(([src, a]) => {
  // eslint-disable-next-line no-new-func
  return new Function("FS", "args", src)(window.Module && window.Module.g1rFS, a);
}, [fn, a]);

async function waitFor(desc, check, ms = timeoutMs, every = 1000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (failures.length) return false;
    try { if (await check()) return true; } catch (e) { /* not yet */ }
    await page.waitForTimeout(every);
  }
  fail(`timed out waiting for ${desc}`);
  return false;
}

async function boot(label, query = "") {
  await page.goto(base + "?autostart=1" + query);
  const up = await waitFor("the runtime to start", () =>
    page.evaluate(() => document.getElementById("canvas").style.visibility === "visible"), 120000);
  if (!up) return false;
  const bridge = await waitFor("the lovejs bridge", () =>
    page.evaluate(() => !!(window.Module && window.Module.g1rFS)), 30000);
  if (!bridge) return false;
  note(`${label}: runtime up, bridge installed`);
  await page.waitForTimeout(4000);
  await screenshot(`${label}-launcher`);
  return true;
}

// The in-game crash screen does not print to the console; it writes
// lua-error.log into the save directory, so look there.
async function crashLog() {
  if (!page) return null;
  try {
    return await fsCall(`try { return FS.readFile("${saveDir}/lua-error.log", { encoding: "utf8" }); } catch (e) { return null; }`);
  } catch (e) { return null; }
}
async function checkCrash(when) {
  const text = await crashLog();
  if (text) fail(`Lua crash ${when}: ${text.split("\n").slice(0, 6).join(" | ")}`);
  return !!text;
}

function luaErrorIn(lines) {
  return lines.find((l) => /Error: |stack traceback|attempt to (call|index)|module '.*' not found/.test(l));
}

try {
  if (await boot("boot")) {
    const err = luaErrorIn(log);
    if (err) fail(`Lua error during boot: ${err}`);
    await checkCrash("during boot");

    // single instance: a second tab must refuse to start (IDBFS mirroring
    // would let two tabs delete each other's data)
    const firstTab = page;
    const second = await context.newPage();
    await second.goto(base + "?autostart=1");
    const blocked = await second.waitForFunction(
      () => getComputedStyle(document.getElementById("blocked")).display !== "none",
      null, { timeout: 30000 }).then(() => true, () => false);
    if (!blocked) fail("a second tab started while the first was running");
    else note("second tab refused to start (single instance)");
    await second.close();
    page = firstTab;
  }

  if (rom && !failures.length) {
    const tImport = Date.now();
    await page.setInputFiles("#fileinput", rom);
    note(`fed ${path.basename(rom)} through the page file input`);
    const marker = () => fsCall(`
      var root = "${saveDir}";
      try {
        return FS.readdir(root).some(function (d) {
          try { FS.stat(root + "/" + d + "/rom-cache.complete"); return true; } catch (e) { return false; }
        });
      } catch (e) { return false; }`);
    let lastShot = Date.now();
    const done = await waitFor("the import to publish rom-cache.complete", async () => {
      if (Date.now() - lastShot > 15000) { lastShot = Date.now(); await screenshot("importing"); }
      if (await checkCrash("during import")) return false;
      return marker();
    });
    if (done) {
      note(`import finished in ${((Date.now() - tImport) / 1000).toFixed(1)}s`);
      const leftovers = await fsCall(`try { return FS.readdir("/tmp/g1r_picks").filter(function (n) { return n[0] !== "."; }); } catch (e) { return []; }`);
      if (leftovers.length) fail(`picked ROM copy was not deleted: ${leftovers.join(", ")}`);
      const tree = await fsCall(`
        var root = "${saveDir}", out = [];
        FS.readdir(root).forEach(function (d) { if (d[0] !== ".") out.push(d); });
        return out;`);
      note(`save dir: ${tree.join(", ")}`);
      await page.waitForTimeout(3000);
      await screenshot("after-import");

      // The cache must reach IndexedDB through the game's own debounced sync
      // (src/core/WebHost.lua), not love.js's beforeunload flush: leave the
      // first page open and boot a second one, which reads IndexedDB fresh.
      // close without running beforeunload, so love.js's own flush cannot
      // be what saved it
      await page.waitForTimeout(3000);
      await page.close({ runBeforeUnload: false });
      await openPage();
      if (await boot("second-tab")) {
        if (!(await marker())) fail("imported cache did not reach IndexedDB (a new tab cannot see it)");
        else note("new tab: imported cache is in IndexedDB");
      }

      if (args.play && !failures.length) {
        const press = async (key, n = 1, gap = 400) => {
          for (let i = 0; i < n; i++) { await page.keyboard.press(key); await page.waitForTimeout(gap); }
        };
        // ?game=blue boots straight into the imported game (launch options)
        const game = path.basename(rom).toLowerCase().includes("yellow") ? "yellow"
          : path.basename(rom).toLowerCase().includes("red") ? "red" : "blue";
        if (await boot("play", `&game=${game}`)) {
          // main-thread stalls over 50 ms (song starts, map loads, saves):
          // the Phase 3 hitch budget
          await page.evaluate(() => {
            window.g1rLongTasks = [];
            new PerformanceObserver((list) => {
              for (const e of list.getEntries()) window.g1rLongTasks.push(Math.round(e.duration));
            }).observe({ type: "longtask", buffered: false });
          });
          await page.click("#canvas");
          await page.waitForTimeout(6000);
          await screenshot("play-title");
          // title -> main menu -> NEW GAME -> Oak's intro -> name the player
          // and rival (NEW NAME + "AAA..." + START) -> the bedroom.  Timings
          // are generous; a miss shows up in the screenshots.
          await press("Enter", 1, 2500);
          await screenshot("play-menu");
          await press("Enter", 1, 3000);
          await screenshot("play-newgame");
          await press("z", 80, 350);
          await press("Enter", 1, 1500);
          await press("z", 30, 350);
          await press("Enter", 1, 1500);
          await press("z", 68, 350);
          await press("x", 4, 600);
          await press("ArrowDown", 1, 800);
          await press("x", 2, 500);
          await screenshot("play-bedroom");
          await press("F1", 1, 3000);
          const saveFile = `${saveDir}/save_${game}.lua`;
          const saved = await fsCall(`try { return FS.stat("${saveFile}").size; } catch (e) { return 0; }`);
          await checkCrash("during play");
          if (!saved) fail("F1 in the bedroom did not write a save");
          else note(`F1 wrote save_${game}.lua (${saved} bytes)`);
          const fps = await page.evaluate(() => new Promise((resolve) => {
            let frames = 0;
            const t = performance.now();
            const tick = () => {
              frames++;
              if (performance.now() - t < 3000) requestAnimationFrame(tick);
              else resolve(frames / ((performance.now() - t) / 1000));
            };
            requestAnimationFrame(tick);
          }));
          note(`page frame rate over 3 s: ${fps.toFixed(1)} fps (headless SwiftShader)`);
          const stalls = await page.evaluate(() => window.g1rLongTasks || []);
          const worst = stalls.length ? Math.max(...stalls) : 0;
          note(`main-thread stalls >50 ms during play: ${stalls.length}, worst ${worst} ms`
            + (stalls.length ? ` [${stalls.slice(0, 20).join(", ")}${stalls.length > 20 ? ", ..." : ""}]` : ""));
          const heap = await page.evaluate(() => (window.Module.HEAP8 || { length: 0 }).length);
          if (heap) note(`wasm heap: ${(heap / 1048576).toFixed(0)} MiB`);

          // the save must reach IndexedDB on its own and offer CONTINUE
          if (saved) {
            await page.waitForTimeout(3000);
            await page.close({ runBeforeUnload: false });
            await openPage();
            if (await boot("continue", `&game=${game}`)) {
              const again = await fsCall(`try { return FS.stat("${saveFile}").size; } catch (e) { return 0; }`);
              if (!again) fail("the save did not reach IndexedDB (a new tab cannot see it)");
              else note("new tab: save is in IndexedDB");
              await page.click("#canvas");
              await page.waitForTimeout(6000);
              // the intro ignores early presses: keep pressing START until the
              // title's menu is up, then CONTINUE (the first entry) loads the save
              const mapsBefore = log.filter((l) => l.includes("[info] map:")).length;
              await press("Enter", 4, 2500);
              await screenshot("continue-menu");
              await press("z", 1, 4000);
              await press("z", 2, 1500);
              await screenshot("continue-loaded");
              const mapsAfter = log.filter((l) => l.includes("[info] map:")).length;
              if (mapsAfter <= mapsBefore) fail("CONTINUE did not load the saved game into a map");
              else note("CONTINUE loaded the save into the overworld");
              await checkCrash("after continue");
            }
          }
        }
      }
    }
    const err = luaErrorIn(log);
    if (err) fail(`Lua error: ${err}`);
  }
} finally {
  fs.writeFileSync(path.join(out, "console.log"), log.join("\n") + "\n");
  await browser.close();
  server.close();
}

if (failures.length) {
  console.log(`\nweb smoke: FAIL (${failures.length})`);
  process.exit(1);
}
console.log("\nweb smoke: PASS");
