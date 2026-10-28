import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {source,globals,worker} from './browser-harness.mjs';
test('popup exposes independent Chrome control while Windows is unavailable and restores on reopen',async()=>{
  const html=source('popup.html'),ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(match=>match[1]);
  assert.equal(new Set(ids).size,ids.length,'Popup IDs must be unique');
  for(const match of source('popup.js').matchAll(/\$\('([^']+)'\)/g))assert.ok(ids.includes(match[1]),'Missing real popup element: '+match[1]);
  const w=await worker();
  function popup(){
    const elements=new Map();
    const document={getElementById(id){if(!elements.has(id))elements.set(id,{disabled:false,hidden:false,open:false,textContent:'',setAttribute(){}});return elements.get(id);},querySelectorAll(){return [];}};
    const context=vm.createContext({...globals,document,chrome:{runtime:{sendMessage:msg=>w.dispatch(msg)}}});
    const code=source('popup.js');vm.runInContext(code.slice(0,code.lastIndexOf('\ninit().catch')),context);
    return {elements,run:code=>vm.runInContext(code,context)};
  }
  const p=popup();await p.run('refreshChromePause()');p.run('renderDesktopControl({fresh:false,canSet:false})');
  assert.equal(p.elements.get('desktopPause').disabled,true);assert.equal(p.elements.get('webPause').disabled,false);
  await p.run('changeChromePause()');assert.equal(p.elements.get('webPause').textContent,'Chrome 효과 재개');
  const reopened=popup();await reopened.run('refreshChromePause()');
  assert.equal(reopened.elements.get('webPause').textContent,'Chrome 효과 재개');
  await reopened.run('changeChromePause()');assert.equal(w.local.aw_web_pause.paused,false);
});
test('Windows guidance shows code entry only for first authentication or rejected credentials',()=>{
  const elements=new Map();const document={getElementById(id){if(!elements.has(id))elements.set(id,{});return elements.get(id);}};
  const context=vm.createContext({...globals,document});const code=source('popup.js');
  vm.runInContext(code.slice(0,code.lastIndexOf('\ninit().catch')),context);
  for(const failure of ['hostNotRegistered','desktopNotRunning','timeout','pairingRequired','pairingRejected']){
    context.connection={ok:false,code:failure,host:'registered',desktop:'stopped',authentication:'unknown',message:'synthetic'};
    vm.runInContext('renderWindowsConnection(connection)',context);
    assert.equal(elements.get('pairingEntry').open,['pairingRequired','pairingRejected'].includes(failure));
  }
  context.connection={ok:true,host:'registered',desktop:'running',authentication:'authenticated',message:'connected'};
  vm.runInContext('renderWindowsConnection(connection)',context);
  assert.equal(elements.get('pairingEntry').open,false);assert.match(elements.get('windowsAuthStatus').textContent,/인증 완료/);
});
