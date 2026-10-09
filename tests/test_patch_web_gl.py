import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import unittest

spec = importlib.util.spec_from_file_location("patch_web_gl", Path(__file__).resolve().parents[1] / "scripts/patch_web_gl.py")
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


class WebGLPatchTest(unittest.TestCase):
    def test_failed_and_linked_program_queries(self):
        source = 'function query(program,pname,p){' + patch.OLD + '''{
          var log=GLctx.getProgramInfoLog(GL.programs[program]);
          if(log===null)log="(unknown error)"; HEAP32[p>>2]=log.length+1
        }else if(pname==35719){HEAP32[p>>2]=ptable.maxUniformLength
        }else{HEAP32[p>>2]=GLctx.getProgramParameter(GL.programs[program],pname)}}'''
        fixed = patch.patch_source(source)
        self.assertEqual(patch.patch_source(fixed), fixed)
        node = os.getenv("NODE") or shutil.which("node")
        self.assertIsNotNone(node, "Node is required for runtime validation")
        script = '''const assert=require('assert'); let errors=[];
          const HEAP32=new Int32Array(4);
          const GL={programInfos:{2:{maxUniformLength:19}}, programs:{1:'failed',2:'linked'},recordError(x){errors.push(x)}};
          const GLctx={getProgramInfoLog(p){return p==='failed' ? 'precision mismatch' : ''},
            getProgramParameter(p,n){return n===35713 ? p==='linked' : 0}};
        ''' + fixed + '''
          query(1,35713,4); assert.equal(HEAP32[1],0); assert.deepEqual(errors,[]);
          query(1,35716,4); assert.equal(HEAP32[1],19); assert.deepEqual(errors,[]);
          for(const n of [35712,35714]){query(1,n,4); assert.deepEqual(errors,[])}
          HEAP32[1]=77; query(1,35719,4); assert.equal(HEAP32[1],77); assert.deepEqual(errors,[1282]);
          query(2,35713,4); assert.equal(HEAP32[1],1);
          query(2,35719,4); assert.equal(HEAP32[1],19);
        '''
        subprocess.run([node, "-e", script], check=True, capture_output=True, text=True)

    def test_unknown_runtime_is_refused(self):
        with self.assertRaises(ValueError):
            patch.patch_source("function query(){}")
