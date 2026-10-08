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

static const luaL_Reg functions[] = {
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
