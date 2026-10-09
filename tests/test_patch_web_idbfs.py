import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import unittest

spec = importlib.util.spec_from_file_location("patch_idbfs",
    Path(__file__).resolve().parents[1] / "scripts/patch_web_idbfs.py")
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


class IDBFSInventoryTest(unittest.TestCase):
    def test_large_tree_yields_and_preserves_inventory(self):
        node = os.environ.get("NODE") or shutil.which("node")
        self.assertIsNotNone(node)
        script = r'''
const assert = require('node:assert/strict');
let queued=[],calls=0,visited=0,failPath=null,removed=null;
const PATH={join2:(a,b)=>a+'/'+b};
const FS={
 readdir:p=>p==='/save'?['.','..','mods','options']:
   p==='/save/mods'?['.','..',...Array.from({length:31404},(_,i)=>'asset'+i)]:[],
 stat:p=>{visited++;if(p===removed){let e=new Error('removed');e.errno=44;throw e}
   if(p===failPath)throw new Error('stat failed');
   return {mode:p==='/save/mods'?1:2,mtime:new Date(p.length*1000)}},
 isDir:m=>m===1
};
const setTimeout=fn=>{queued.push(fn)};
const source={''' + patch.OLD + r'''};
const sliced={''' + patch.NEW + r'''};
let expected,result;
source.getLocalSet({mountpoint:'/save'},(err,set)=>{assert.ifError(err);expected=set});
visited=0;
sliced.getLocalSet({mountpoint:'/save'},(err,set)=>{assert.ifError(err);calls++;result=set});
assert.equal(calls,0);assert.ok(visited<=64);assert.ok(queued.length);
while(queued.length){let before=visited;queued.shift()();assert.ok(visited-before<=64)}
assert.equal(calls,1);assert.deepEqual(result,expected);
// A cache asset removed between batches is absent from the persisted set.
calls=0;
sliced.getLocalSet({mountpoint:'/save'},(err,set)=>{assert.ifError(err);calls++;result=set});
removed='/save/mods/asset31000';
while(queued.length)queued.shift()();
assert.equal(calls,1);assert.ok(!Object.hasOwn(result.entries,removed));
assert.equal(Object.keys(result.entries).length,Object.keys(expected.entries).length-1);
removed=null;
// A filesystem failure terminates once and never queues continuation work.
calls=0;failPath='/save/mods/asset31000';
sliced.getLocalSet({mountpoint:'/save'},err=>{calls++;assert.equal(err.message,'stat failed')});
while(queued.length)queued.shift()();assert.equal(calls,1);
// Empty directories and initial readdir errors retain the callback contract.
FS.readdir=()=>[];calls=0;
sliced.getLocalSet({mountpoint:'/empty'},(err,set)=>{assert.ifError(err);calls++;assert.deepEqual(set.entries,{})});
assert.equal(calls,1);assert.equal(queued.length,0);
FS.readdir=()=>{throw new Error('directory failed')};calls=0;
sliced.getLocalSet({mountpoint:'/bad'},err=>{calls++;assert.equal(err.message,'directory failed')});
assert.equal(calls,1);
console.log('31,406-entry cooperative inventory verified');
'''
        subprocess.run([node, "-e", script], check=True)

    def test_guard_and_idempotence(self):
        updated = patch.patch_source("before;" + patch.OLD + ";after")
        self.assertEqual(patch.patch_source(updated), updated)
        with self.assertRaises(ValueError):
            patch.patch_source("changed runtime")
        with self.assertRaises(ValueError):
            patch.patch_source(patch.OLD + patch.OLD)


if __name__ == "__main__":
    unittest.main()
