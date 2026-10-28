import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {worker,desktopReply,source,globals,event,copy} from './browser-harness.mjs';
async function setPause(w,paused){const {web}=await w.dispatch({type:'AW_WEB_PAUSE_QUERY'});return w.dispatch({type:'AW_WEB_PAUSE_SET',paused,instanceId:web.instanceId,revision:web.revision});}
test('Chrome-only pause/resume never uses Native or changes output/source preferences',async()=>{
  const local={enabled:true,sourceMode:'glow',youtubeAmbientEnabled:false,desktopVideoEnabled:true,sitesEnabled:{notion:false}};
  const w=await worker({local});
  assert.equal((await setPause(w,true)).web.paused,true);assert.equal((await setPause(w,false)).web.paused,false);
  assert.equal(w.requests.length,0);for(const [key,value] of Object.entries(local))assert.deepEqual(w.local[key],value);
});
test('Desktop offline, rejection, normal reads and reconnection cannot clear explicit Chrome pause',async()=>{
  let failure='bridgeUnavailable';const w=await worker({local:{desktopPairingCode:'a'.repeat(64)},native:packet=>{if(failure)throw Error(failure);return desktopReply(packet);}});
  await setPause(w,true);
  for(const code of ['bridgeUnavailable','pairingRejected','timeout',null]){
    failure=code;await w.dispatch({type:'AW_DESKTOP_CONTROL_QUERY'});
    assert.equal((await w.dispatch({type:'AW_WEB_PAUSE_QUERY'})).web.paused,true);
  }
  assert.equal((await w.dispatch({type:'AW_WINDOWS_CONNECT'})).connection.ok,true);
  assert.equal((await w.dispatch({type:'AW_WEB_PAUSE_QUERY'})).web.paused,true);
  await setPause(w,false);
  failure=null;w.context.AW_NATIVE.request=async packet=>desktopReply(packet,{paused:true,revision:1});
  await w.dispatch({type:'AW_DESKTOP_CONTROL_QUERY'});
  assert.equal((await w.dispatch({type:'AW_WEB_PAUSE_QUERY'})).web.paused,false);
});
test('multiple sites, tab navigation, popup reopen and worker restart restore the durable pause',async()=>{
  const tabs=[{id:1,url:'https://chatgpt.com/',status:'complete'},{id:2,url:'https://claude.ai/',status:'complete'},{id:3,url:'https://www.youtube.com/watch?v=synthetic',status:'complete'}];
  const w=await worker({tabs});await setPause(w,true);
  assert.equal(w.messages.filter(m=>m.type==='AW_WEB_CONTROL_APPLY'&&m.web.paused).length,2);
  assert.equal(w.messages.some(m=>m.type==='AW_YT_CONTROL_APPLY'&&m.web.paused),true);
  w.chrome.tabs.onUpdated.emit(2,{status:'loading'},tabs[1]);w.chrome.tabs.onUpdated.emit(2,{status:'complete'},tabs[1]);
  assert.equal((await w.dispatch({type:'AW_WEB_PAUSE_QUERY'})).web.paused,true);
  const restarted=await worker({tabs,local:w.local,session:w.session});
  const reply=await restarted.dispatch({type:'AW_WEB_PAUSE_QUERY'});
  assert.equal(reply.web.paused,true);assert.equal(reply.web.unconfirmedCount,0);
  assert.equal((await setPause(restarted,false)).web.paused,false);
  assert.equal(restarted.requests.length,0);
});
test('failed storage, duplicate and stale popup requests retain a consistent pause',async()=>{
  const w=await worker();const paused=await setPause(w,true),web=paused.web;
  w.setFailSave(true);assert.equal((await setPause(w,false)).ok,false);
  assert.equal((await w.dispatch({type:'AW_WEB_PAUSE_QUERY'})).web.paused,true);
  w.setFailSave(false);
  const duplicate=await w.dispatch({type:'AW_WEB_PAUSE_SET',paused:true,instanceId:web.instanceId,revision:web.revision});
  assert.equal(duplicate.web.revision,web.revision);
  await setPause(w,false);
  assert.equal((await w.dispatch({type:'AW_WEB_PAUSE_SET',paused:true,instanceId:web.instanceId,revision:web.revision})).ok,false);
});
test('renderer cannot write Chrome pause; legacy paused checkpoint remains paused',async()=>{
  const legacy={instanceId:'c'.repeat(32),revision:4,paused:true};const w=await worker({local:{aw_web_pause:legacy}});
  const sender={id:w.chrome.runtime.id,frameId:0,tab:{id:1},documentId:'doc',url:'https://chatgpt.com/'};
  assert.equal((await w.dispatch({type:'AW_WEB_PAUSE_SET',paused:false},sender)).ok,false);
  const reply=await w.dispatch({type:'AW_WEB_CONTROL_SYNC',rendererId:'f'.repeat(32)},sender);
  assert.equal(reply.web.paused,true);assert.equal(reply.web.fresh,true);
  assert.equal((await setPause(w,false)).web.paused,false);
});
test('YouTube target selection and Desktop-offline web fallback preserve pause and capture settings',async()=>{
  const tabs=[{id:1,url:'https://www.youtube.com/watch?v=synthetic',status:'complete',active:true},{id:2,url:'https://chatgpt.com/',status:'complete'}];
  for(const scope of ['youtube','all']){
    const w=await worker({tabs,local:{desktopPairingCode:'a'.repeat(64),desktopEnabled:true,sourceMode:'glow'},sendOffscreen:msg=>msg.type==='AW_OFFSCREEN_DESKTOP_PING'?{ok:false,error:'bridgeUnavailable'}:{ok:true}});
    await setPause(w,true);
    const reply=await w.dispatch({type:'AW_START_CAPTURE',scope});
    assert.equal(reply.ok,true);assert.equal(reply.desktopConnected,false);
    assert.deepEqual(reply.session.targetTabIds,scope==='youtube'?[]:[2]);
    assert.equal(Boolean(reply.desktopWarning),scope==='all');
    const start=w.messages.find(m=>m.type==='AW_OFFSCREEN_START');
    assert.equal(start.control.paused,true);assert.equal(start.sourceMode,'glow');assert.equal(start.desktopEnabled,false);
    assert.equal(w.local.aw_web_pause.paused,true);
  }
});
test('corrupt Chrome checkpoint cannot silently resume effects',async()=>{
  const w=await worker({local:{aw_web_pause:{paused:'invalid'}}});
  assert.equal((await w.dispatch({type:'AW_WEB_PAUSE_QUERY'})).ok,false);
  assert.equal(w.evaluate('wbReady'),false);
});
test('offscreen pause blocks frame work and native posts, drops late encodes, keeps capture track',async()=>{
  const timers=[],sent=[];const chrome={runtime:{id:'synthetic',onMessage:event(),async sendMessage(msg){sent.push(copy(msg));return {ok:true};}}};
  const c=vm.createContext({...globals,chrome,setTimeout(fn,delay){timers.push({fn,delay});return timers.length;},clearTimeout(){}});
  vm.runInContext(source('offscreen.js'),c);
  const run=code=>vm.runInContext(code,c);
  run(`sessionId='capture';running=true;stream={active:true,getVideoTracks:()=>[{id:'track'}]};
    sourceAuthority={ready:true,workerId:'worker',generation:1};sourceDeadline=performance.now()+10000;
    lastControlAt=performance.now();sourceMode='video';receiversVisible=true;youtubeAmbientEnabled=true;youtubeVisible=true;
    desktopEnabled=true;desktopToken='${'a'.repeat(64)}';desktopVideoEnabled=true;desktopOnline=true;
    crop={x:0,y:0,w:1,h:1};vid={readyState:4,videoWidth:1920,videoHeight:1080};
    canvas={width:560,height:315,toBlob(callback){globalThis.completeEncode=callback;}};ctx={drawImage(){throw Error('paused draw must not run');}};
    applyCaptureControl({workerId:'worker',generation:1,ready:true,paused:false});
    globalThis.oldEpoch=processingEpoch;
    globalThis.lateEncode=deliverWebFrame('capture',true,true);
    applyCaptureControl({workerId:'worker',generation:2,ready:true,paused:true});`);
  run('completeEncode({size:10})');await run('lateEncode');
  await run(`tick('capture')`);
  const gate=copy(run('processingSnapshot()'));
  assert.equal(gate.allowed,false);assert.equal(gate.active,true);assert.deepEqual(gate.trackIds,['track']);
  for(const key of ['samples','canvasCopies','jpegCalls','bridgePosts','webpBroadcasts'])assert.equal(gate.counts[key],0);
  assert.equal(gate.counts.webpCalls,1);assert.equal(gate.counts.lateDropped,1);
  assert.equal(run('processingValid(oldEpoch)'),false);assert.equal(timers.at(-1).delay>=900,true);
  await run(`deliverDesktop(['#000000','#ffffff'],'capture')`);assert.equal(sent.some(m=>m.type==='AW_NATIVE_REQUEST'),false);
  run(`applyCaptureControl({workerId:'worker',generation:3,ready:true,paused:false})`);
  assert.equal(run('processingAllowed()'),true);
  assert.equal(run(`applyCaptureControl({workerId:'worker',generation:2,ready:true,paused:true})`),false);
});
