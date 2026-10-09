import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import unittest

spec = importlib.util.spec_from_file_location("patch_openal", Path(__file__).resolve().parents[1] / "scripts/patch_web_openal.py")
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


class OpenALPatchTest(unittest.TestCase):
    def test_real_vector_dispatch_contract(self):
        # Same vector validation/dispatch as the pinned generated runtime.
        source = ""
        for name, state in [("Play", 4114), ("Pause", 4115), ("Stop", 4116)]:
            source += f'''function _alSource{name}v(count,pSourceIds){{
              if(!AL.currentCtx){{return}}
              for(var i=0;i<count;++i){{
                if(!AL.currentCtx.sources[HEAP32[pSourceIds+i*4>>2]]){{AL.currentCtx.err=40961;return}}
              }}
              for(var i=0;i<count;++i){{AL.setSourceState(HEAP32[pSourceIds+i*4>>2],{state})}}
            }}'''
        fixed = patch.patch_source(source)
        self.assertEqual(patch.patch_source(fixed), fixed)
        node = os.getenv("NODE") or shutil.which("node")
        self.assertIsNotNone(node, "Node is required for runtime validation")
        script = '''const assert = require('assert');
          const a={bufQueue:[1]}, b={bufQueue:[2]};
          const HEAP32=new Int32Array([4,9,99]);
          const AL={currentCtx:{sources:{4:a,9:b}},setSourceState(src,state){
            assert.ok(src === a || src === b); src.state=state;
            if(state===4116) src.processed=src.bufQueue.length;
          }};
        ''' + fixed + '''
          for(const [fn,state] of [[_alSourcePlayv,4114],[_alSourcePausev,4115],[_alSourceStopv,4116]]){
            fn(2,0); assert.equal(a.state,state); assert.equal(b.state,state);
          }
          assert.equal(a.processed,1); assert.equal(b.processed,1);
          a.state=b.state=0; _alSourceStopv(3,0);
          assert.equal(AL.currentCtx.err,40961); assert.equal(a.state,0); assert.equal(b.state,0);
          AL.currentCtx=null; _alSourceStopv(2,0);
        '''
        subprocess.run([node, "-e", script], check=True, capture_output=True, text=True)

    def test_unknown_runtime_is_not_silently_modified(self):
        with self.assertRaises(ValueError):
            patch.patch_source("AL.setSourceState(src,4116)")
