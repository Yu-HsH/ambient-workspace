import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {source,event,globals,worker,desktopReply} from './browser-harness.mjs';
const key='a'.repeat(64);
test('Windows flow distinguishes registration, launch, Desktop, auth and timeout failures',async()=>{
  for(const code of ['hostNotRegistered','hostForbidden','hostStartFailed','timeout','nativeUnavailable']){
    const w=await worker({local:{desktopPairingCode:key},native:()=>{throw Error(code);}});
    const reply=await w.dispatch({type:'AW_WINDOWS_CONNECT'});
    assert.equal(reply.connection.ok,false);assert.equal(reply.connection.code,code);
    assert.equal(w.local.desktopPairingCode,key);assert.equal(w.local.desktopEnabled,undefined);
  }
  const offline=await worker({local:{desktopPairingCode:key},native:()=>({ok:true,transport:'native',bridgeAvailable:false})});
  const reply=await offline.dispatch({type:'AW_WINDOWS_CONNECT'});
  assert.equal(reply.connection.code,'desktopNotRunning');assert.equal(reply.connection.host,'registered');
  assert.equal(offline.requests.length,1);
});
test('existing credential is reused; first pairing alone requests input; rejection preserves saved key',async()=>{
  const w=await worker({local:{desktopPairingCode:key,desktopEnabled:false,desktopVideoEnabled:true},native:desktopReply});
  const reply=await w.dispatch({type:'AW_WINDOWS_CONNECT'});
  assert.equal(reply.connection.authentication,'authenticated');assert.equal(w.local.desktopPairingCode,key);
  assert.equal(w.local.desktopEnabled,false);assert.equal(w.local.desktopVideoEnabled,true);
  assert.equal(w.requests.find(p=>p.type==='ping').token,key);assert.equal(w.disconnects.length,1);
  const fresh=await worker({native:desktopReply});
  assert.equal((await fresh.dispatch({type:'AW_WINDOWS_CONNECT'})).connection.code,'pairingRequired');
  assert.equal(fresh.requests.some(p=>p.type==='ping'),false);
  assert.equal((await fresh.dispatch({type:'AW_DESKTOP_PAIR',token:key})).connection.ok,true);
  assert.equal(fresh.local.desktopPairingCode,key);assert.equal(fresh.local.desktopEnabled,true);
  const rejected=await worker({local:{desktopPairingCode:key},native:packet=>{if(packet.type==='ping')throw Error('pairingRejected');return desktopReply(packet);}});
  const failed=await rejected.dispatch({type:'AW_DESKTOP_PAIR',token:'b'.repeat(64)});
  assert.equal(failed.connection.code,'pairingRejected');assert.equal(rejected.local.desktopPairingCode,key);
});
test('web documents cannot start connection, change pairing or control Windows',async()=>{
  const w=await worker({native:desktopReply});const sender={id:w.chrome.runtime.id,tab:{id:2},frameId:0,url:'https://chatgpt.com/'};
  for(const type of ['AW_WINDOWS_CONNECT','AW_DESKTOP_PAIR','AW_DESKTOP_CONTROL_SET','AW_NATIVE_STATUS']){
    assert.equal((await w.dispatch({type,token:key},sender)).ok,false);
  }
  assert.equal(w.requests.length,0);assert.equal(w.local.desktopPairingCode,undefined);
});
function transport(behavior){
  let opened=0;const packets=[],ports=[];const chrome={runtime:{lastError:null,connectNative(){
    const number=++opened;const port={onMessage:event(),onDisconnect:event(),disconnect(){},postMessage(message){packets.push({number,...message});queueMicrotask(()=>behavior({chrome,port,number,message}));}};ports.push(port);return port;
  }}};
  const context=vm.createContext({...globals,chrome});vm.runInContext(source('native-transport.js'),context);
  return {api:context.AW_NATIVE,packets,ports,get opened(){return opened;}};
}
test('stale Native port reopens once for reads; commands/media are never replayed',async()=>{
  for(const type of ['ping','control.hello','control.query']){
    const t=transport(({port,number,message})=>port.onMessage.emit(number===1?{id:message.id,transport:'bridgeUnavailable'}:{id:message.id,transport:'ok',result:{ok:true}}));
    assert.equal((await t.api.request({type})).ok,true);assert.equal(t.opened,2);assert.equal(t.packets.length,2);
  }
  for(const type of ['control.set','colors','frame','native.profile.export']){
    const t=transport(({port,message})=>port.onMessage.emit({id:message.id,transport:'bridgeUnavailable'}));
    await assert.rejects(t.api.request({type}),/bridgeUnavailable/);assert.equal(t.packets.length,1);
  }
  const t=transport(({port,message})=>port.onMessage.emit({id:message.id,transport:'bridgeUnavailable'}));
  await assert.rejects(t.api.request({type:'ping'}),/bridgeUnavailable/);assert.equal(t.packets.length,2);
});
test('Native disconnect reports only fixed diagnostic codes and timeout is bounded',async()=>{
  for(const [message,code] of [['Specified native messaging host not found.','hostNotRegistered'],['Access to the specified native messaging host is forbidden.','hostForbidden'],['Failed to start native messaging host.','hostStartFailed'],['private path or policy failure','nativeUnavailable']]){
    const t=transport(({chrome,port})=>{chrome.runtime.lastError={message};port.onDisconnect.emit();chrome.runtime.lastError=null;});
    await assert.rejects(t.api.request({type:'native.status'}),new RegExp(code));
  }
  const t=transport(()=>{});await assert.rejects(t.api.request({type:'control.set'},{timeoutMs:5}),/timeout/);assert.equal(t.packets.length,1);
});
