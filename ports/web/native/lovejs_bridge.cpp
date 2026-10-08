/*
 * gen1recomp browser bridge: the `lovejs` Lua module preloaded by the custom
 * love.js build (see ports/web/BUILD.md and ports/web/patch_love.py).
 *
 * src/core/WebHost.lua copies the picker functions onto love.system under the
 * names the UWP picker bridge already uses, so RomImporter's native-picker
 * path works unchanged:
 *
 *   pickFile(kind)   -> boolean   open the page's <input type=file>
 *   getPickedFile()  -> path|nil  next picked file, written under /tmp
 *   getPickError()   -> text|nil  next picker error
 *   pickFileKinds()  -> "rom,sav,mod,skin,cart"
 *
 * plus two the web needs on its own:
 *
 *   getDroppedFile() -> path|nil  next file dropped on the page, under /tmp
 *   syncStorage()                 flush the IndexedDB-backed save directory
 *   downloadFile(path, name) -> boolean
 *                                 hand a file to the browser as a download
 *                                 (exported saves: the save directory itself
 *                                 is invisible inside a browser)
 *
 * The queues and the file input live in the page shell
 * (ports/web/shell/index.html); this file only moves strings across.  Paths
 * are under /tmp (MEMFS, never persisted), so a picked ROM never reaches
 * IndexedDB -- the importer reads it once and deletes it.
 */

#include <emscripten.h>

#include <cstring>
#include <vector>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

// Expose FS, the queues and the one storage-sync coalescer to the page.  Runs
// once, from luaopen_lovejs.  Module.g1rSync(cb) is the only way anything
// flushes the save directory (Lua through syncStorage, the page on
// visibilitychange/pagehide): a request made while a sync is running re-runs
// it once that finishes, so the last write is always flushed and two syncfs
// calls never overlap.
EM_JS(void, g1r_init, (), {
	Module["g1rFS"] = FS;
	Module["g1rPicks"] = Module["g1rPicks"] || [];
	Module["g1rPickErrors"] = Module["g1rPickErrors"] || [];
	Module["g1rDrops"] = Module["g1rDrops"] || [];
	var syncing = false, again = false, waiters = [];
	Module["g1rSync"] = function (cb) {
		if (typeof cb === "function") waiters.push(cb);
		if (syncing) { again = true; return; }
		syncing = true;
		var mine = waiters; waiters = [];
		function done(err) {
			syncing = false;
			if (err && Module["printErr"]) Module["printErr"]("[g1r] storage sync failed: " + err);
			mine.forEach(function (f) { try { f(err || null); } catch (e) {} });
			if (again || waiters.length) { again = false; Module["g1rSync"](); }
		}
		// a synchronous throw must not leave `syncing` stuck at true: every
		// later sync would queue behind it forever and nothing would persist
		try { FS.syncfs(false, done); } catch (e) { done(e); }
	};
	// true while a sync is running or queued: the page asks before closing
	Module["g1rSyncBusy"] = function () { return syncing || again || waiters.length > 0; };
	if (typeof Module["g1rOnBridgeReady"] === "function") Module["g1rOnBridgeReady"]();
});

EM_JS(int, g1r_pick_file, (const char *kind), {
	var open = Module["g1rPickFile"];
	if (typeof open !== "function") return 0;
	try {
		return open(UTF8ToString(kind)) ? 1 : 0;
	} catch (e) {
		Module["g1rPickErrors"].push(String(e && e.message || e));
		return 0;
	}
});

// which: 0 = picks, 1 = pick errors, 2 = drops.  Byte length of the next
// entry including its terminator, or 0 when the queue is empty.
EM_JS(int, g1r_peek_len, (int which), {
	var q = which === 0 ? Module["g1rPicks"] : which === 1 ? Module["g1rPickErrors"] : Module["g1rDrops"];
	if (!q || !q.length) return 0;
	return lengthBytesUTF8(String(q[0])) + 1;
});

EM_JS(void, g1r_shift_into, (int which, char *buf, int len), {
	var q = which === 0 ? Module["g1rPicks"] : which === 1 ? Module["g1rPickErrors"] : Module["g1rDrops"];
	stringToUTF8(String(q.shift()), buf, len);
});

EM_JS(void, g1r_sync_storage, (), {
	Module["g1rSync"]();
});

EM_JS(int, g1r_download_file, (const char *path, const char *name), {
	try {
		var data = FS.readFile(UTF8ToString(path));
		var blob = new Blob([data], { type: "application/octet-stream" });
		var url = URL.createObjectURL(blob);
		var a = document.createElement("a");
		a.href = url;
		a.download = UTF8ToString(name) || "download";
		a.style.display = "none";
		document.body.appendChild(a);
		a.click();
		// generous: some browsers (Safari, slow disks) read the blob well
		// after the click returns
		setTimeout(function () { URL.revokeObjectURL(url); a.remove(); }, 40000);
		return 1;
	} catch (e) {
		if (Module["printErr"]) Module["printErr"]("[g1r] download failed: " + e);
		return 0;
	}
});

// HTTP through the browser's fetch(), for src/net/Fetch.lua's Web transport
// (the desktop ports use curl on a worker thread; the page has neither).
// Asynchronous: start returns at once, the body streams into the virtual
// filesystem at `dest`, and Lua polls.  Cross-origin hosts must send CORS
// headers -- GitHub Pages, raw.githubusercontent.com and api.github.com do.
// flags: 1 = any HTTP status finishes ok (Fetch.request, like the desktop
// worker), 2 = an empty body is a failure (downloads).  timeoutMs > 0 aborts
// a request that has not finished by then.
EM_JS(int, g1r_fetch_start, (int id, const char *method, const char *url,
		const char *headers, const char *body, int bodyLen, const char *dest,
		int flags, int timeoutMs), {
	var jobs = Module["g1rFetches"] = Module["g1rFetches"] || {};
	var job = jobs[id] = { state: 0, code: 0, progress: 0, err: "" };
	var m = UTF8ToString(method) || "GET";
	var path = UTF8ToString(dest);
	var init = { method: m, headers: {}, redirect: "follow" };
	UTF8ToString(headers).split("\n").forEach(function (line) {
		var i = line.indexOf(":");
		if (i > 0) init.headers[line.slice(0, i).trim()] = line.slice(i + 1).trim();
	});
	if (body && m !== "GET" && m !== "HEAD") init.body = HEAPU8.slice(body, body + bodyLen);
	var phase = "connect";
	var timer = 0;
	function fail(why) { if (timer) clearTimeout(timer); job.state = 2; job.err = String(why); }
	if (timeoutMs > 0 && typeof AbortController === "function") {
		var ctl = new AbortController();
		init.signal = ctl.signal;
		timer = setTimeout(function () { phase = "timeout"; ctl.abort(); }, timeoutMs);
	}
	try {
		fetch(UTF8ToString(url), init).then(function (res) {
			job.code = res.status;
			phase = "read";
			if (!res.ok && !(flags & 1)) { fail("HTTP " + res.status); return; }
			var total = Number(res.headers.get("content-length")) || 0;
			var chunks = [], got = 0;
			function finish() {
				if (got === 0 && (flags & 2)) { fail("the server sent an empty file"); return; }
				phase = "write";
				var data = new Uint8Array(got), at = 0;
				chunks.forEach(function (c) { data.set(c, at); at += c.length; });
				var dir = path.substring(0, path.lastIndexOf("/"));
				if (dir) { try { FS.mkdirTree(dir); } catch (e) {} }
				FS.writeFile(path, data);
				if (timer) clearTimeout(timer);
				job.progress = 1;
				job.state = 1;
			}
			if (!res.body || !res.body.getReader) {
				return res.arrayBuffer().then(function (buf) {
					chunks.push(new Uint8Array(buf)); got = buf.byteLength; finish();
				});
			}
			var reader = res.body.getReader();
			function pump() {
				return reader.read().then(function (r) {
					if (r.done) { finish(); return; }
					chunks.push(r.value);
					got += r.value.length;
					if (total > 0) job.progress = Math.min(0.99, got / total);
					return pump();
				});
			}
			return pump();
		}).catch(function (e) {
			var msg = e && e.message || e;
			if (phase === "timeout") fail("timed out");
			else if (phase === "connect")
				// a CORS refusal and an offline network look the same from here
				fail("network error (offline, or the host does not allow browser requests): " + msg);
			else if (phase === "write") fail("could not save the download: " + msg);
			else fail("the connection dropped: " + msg);
		});
	} catch (e) {
		fail(e && e.message || e);
		return 0;
	}
	return 1;
});

// Open a URL in a new tab; 0 when the browser would block it.  A pop-up is
// only allowed inside a click/key's user activation, so with no activation
// left this does not try (window.open with noopener returns null either way,
// so its result cannot tell).
EM_JS(int, g1r_open_url, (const char *url), {
	try {
		if (navigator.userActivation && !navigator.userActivation.isActive) return 0;
		window.open(UTF8ToString(url), "_blank", "noopener");
		return 1;
	} catch (e) {
		return 0;
	}
});

// WebHost's "writes waiting for their debounced sync" flag, for the page's
// close-tab prompt.
EM_JS(void, g1r_set_dirty, (int dirty), {
	Module["g1rDirty"] = dirty !== 0;
});

// 0 pending, 1 ok, 2 error, -1 unknown id
EM_JS(int, g1r_fetch_state, (int id), {
	var job = (Module["g1rFetches"] || {})[id];
	return job ? job.state : -1;
});
EM_JS(int, g1r_fetch_code, (int id), {
	var job = (Module["g1rFetches"] || {})[id];
	return job ? job.code : 0;
});
EM_JS(double, g1r_fetch_progress, (int id), {
	var job = (Module["g1rFetches"] || {})[id];
	return job ? job.progress : 0;
});
EM_JS(int, g1r_fetch_err_len, (int id), {
	var job = (Module["g1rFetches"] || {})[id];
	return job ? lengthBytesUTF8(job.err) + 1 : 1;
});
EM_JS(void, g1r_fetch_err_into, (int id, char *buf, int len), {
	var job = (Module["g1rFetches"] || {})[id];
	stringToUTF8(job ? job.err : "", buf, len);
});
EM_JS(void, g1r_fetch_forget, (int id), {
	if (Module["g1rFetches"]) delete Module["g1rFetches"][id];
});

static int shiftQueue(lua_State *L, int which)
{
	int len = g1r_peek_len(which);
	if (len <= 0)
	{
		lua_pushnil(L);
		return 1;
	}
	std::vector<char> buf((size_t) len);
	g1r_shift_into(which, buf.data(), len);
	lua_pushstring(L, buf.data());
	return 1;
}

static int w_pickFile(lua_State *L)
{
	const char *kind = luaL_optstring(L, 1, "rom");
	lua_pushboolean(L, g1r_pick_file(kind) != 0);
	return 1;
}

static int w_getPickedFile(lua_State *L) { return shiftQueue(L, 0); }
static int w_getPickError(lua_State *L) { return shiftQueue(L, 1); }
static int w_getDroppedFile(lua_State *L) { return shiftQueue(L, 2); }

static int w_pickFileKinds(lua_State *L)
{
	lua_pushstring(L, "rom,sav,mod,skin,cart");
	return 1;
}

static int w_syncStorage(lua_State *L)
{
	(void) L;
	g1r_sync_storage();
	return 0;
}

static int w_downloadFile(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	const char *name = luaL_optstring(L, 2, "");
	lua_pushboolean(L, g1r_download_file(path, name) != 0);
	return 1;
}

// fetchStart(id, method, url, headers ("Name: value" lines), body|nil, dest)
static int w_fetchStart(lua_State *L)
{
	int id = (int) luaL_checkinteger(L, 1);
	const char *method = luaL_optstring(L, 2, "GET");
	const char *url = luaL_checkstring(L, 3);
	const char *headers = luaL_optstring(L, 4, "");
	size_t bodyLen = 0;
	const char *body = lua_isstring(L, 5) ? lua_tolstring(L, 5, &bodyLen) : nullptr;
	const char *dest = luaL_checkstring(L, 6);
	int flags = (int) luaL_optinteger(L, 7, 0);
	int timeoutMs = (int) luaL_optinteger(L, 8, 0);
	lua_pushboolean(L, g1r_fetch_start(id, method, url, headers, body, (int) bodyLen, dest,
		flags, timeoutMs) != 0);
	return 1;
}

static int w_openURL(lua_State *L)
{
	lua_pushboolean(L, g1r_open_url(luaL_checkstring(L, 1)) != 0);
	return 1;
}

static int w_setDirty(lua_State *L)
{
	g1r_set_dirty(lua_toboolean(L, 1));
	return 0;
}

// fetchPoll(id) -> "pending"|"ok"|"error"|"unknown", httpCode, progress, err
static int w_fetchPoll(lua_State *L)
{
	int id = (int) luaL_checkinteger(L, 1);
	int state = g1r_fetch_state(id);
	lua_pushstring(L, state == 0 ? "pending" : state == 1 ? "ok" : state == 2 ? "error" : "unknown");
	lua_pushinteger(L, g1r_fetch_code(id));
	lua_pushnumber(L, g1r_fetch_progress(id));
	if (state == 2)
	{
		int len = g1r_fetch_err_len(id);
		std::vector<char> buf((size_t) len);
		g1r_fetch_err_into(id, buf.data(), len);
		lua_pushstring(L, buf.data());
	}
	else
		lua_pushnil(L);
	return 4;
}

static int w_fetchForget(lua_State *L)
{
	g1r_fetch_forget((int) luaL_checkinteger(L, 1));
	return 0;
}

static const luaL_Reg functions[] = {
	{ "fetchStart", w_fetchStart },
	{ "fetchPoll", w_fetchPoll },
	{ "fetchForget", w_fetchForget },
	{ "openURL", w_openURL },
	{ "setDirty", w_setDirty },
	{ "pickFile", w_pickFile },
	{ "getPickedFile", w_getPickedFile },
	{ "getPickError", w_getPickError },
	{ "getDroppedFile", w_getDroppedFile },
	{ "pickFileKinds", w_pickFileKinds },
	{ "syncStorage", w_syncStorage },
	{ "downloadFile", w_downloadFile },
	{ nullptr, nullptr }
};

extern "C" int luaopen_lovejs(lua_State *L)
{
	g1r_init();
	lua_newtable(L);
	for (const luaL_Reg *f = functions; f->name != nullptr; f++)
	{
		lua_pushcfunction(L, f->func);
		lua_setfield(L, -2, f->name);
	}
	return 1;
}
