"""Exercise the real shell's recovery and file staging event handlers."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WebRecoveryTest(unittest.TestCase):
    def test_shell_recovery_and_same_name_drops(self):
        node = os.environ.get("NODE") or shutil.which("node")
        self.assertIsNotNone(node)
        script = r'''
const assert=require('node:assert/strict'), vm=require('node:vm'), fs=require('node:fs');
const html=fs.readFileSync('ports/web/shell/index.html','utf8');
const source=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1].replace('__G1R_MEMORY__','268435456');
function setup(){
  const nodes={};let reloads=0;
  function element(id){return nodes[id] ||= {style:{},listeners:{},files:[],hidden:false,
    classList:{remove(){},add(){}},addEventListener(n,f){this.listeners[n]=f},
    focus(){},click(){},removeAttribute(){},content:'test-build'};}
  const context={Module:{g1rPicks:[],g1rDrops:[],g1rPickErrors:[]},
    document:{getElementById:element,querySelector:()=>element('meta'),addEventListener(){}},
    location:{search:'',reload(){reloads++}},navigator:{},URLSearchParams,
    console:{log(){},error(){}},performance:{now:()=>0},Date:{now:()=>123},
    setTimeout(){},clearTimeout(){},requestAnimationFrame(){}};
  context.window=context;context.events={};context.addEventListener=(n,f)=>context.events[n]=f;
  vm.runInNewContext(source,context);
  return {context,nodes,element,get reloads(){return reloads}};
}
for(const failure of ['g1rLoveFailed','g1rDataFailed']){
  const s=setup();s.context[failure]();
  assert.equal(s.nodes.go.disabled,false);assert.equal(s.nodes.go.textContent,'Reload');
  assert.match(s.nodes.status.textContent,/could not download/);
  s.context.g1rLoveLoaded();assert.equal(s.nodes.go.textContent,'Reload');
  s.nodes.go.listeners.click();assert.equal(s.reloads,1);
}
{
  const s=setup();s.context.Love=()=>{throw Error('boot')};s.context.g1rLoveLoaded();
  s.nodes.go.listeners.click();assert.equal(s.nodes.go.textContent,'Reload');
  assert.match(s.nodes.status.textContent,/could not start/);
}
{
  const s=setup();s.context.events.error({message:'startup script failed'});
  assert.equal(s.nodes.go.disabled,false);assert.equal(s.nodes.go.textContent,'Reload');
}
async function run(){
  const s=setup(),m=s.context.Module,files=new Map();
  m.g1rFS={mkdirTree(){},writeFile(p,b){files.set(p,b)}};
  s.context.Love=()=>m.onRuntimeInitialized();s.context.g1rLoveLoaded();s.nodes.go.listeners.click();
  m.g1rPickFile('rom');s.nodes['pickprompt-cancel'].listeners.click();
  assert.equal(m.g1rPickErrors.shift(),'cancelled:No file was selected.');
  const file=(value)=>({name:'same.gb',arrayBuffer:()=>Promise.resolve(new Uint8Array([value]).buffer)});
  s.context.events.drop({preventDefault(){},dataTransfer:{files:[file(1),file(2)]}});
  await new Promise(setImmediate);
  assert.equal(files.size,2);assert.equal(m.g1rDrops.length,2);
  assert.notEqual(m.g1rDrops[0],m.g1rDrops[1]);
  assert.equal(files.get(m.g1rDrops[0])[0],1);assert.equal(files.get(m.g1rDrops[1])[0],2);
  s.context.events.drop({preventDefault(){},dataTransfer:{files:[{name:'bad.gb',arrayBuffer:()=>Promise.reject(Error('read failed'))}]}});
  await new Promise(setImmediate);
  assert.equal(s.nodes.error.style.display,'block');assert.match(s.nodes['error-text'].textContent,/read failed/);
  assert.equal(s.nodes['error-reload'].hidden,true);
  s.nodes['error-dismiss'].listeners.click();assert.equal(s.nodes.error.style.display,'none');
  m.onAbort();assert.equal(s.nodes.error.style.display,'block');assert.equal(s.nodes['error-reload'].hidden,false);
  assert.match(s.nodes['error-text'].textContent,/last save/);
  let stopped=false;s.nodes.error.listeners.keydown({key:'Escape',stopPropagation(){stopped=true},preventDefault(){}});
  assert.equal(stopped,true);assert.equal(s.nodes.error.style.display,'none');
  m.onAbort();
  s.nodes['error-reload'].listeners.click();assert.equal(s.reloads,1);
  console.log('Shell recovery and concurrent same-name drops verified');
}
run().catch(e=>{console.error(e);process.exitCode=1});
'''
        subprocess.run([node, "-e", script], cwd=ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
