importScripts('native-transport.js');
importScripts('native-profiles.js');
importScripts('windows-connection.js');
// Ambient Workspace v0.6: one YouTube capture -> web receivers + local desktop RGB/JPEG bridge.
const WORKSPACE_URLS = ['https://chatgpt.com/*','https://chat.openai.com/*','https://claude.ai/*','https://gemini.google.com/*','https://notion.so/*','https://www.notion.so/*','https://notion.com/*','https://www.notion.com/*','https://app.notion.com/*','https://app.notion.so/*'];
const SITES_DEFAULT = {chatgpt:true,claude:true,gemini:true,notion:true};
const YT_DEFAULTS={youtubeAmbientEnabled:true,youtubeAmbientStrength:84,youtubeAmbientBlur:118,youtubeAmbientSpread:440,youtubeAmbientFps:2};
const SETTINGS_DEFAULTS = {enabled:true,mode:'demo',intensity:30,blur:13,dim:30,saturation:88,protectCenter:true,focusWidth:70,sourceMode:'video',fps:5,focusHeight:115,palette:'twilight',motion:'vertical',motionSpeed:65,performanceMode:'balanced',sitesEnabled:SITES_DEFAULT,...YT_DEFAULTS};
const SESSION_KEY='aw_capture_session';
const DESKTOP_TOKEN_KEY='desktopPairingCode';
const TOKEN_RE=/^[a-f0-9]{64}$/;
const isOwnPopup=sender=>sender.id===chrome.runtime.id&&!sender.tab&&sender.url===chrome.runtime.getURL('source/popup.html');
const OFFSCREEN_PATH='source/offscreen.html';
const isOffscreen=sender=>sender.id===chrome.runtime.id&&!sender.tab&&sender.url===chrome.runtime.getURL(OFFSCREEN_PATH);
// Preserve existing key/settings bytes. Only the access policy changes; renderers
// continue to receive public preferences through the explicit broker below.
let storageBoundaryReady=false;
const storageBoundary=chrome.storage.local.setAccessLevel({accessLevel:'TRUSTED_CONTEXTS'}).then(()=>{storageBoundaryReady=true;return true;},()=>false);
const PUBLIC_SETTING_KEYS=Object.keys(SETTINGS_DEFAULTS);
let publicSettingsRevision=0;
async function publicSettingsView(){
  const revision=publicSettingsRevision,settings=await chrome.storage.local.get(SETTINGS_DEFAULTS);
  return {settings:Object.fromEntries(PUBLIC_SETTING_KEYS.map(key=>[key,settings[key]])),workerId:wbWorker,revision};
}
const popupRequests=new Set(['AW_GET_STATUS','AW_START_CAPTURE','AW_STOP_CAPTURE','AW_REFRESH_CROP','AW_WEB_PAUSE_QUERY','AW_WEB_PAUSE_SET','AW_WINDOWS_CONNECT','AW_DESKTOP_CONTROL_QUERY','AW_DESKTOP_CONTROL_SET','AW_DESKTOP_PAIR','AW_DESKTOP_TOGGLE','AW_DESKTOP_FORGET','AW_DESKTOP_PING','AW_NATIVE_STATUS','AW_NATIVE_PROFILE_LIST','AW_NATIVE_PROFILE_EXPORT','AW_NATIVE_PROFILE_IMPORT']);
const offscreenRequests=new Set(['AW_CAPTURE_CONTROL_SYNC','AW_FRAME_BROADCAST','AW_GLOW_BROADCAST','AW_OFFSCREEN_ENDED','AW_NATIVE_REQUEST','AW_NATIVE_CANCEL']);
const youtubePattern={test(value){try{const u=new URL(value);return u.protocol==='https:'&&['youtube.com','www.youtube.com'].includes(u.hostname)&&!u.username&&!u.password&&(!u.port||u.port==='443');}catch{return false;}}};
const siteFromUrl=(url='')=>{try {const h=new URL(url).hostname; if(['chatgpt.com','chat.openai.com'].includes(h))return 'chatgpt';if(h==='claude.ai')return 'claude';if(h==='gemini.google.com')return 'gemini';if(['notion.so','www.notion.so','notion.com','www.notion.com','app.notion.com','app.notion.so'].includes(h))return 'notion';}catch{}return null;};
// Desktop authority. Independent of capture tasks, send preference and offscreen lifetime.
const DC_PROFILE='aw_desktop_profile',DC_SESSION='aw_desktop_control',DC_ALARM='aw-desktop-control';
const DC_ID=/^[a-f0-9]{32}$/;
let dcEpoch=0,dcReady=null,dcTasks=Promise.resolve(),dcWrites=Promise.resolve(),dcAbort=null,dcQueryPending=null;
let dcToken='',dcProfile='',dcLease=null,dcState=null,dcPending=null,dcNotice='',dcCheckedAt=0,dcFresh=false;
let dcReportsSupported=false,dcIndependentSupported=false,dcReportError=false;
const dcId=()=>crypto.randomUUID().replaceAll('-','');
// Chrome owns its durable pause; Desktop reads/reconnects cannot change it.
const WB_LOCAL='aw_web_pause',wbWorker=dcId(),wbTargets=new Map(),ytTargets=new Map();
let wbState=null,wbReady=false,wbGeneration=0,wbInventoryKnown=false,wbLoading=null,wbWrites=Promise.resolve();
function wbSnapshot(value){
  return value&&DC_ID.test(value.instanceId)&&Number.isSafeInteger(value.revision)&&value.revision>=0&&typeof value.paused==='boolean'
    ?{instanceId:value.instanceId,revision:value.revision,paused:value.paused}:null;
}
function wbAdopt(value){
  if(JSON.stringify(value)!==JSON.stringify(wbState)){wbState=value;wbGeneration++;}
}
async function wbInit(){
  if(wbReady)return;
  if(!wbLoading)wbLoading=(async()=>{
    if(!await storageBoundary)throw Error('checkpointFailed');
    const local=await chrome.storage.local.get(WB_LOCAL);
    const saved=wbSnapshot(local[WB_LOCAL]);
    if(local[WB_LOCAL]!=null&&!saved)throw Error('checkpointFailed');
    // Preserve an rc.1 confirmed pause when upgrading, without rewriting settings.
    wbAdopt(saved||{instanceId:dcId(),revision:0,paused:false});
    wbReady=true;
  })().finally(()=>{wbLoading=null;});
  await wbLoading;
}
function wbSet(message){
  const result=wbWrites.then(async()=>{
    await wbInit();
    if(typeof message.paused!=='boolean'||message.revision!==wbState.revision||message.instanceId!==wbState.instanceId)throw Error('pauseConflict');
    if(message.paused!==wbState.paused){
      const next={instanceId:wbState.instanceId,revision:wbState.revision+1,paused:message.paused};
      // Resume only after persistence succeeds; failed saves retain the old gate.
      await chrome.storage.local.set({[WB_LOCAL]:next});
      wbAdopt(next);
      if(next.paused)cancelNativeOffscreen();
    }
    await Promise.all([reconcileCapture(),wbReconcile()]);
    return wbView();
  });
  wbWrites=result.catch(()=>{});return result;
}
function wbEnvelope(){return {workerId:wbWorker,generation:wbGeneration,ready:wbReady,paused:wbState?.paused===true,
  instanceId:wbState?.instanceId||null,revision:wbState?.revision??null,fresh:wbReady,checkedAt:wbReady?Date.now():0};}
// Actual offscreen processing ACK. Never merge it into Desktop or renderer ACKs.
let captureAck=null,captureCheckedAt=0,captureCheckSerial=0;
function captureView(){
  const localApplied=!!captureAck&&captureAck.workerId===wbWorker&&captureAck.generation===wbGeneration&&captureAck.sessionId===cachedSession?.sessionId&&Date.now()>=captureCheckedAt&&Date.now()-captureCheckedAt<5000;
  const fresh=dcFresh&&Date.now()-dcCheckedAt<5000;
  return {status:localApplied?'applied':'unconfirmed',localApplied,fresh,checkedAt:captureCheckedAt,gate:captureAck};
}
async function reconcileCapture(){
  const check=++captureCheckSerial;
  const control=wbEnvelope(),session=await sessionGet();
  if(check!==captureCheckSerial)return;
  if(!session){captureAck=null;captureCheckedAt=0;return;}
  // A pending read is not evidence that the same current gate stopped applying.
  // Generation/session and bounded ACK freshness still invalidate it immediately.
  let timeout;
  try{
    const reply=await Promise.race([sendOffscreen('AW_OFFSCREEN_CONTROL_APPLY',{control}),new Promise(resolve=>{timeout=setTimeout(resolve,600);})]);
    const gate=reply?.gate;
    if(check!==captureCheckSerial||control.generation!==wbGeneration||session.sessionId!==cachedSession?.sessionId)return;
    if(reply?.ok&&control.generation===wbGeneration&&gate?.version==='2c3-gate-1'&&gate.workerId===wbWorker&&gate.generation===wbGeneration&&
      gate.ready===true&&gate.paused===control.paused&&gate.allowed===!control.paused&&gate.sessionId===session.sessionId&&gate.active===true&&Number.isSafeInteger(gate.processingEpoch)){captureAck=gate;captureCheckedAt=Date.now();}
    else{captureAck=null;captureCheckedAt=0;}
  }catch{if(check===captureCheckSerial){captureAck=null;captureCheckedAt=0;}}finally{clearTimeout(timeout);}
}
const captureFrameAllowed=msg=>wbReady&&!wbState?.paused&&msg.controlWorkerId===wbWorker&&msg.controlGeneration===wbGeneration&&sourceGuard?.ready===true&&msg.sourceWorkerId===wbWorker&&msg.sourceGeneration===sourceGuard.generation;
function integrationView(){
  const fresh=dcFresh&&Date.now()-dcCheckedAt<5000;
  const renderer=registry=>{
    if(!wbInventoryKnown||!wbReady)return 'waiting';
    if(!registry.size)return 'notRequired';
    let enabled=0;
    for(const target of registry.values()){
      if(target.configuredOff)continue;
      const ack=target.ack;
      if(!ack||ack.generation!==wbGeneration)return 'waiting';
      if(!ack.enabled)return 'waiting';
      enabled++;
    }
    return enabled?'applied':'off';
  };
  const gate=captureView(),inFlight=gate.gate?.inFlight;
  const draining=wbState?.paused&&inFlight&&Object.values(inFlight).some(Boolean);
  const parts={desktop:!fresh||!dcState?'waiting':!dcState.desktopOutput.enabled||!dcState.desktopOutput.rgbEnabled&&!dcState.desktopOutput.videoEnabled?'off':'applied',
    web:renderer(wbTargets),youtube:renderer(ytTargets),capture:cachedSession===null?'notRequired':gate.status==='applied'&&!draining?'applied':'waiting'};
  // Chrome's opposite pause phase must not be reported as applied to Windows.
  if(dcState&&wbState?.paused!==dcState.globalPaused)for(const key of ['web','youtube','capture']){
    if(parts[key]==='applied')parts[key]=dcIndependentSupported?'independent':'waiting';
  }
  const confirmed=Object.values(parts).every(value=>['applied','off','notRequired','independent'].includes(value));
  const status=dcState?.persisted===false||dcNotice==='saveFailed'?'saveFailed':!fresh||dcReportError?'error':dcPending?'waiting':confirmed?'complete':Object.values(parts).includes('applied')?'partial':'waiting';
  return {status,paused:dcState?.globalPaused===true,parts,reportConfirmed:dcReportsSupported&&!dcReportError};
}
async function reportIntegration(epoch){
  if(!dcReportsSupported||!dcFresh||!dcLease||!dcState)return;
  try{
    const summary=integrationView();
    const reply=await dcFetch({type:'control.applied',instanceId:dcState.instanceId,revision:dcState.revision,globalPaused:dcState.globalPaused,parts:summary.parts},epoch);
    dcReportError=!reply.ok||reply.status!=='clientApplied';
  }catch{dcReportError=true;}
}
function wbView(registry=wbTargets,scope='supported-top-frame-documents'){
  const targets=[...registry].map(([tabId,target])=>({tabId,documentId:target.documentId||null,
    status:target.ack?.generation===wbGeneration?'applied':'unconfirmed',...(target.ack?.generation===wbGeneration?target.ack:{})}));
  const appliedCount=targets.filter(target=>target.status==='applied').length;
  return {...wbEnvelope(),inventoryKnown:wbInventoryKnown,scope,targets,appliedCount,unconfirmedCount:targets.length-appliedCount};
}
function wbAck(target,ack,youtube=false){
  if(!ack||ack.workerId!==wbWorker||ack.generation!==wbGeneration||ack.paused!==(wbState?.paused===true)||
    !DC_ID.test(ack.rendererId)||!Number.isSafeInteger(ack.appliedAt)||typeof ack.hidden!=='boolean'||typeof ack.enabled!=='boolean'||(!youtube&&!['demo','live'].includes(ack.mode)||youtube&&typeof ack.connected!=='boolean')||
    target.rendererId&&target.rendererId!==ack.rendererId)return;
  if(ack.ok!==true||(ack.paused&&!ack.hidden)||youtube&&(ack.rendererVersion!=='2c2-root-2'||typeof ack.gateOpen!=='boolean'||ack.paused&&ack.gateOpen||
      !Number.isSafeInteger(ack.rootCount)||ack.rootCount<0||ack.rootCount>1)){
    if(youtube)delete target.ack;return false;
  }
  target.rendererId=ack.rendererId;
  target.ack={generation:ack.generation,paused:ack.paused,hidden:ack.hidden,enabled:ack.enabled,...(youtube?{
    connected:ack.connected,rendererVersion:ack.rendererVersion,gateOpen:ack.gateOpen,rootCount:ack.rootCount}:{mode:ack.mode}),appliedAt:ack.appliedAt};
  return true;
}
async function wbReconcile(){
  if(!wbReady)return;
  try{
    const tabs=await chrome.tabs.query({url:[...WORKSPACE_URLS,'https://www.youtube.com/*','https://youtube.com/*']});wbInventoryKnown=true;
    for(const [registry,accept] of [[wbTargets,tab=>siteFromUrl(tab.url)],[ytTargets,tab=>youtubePattern.test(tab.url||'')]]){
      const ids=new Set(tabs.filter(accept).map(tab=>tab.id));
      for(const id of registry.keys())if(!ids.has(id))registry.delete(id);
    }
    const web=wbEnvelope();
    const prefs=await chrome.storage.local.get(['enabled','sitesEnabled','youtubeAmbientEnabled']);
    await Promise.allSettled(tabs.filter(tab=>siteFromUrl(tab.url)||youtubePattern.test(tab.url||'')).map(async tab=>{
      const youtube=youtubePattern.test(tab.url||''),registry=youtube?ytTargets:wbTargets;
      let target=registry.get(tab.id);
      if(!target){target={loading:tab.status==='loading'};registry.set(tab.id,target);}
      target.configuredOff=youtube?prefs.youtubeAmbientEnabled===false:prefs.enabled===false||prefs.sitesEnabled?.[siteFromUrl(tab.url)]===false;
      if(target.loading||target.ack?.generation===web.generation)return;
      let timer;
      try{
        const ack=await Promise.race([chrome.tabs.sendMessage(tab.id,{type:youtube?'AW_YT_CONTROL_APPLY':'AW_WEB_CONTROL_APPLY',web},target.documentId?{documentId:target.documentId}:{frameId:0}),
          new Promise(resolve=>{timer=setTimeout(resolve,600);})]);
        if(registry.get(tab.id)===target&&web.generation===wbGeneration)wbAck(target,ack,youtube);
      }finally{clearTimeout(timer);}
    }));
  }catch{wbInventoryKnown=false;}
}
const wbSender=(sender,youtube=false)=>sender.id===chrome.runtime.id&&Number.isInteger(sender.tab?.id)&&sender.frameId===0&&
  (!sender.documentLifecycle||sender.documentLifecycle==='active')&&/^https:\/\//.test(sender.url||'')&&(youtube?youtubePattern.test(sender.url||''):!!siteFromUrl(sender.url));
function wbRegister(sender,message,registry=wbTargets){
  let target=registry.get(sender.tab.id);
  if(!target||target.documentId!==sender.documentId||target.rendererId!==message.rendererId){
    target={documentId:sender.documentId,rendererId:message.rendererId};registry.set(sender.tab.id,target);
  }
  return target;
}
const nativeOffscreenJobs=new Map();
function cancelNativeOffscreen(){for(const controller of nativeOffscreenJobs.values())controller.abort();nativeOffscreenJobs.clear();}
const dcCheck=epoch=>{if(epoch!==dcEpoch)throw Error('connectionChanged');};
const dcSave=epoch=>{
  const value={lease:dcLease,state:dcState,pending:dcPending,notice:dcNotice,checkedAt:dcCheckedAt};
  const result=dcWrites.then(async()=>{
    dcCheck(epoch);
    try{
      await chrome.storage.session.set({[DC_SESSION]:value});
    }catch{throw Error('checkpointFailed');}
  });
  dcWrites=result.catch(()=>{});return result;
};
function dcReset(){
  dcReportsSupported=false;dcIndependentSupported=false;dcReportError=false;
  dcEpoch++;dcAbort?.abort();dcReady=null;dcQueryPending=null;dcLease=null;dcState=null;dcPending=null;dcCheckedAt=0;dcFresh=false;dcNotice='';
  dcWrites=dcWrites.catch(()=>{}).then(()=>chrome.storage.session.remove(DC_SESSION)).catch(()=>{});
  // Pairing loss is not a resume. Keep the last web gate through reconnection.
  wbGeneration++;
}
function dcView(){
  return {state:dcState,fresh:dcFresh&&Date.now()-dcCheckedAt<5000,checkedAt:dcCheckedAt,
    canSet:dcFresh&&Date.now()-dcCheckedAt<5000&&!!dcLease&&dcLease.instanceId===dcState?.instanceId&&dcLease.expiresAt>Date.now()&&!dcPending,
    pending:!!dcPending,notice:dcNotice,web:wbView(),youtube:wbView(ytTargets,'youtube-light-top-frame-documents'),capture:captureView(),integration:integrationView()};
}
async function dcInit(epoch){
  if(!dcReady)dcReady=(async()=>{
    if(!await storageBoundary)throw Error('checkpointFailed');
    await dcWrites;dcCheck(epoch);
    await wbInit();dcCheck(epoch);
    const local=await chrome.storage.local.get([DESKTOP_TOKEN_KEY,DC_PROFILE]);dcCheck(epoch);
    dcToken=local[DESKTOP_TOKEN_KEY]||'';dcProfile=local[DC_PROFILE];
    if(!DC_ID.test(dcProfile||'')){
      dcProfile=dcId();await chrome.storage.local.set({[DC_PROFILE]:dcProfile});dcCheck(epoch);
    }
    const saved=(await chrome.storage.session.get(DC_SESSION))[DC_SESSION];dcCheck(epoch);
    dcLease=saved?.lease||null;dcState=dcSnapshot(saved?.state);dcPending=saved?.pending||null;
    dcNotice=dcPending?'unconfirmed':saved?.notice||'';dcCheckedAt=saved?.checkedAt||0;
    // Checkpoints are never a fresh confirmation after a worker restart.
    dcFresh=false;
  })().catch(()=>{if(epoch===dcEpoch)dcReady=null;throw Error('checkpointFailed');});
  await dcReady;dcCheck(epoch);
}
function dcSnapshot(state){
  if(!state||typeof state.instanceId!=='string'||!DC_ID.test(state.instanceId)||!Number.isSafeInteger(state.revision)||state.revision<0||
    typeof state.globalPaused!=='boolean'||typeof state.persisted!=='boolean'||
    !['enabled','rgbEnabled','videoEnabled'].every(key=>typeof state.desktopOutput?.[key]==='boolean'))return null;
  return {instanceId:state.instanceId,revision:state.revision,globalPaused:state.globalPaused,persisted:state.persisted,
    desktopOutput:{enabled:state.desktopOutput?.enabled===true,rgbEnabled:state.desktopOutput?.rgbEnabled===true,videoEnabled:state.desktopOutput?.videoEnabled===true}};
}
async function dcFetch(packet,epoch){
  dcCheck(epoch);
  if(!TOKEN_RE.test(dcToken))throw Error('pairingRequired');
  const controller=new AbortController();dcAbort=controller;
  let timer;
  try{
    return await Promise.race([(async()=>{
      const reply=await AW_NATIVE.request({...packet,profileId:dcProfile,...(dcLease?{leaseId:dcLease.leaseId}:{}),token:dcToken},{signal:controller.signal,timeoutMs:1800});
      dcCheck(epoch);return reply;
    })(),new Promise((_,reject)=>{timer=setTimeout(()=>{controller.abort();reject(Error('timeout'));},1800);})]);
  }finally{clearTimeout(timer);if(dcAbort===controller)dcAbort=null;}
}
function dcAccept(reply,epoch,allowInstance=false){
  dcCheck(epoch);
  const state=dcSnapshot(reply.state);
  if(!state)throw Error('invalidSnapshot');
  if(dcState&&state.instanceId!==dcState.instanceId&&!allowInstance)throw Error('instanceChanged');
  if(dcState?.instanceId===state.instanceId&&state.revision<dcState.revision)throw Error('oldRevision');
  if(dcPending){
    const ack=Array.isArray(reply.state.results)?reply.state.results.find(result=>result.requestId===dcPending.requestId):null;
    if(state.instanceId!==dcPending.instanceId){dcPending=null;dcNotice='instanceChanged';}
    else if(ack){
      if(ack.instanceId!==state.instanceId||ack.expectedRevision!==dcPending.revision||ack.globalPaused!==dcPending.paused||
        ack.expectedInstanceId!==state.instanceId||!Number.isSafeInteger(ack.revision)||ack.revision>state.revision)throw Error('invalidAck');
      dcNotice=ack.outcome==='applied'?'applied':String(ack.outcome);dcPending=null;
    }else if(Date.now()-dcPending.sentAt>6000){dcPending=null;dcNotice='resultUnknown';}
  }
  if(dcState?.instanceId!==state.instanceId)dcLease=null;
  dcState=state;dcCheckedAt=Date.now();dcFresh=true;
  // Only the lease owner receives this field; never expose lease IDs in public status.
  if(reply.lease&&DC_ID.test(reply.lease.leaseId)&&reply.lease.instanceId===state.instanceId&&Number.isSafeInteger(reply.lease.expiresAt))dcLease=reply.lease;
}
async function dcRead(epoch){
  await dcInit(epoch);
  const hello=!dcLease||!dcFresh||dcLease.expiresAt<=Date.now();
  const reply=await dcFetch({type:hello?'control.hello':'control.query'},epoch);
  if(reply.ok){
    if(hello&&(reply.protocolVersion!==1||!reply.profileLeaseSupported||!reply.capabilities?.includes('desktop-pause-control')))throw Error('unsupported');
    if(hello){dcReportsSupported=reply.capabilities.includes('integration-status');dcIndependentSupported=reply.capabilities.includes('independent-chrome-pause');}
    if(!dcPending&&['leaseExpired','leaseConflict','pairingRequired','pairingRejected','unsupported','timeout','snapshotUnavailable','unavailable','ownerUnavailable','stale','ioError','checkpointFailed','oldRevision','invalidSnapshot','invalidAck'].includes(dcNotice))dcNotice='';
    dcAccept(reply,epoch,hello);await dcSave(epoch);return;
  }
  if(['leaseConflict','leaseExpired','instanceChanged'].includes(reply.status)){
    dcLease=null;
    const changed=!!dcState&&reply.state?.instanceId!==dcState.instanceId;
    // A conflict may show confirmed Desktop state, but cannot enable its write button.
    dcAccept(reply,epoch,true);dcNotice=changed?'instanceChanged':reply.status;await dcSave(epoch);return;
  }
  throw Error(reply.status||'unavailable');
}
function dcQueue(action){
  const epoch=dcEpoch;
  const result=dcTasks.then(async()=>{
    dcCheck(epoch);
    try{await action(epoch);}
    catch(error){
      if(epoch===dcEpoch){dcFresh=false;dcNotice=error.message==='checkpointFailed'?'checkpointFailed':dcPending?'unconfirmed':
        (/^(pairingRequired|pairingRejected|unsupported|timeout|invalidSnapshot|invalidAck|oldRevision|instanceChanged|snapshotUnavailable|leaseExpired|leaseConflict|busy|conflict|saveFailed|expired|unavailable|ownerUnavailable|stale|ioError|checkpointFailed)$/.test(error.message)?error.message:'unavailable');}
    }
    if(epoch===dcEpoch){await reconcileCapture();await wbReconcile();await reportIntegration(epoch);}
    return dcView();
  });
  dcTasks=result.catch(()=>{});return result;
}
const dcQuery=()=>{
  if(!dcQueryPending){
    const pending=dcQueue(dcRead);dcQueryPending=pending;
    pending.finally(()=>{if(dcQueryPending===pending)dcQueryPending=null;}).catch(()=>{});
  }
  return dcQueryPending;
};
let dcObservedAt=0;
function dcObserve(){
  // Keep Windows diagnostics/leases current without blocking Chrome-only controls.
  const now=Date.now();
  if(TOKEN_RE.test(dcToken)&&now-dcObservedAt>=(dcFresh?1000:5000)){
    dcObservedAt=now;dcQuery().catch(()=>{});
  }
}
function dcSet(message){
  return dcQueue(async epoch=>{
    await dcRead(epoch);
    if(!dcView().canSet)return;
    if(typeof message.paused!=='boolean'||dcState.instanceId!==message.instanceId||dcState.revision!==message.revision){dcNotice='conflict';return;}
    dcPending={requestId:dcId(),instanceId:dcState.instanceId,revision:dcState.revision,paused:message.paused,sentAt:Date.now()};
    dcNotice='requesting';
    try{await dcSave(epoch);}catch(error){dcPending=null;throw error;}
    dcCheck(epoch);
    const reply=await dcFetch({type:'control.set',requestId:dcPending.requestId,expectedInstanceId:dcPending.instanceId,
      expectedRevision:dcPending.revision,globalPaused:dcPending.paused,ttlMs:2000},epoch);
    if(!reply.ok){dcPending=null;dcNotice=reply.status||'unavailable';dcFresh=false;await dcSave(epoch);return;}
    if(reply.status!=='accepted'&&reply.status!=='ack')throw Error('invalidAck');
    dcAccept(reply,epoch);dcNotice=dcPending?'accepted':dcNotice;await dcSave(epoch);
    // No retry of control.set, including after timeout or worker recreation.
    const deadline=Date.now()+4000;
    while(dcPending&&Date.now()<deadline){
      await new Promise(resolve=>setTimeout(resolve,200));dcCheck(epoch);await dcRead(epoch);
    }
    if(dcPending){dcNotice='unconfirmed';await dcSave(epoch);}
  });
}
if(chrome.alarms){
  chrome.alarms.onAlarm.addListener(alarm=>{if(alarm.name===DC_ALARM)dcQuery().catch(()=>{});});
  // One minute also supports the existing minimum Chrome 116. Alarms may be delayed.
  chrome.alarms.get(DC_ALARM).then(alarm=>alarm||chrome.alarms.create(DC_ALARM,{periodInMinutes:1})).catch(()=>{});
  dcQuery().catch(()=>{});
}
// Read the session from storage on worker startup, not on every incoming frame.
let cachedSession,sessionLoad=null,sessionRevision=0,storageWrites=Promise.resolve(),modeRevision=0;
const writeStorage=task=>{const result=storageWrites.then(task);storageWrites=result.catch(()=>{});return result;};
const sessionGet=async()=>{
  if(cachedSession===undefined){
    if(!sessionLoad){
      const revision=sessionRevision;
      sessionLoad=chrome.storage.session.get(SESSION_KEY).then(value=>{
        if(revision===sessionRevision)cachedSession=value[SESSION_KEY]||null;
      }).finally(()=>{sessionLoad=null;});
    }
    await sessionLoad;
  }
  return cachedSession;
};
const sessionSet=async(value,job)=>{job?.check();const revision=++sessionRevision;cachedSession=value;await writeStorage(()=>revision===sessionRevision?chrome.storage.session.set({[SESSION_KEY]:value}):undefined);};
const sessionClear=async()=>{const revision=++sessionRevision;cachedSession=null;await writeStorage(()=>revision===sessionRevision?chrome.storage.session.remove(SESSION_KEY):undefined);};
const modeSet=async(value,job)=>{job?.check();const revision=++modeRevision;return writeStorage(()=>revision===modeRevision?chrome.storage.local.set(value):undefined);};
// Serialize state changes, while frame fan-out can continue using the read cache.
let sessionTasks=Promise.resolve(),controlEpoch=0,activeTask=null;
const cancelled=()=>{const error=Error('취소된 연결 요청이에요.');error.name='AbortError';return error;};
function waitForJob(value,job,onLate){
  return new Promise((resolve,reject)=>{
    const abort=()=>reject(cancelled());
    job.controller.signal.addEventListener('abort',abort,{once:true});
    if(job.controller.signal.aborted)abort();
    Promise.resolve(value).then(result=>{
      if(job.controller.signal.aborted){if(onLate)Promise.resolve(onLate(result)).catch(()=>{});reject(cancelled());}
      else resolve(result);
    },reject).finally(()=>job.controller.signal.removeEventListener('abort',abort)).catch(()=>{});
  });
}
function queueSessionTask(task){
  const epoch=controlEpoch;
  const result=sessionTasks.then(async()=>{
    if(epoch!==controlEpoch)throw cancelled();
    const job={controller:new AbortController(),session:null,check(){if(epoch!==controlEpoch||this.controller.signal.aborted)throw cancelled();},wait(value,onLate){return waitForJob(value,this,onLate);}};
    activeTask=job;
    try{return await job.wait(task(job));}finally{if(activeTask===job)activeTask=null;}
  });
  sessionTasks=result.catch(()=>{});
  return result;
}
const withSession=task=>queueSessionTask(async job=>task(await job.wait(sessionGet()),job));
async function cleanupSession(session){
  if(!session)return;
  const results=await Promise.allSettled([
    sendOffscreen('AW_OFFSCREEN_STOP',{sessionId:session.sessionId}),
    ...(session.targetTabIds||[]).map(id=>chrome.tabs.sendMessage(id,{type:'AW_STOP_REMOTE',sessionId:session.sessionId})),
    chrome.tabs.sendMessage(session.sourceTabId,{type:'AW_YT_AMBIENT_STOP',sessionId:session.sessionId})
  ]);
  return results[0].status==='fulfilled';
}
async function interruptSession(){
  const sessions=[cachedSession,activeTask?.session].filter(Boolean);
  const restoring=cachedSession===undefined?chrome.storage.session.get(SESSION_KEY).then(value=>{
    const old=value[SESSION_KEY];
    if(old&&old.sessionId!==cachedSession?.sessionId&&old.sessionId!==activeTask?.session?.sessionId)return cleanupSession(old);
  }):null;
  controlEpoch++;activeTask?.controller.abort();
  // Clear the runtime cache immediately. Durable writes retain order, even if an old API is slow.
  const tasks=[sessionClear(),modeSet({mode:'demo'}),...sessions.map(cleanupSession)];
  if(restoring)tasks.push(restoring);
  if(!sessions.length)tasks.push(sendOffscreen('AW_OFFSCREEN_STOP').catch(()=>null));
  let timeout;
  try{
    const result=await Promise.race([
      Promise.allSettled(tasks),
      new Promise(resolve=>{timeout=setTimeout(()=>resolve(null),500);})
    ]);
    if(!result)return {ok:true,cleanupPending:true};
    if(result.some(item=>item.status==='rejected'))return {ok:false,error:'중지했지만 일부 정리를 확인하지 못했어요. 상태를 다시 확인해 주세요.'};
    return {ok:true,cleanupPending:result.some(item=>item.status==='fulfilled'&&item.value===false)};
  }finally{clearTimeout(timeout);}
}
let creatingOffscreen=null;
async function ensureOffscreen(){
  if(creatingOffscreen)return creatingOffscreen;
  creatingOffscreen=(async()=>{
    const url=chrome.runtime.getURL(OFFSCREEN_PATH);
    if((await chrome.runtime.getContexts({contextTypes:['OFFSCREEN_DOCUMENT'],documentUrls:[url]})).length)return;
    await chrome.offscreen.createDocument({url:OFFSCREEN_PATH,reasons:['USER_MEDIA'],justification:'Capture YouTube video once and distribute a low-resolution visual to selected work tabs.'});
  })();
  try {await creatingOffscreen;} finally {creatingOffscreen=null;}
}
async function sendOffscreen(type,params={}){
  return chrome.runtime.sendMessage({type,target:'aw-offscreen',...params});
}
async function ensureWorkspaceScript(tabId,job){
  try{const r=await job.wait(chrome.tabs.sendMessage(tabId,{type:'AW_PERF_STATS'})); if(r?.ok)return;}catch{job.check();}
  job.check();await job.wait(chrome.scripting.executeScript({target:{tabId},files:['source/content.js']}));
}
async function getSourceCrop(tabId,job,documentId){
  const wait=value=>job?job.wait(value):value;
  try{return await wait(chrome.tabs.sendMessage(tabId,{type:'AW_VIDEO_RECT'},documentId?{documentId}:{frameId:0}));}
  catch{
    job?.check();await wait(chrome.scripting.executeScript({target:{tabId},files:['source/youtube.js']}));
    job?.check();return wait(chrome.tabs.sendMessage(tabId,{type:'AW_VIDEO_RECT'},documentId?{documentId}:{frameId:0}));
  }
}
// SA-01: a restarted worker must prove the current top document again.
// Persisted session/crop metadata cannot open this ephemeral authority.
let sourceGuard=null,sourceGeneration=0,sourceCheck=null;
const sourceEvents=[]; // bounded numeric diagnostics, never URLs or pixels
const cropValid=c=>c&&['x','y','w','h'].every(k=>Number.isFinite(c[k]))&&c.x>=0&&c.y>=0&&c.w>0&&c.h>0&&c.x+c.w<=1.001&&c.y+c.h<=1.001;
function blockSource(session,reason='navigation'){
  cancelNativeOffscreen();
  const guard={sessionId:session.sessionId,tabId:session.sourceTabId,workerId:wbWorker,generation:++sourceGeneration,ready:false};
  sourceGuard=guard;captureAck=null;captureCheckedAt=0;
  const event={reason,eventAt:Date.now(),generation:guard.generation};sourceEvents.push(event);if(sourceEvents.length>16)sourceEvents.shift();
  // Dispatch before queue/storage work. Worker fanout is already closed above.
  guard.blocked=sendOffscreen('AW_OFFSCREEN_SOURCE_BLOCK',{sessionId:session.sessionId,source:guard,eventAt:event.eventAt}).then(reply=>{
    event.blockedAt=reply?.source?.blockedAt||null;event.inFlight=reply?.source?.inFlight||null;return reply;
  }).catch(()=>null);
  return guard;
}
async function verifySource(session,job){
  if(sourceCheck?.sessionId===session.sessionId&&sourceCheck.guard===sourceGuard)return sourceCheck.promise;
  const guard=sourceGuard?.sessionId===session.sessionId?sourceGuard:blockSource(session,'validation');
  const check=()=>{job?.check();if(sourceGuard!==guard||cachedSession?.sessionId!==session.sessionId)throw cancelled();};
  const bounded=async value=>{let timer;try{return await Promise.race([value,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('sourceUnconfirmed')),600);})]);}finally{clearTimeout(timer);}};
  const work={sessionId:session.sessionId,guard};sourceCheck=work;
  work.promise=(async()=>{
    try{
      const before=await bounded(chrome.tabs.get(session.sourceTabId));check();
      if(!youtubePattern.test(before.url)||before.pendingUrl&&!youtubePattern.test(before.pendingUrl)){interruptSession().catch(()=>{});throw Error('sourceUnconfirmed');}
      if(before.pendingUrl||before.status==='loading')throw Error('sourceUnconfirmed');
      const [identity]=await bounded(chrome.scripting.executeScript({target:{tabId:session.sourceTabId,frameIds:[0]},func:()=>location.href}));check();
      if(!identity?.documentId||identity.frameId!==0||identity.result!==before.url)throw Error('sourceUnconfirmed');
      const crop=await bounded(getSourceCrop(session.sourceTabId,job,identity.documentId));check();
      const after=await bounded(chrome.tabs.get(session.sourceTabId));check();
      if(!cropValid(crop)||after.status==='loading'||after.pendingUrl||after.url!==identity.result||!youtubePattern.test(after.url))throw Error('sourceUnconfirmed');
      if(guard.ready&&(guard.documentId!==identity.documentId||guard.href!==after.url))throw Error('sourceChanged');
      const blocked=await bounded(guard.blocked);check();
      if(!blocked?.ok)throw Error('sourceUnconfirmed');
      const restored=!guard.ready;
      const yt=restored?await bounded(chrome.storage.local.get('youtubeAmbientEnabled')):null;check();
      const proof={workerId:wbWorker,generation:guard.generation,documentId:identity.documentId,ready:true};
      const reply=await bounded(sendOffscreen('AW_OFFSCREEN_SOURCE_APPLY',{sessionId:session.sessionId,source:proof,crop}));check();
      if(!reply?.ok)throw Error('sourceUnconfirmed');
      Object.assign(guard,proof,{href:after.url,crop});
      if(restored)for(const id of session.targetTabIds||[])chrome.tabs.sendMessage(id,{type:'AW_UPDATE_CROP',sessionId:session.sessionId,crop:{x:0,y:0,w:1,h:1}}).catch(()=>{});
      // complete can precede video readiness. Rebind the new document when the
      // later successful probe actually restores authority, including while paused.
      if(restored&&yt.youtubeAmbientEnabled!==false&&activeTask?.sourceTabId!==session.sourceTabId)chrome.tabs.sendMessage(session.sourceTabId,{type:'AW_YT_AMBIENT_START',sessionId:session.sessionId},{documentId:identity.documentId}).catch(()=>{});
      return proof;
    }catch(error){
      if(sourceGuard===guard)blockSource(session,'validationFailed');
      return null;
    }finally{if(sourceCheck===work)sourceCheck=null;}
  })();return work.promise;
}
function sourceNavigation(id,info,tab={}){
  const session=cachedSession?.sourceTabId===id?cachedSession:activeTask?.session?.sourceTabId===id?activeTask.session:null;
  if(!session){
    if(cachedSession===undefined){
      // Close before a waking worker's source identity read can settle.
      sendOffscreen('AW_OFFSCREEN_SOURCE_BLOCK',{source:{workerId:wbWorker,generation:++sourceGeneration},eventAt:Date.now()}).catch(()=>{});
      sessionGet().then(s=>{if(s?.sourceTabId===id)sourceNavigation(id,info,tab);}).catch(()=>{});
    }
    return;
  }
  blockSource(session,info.reason||'tabsUpdated');
  if([info.url,tab.pendingUrl,tab.url].filter(Boolean).some(url=>!youtubePattern.test(url))){interruptSession().catch(()=>{});return;}
  if(activeTask?.sourceTabId===id){interruptSession().catch(()=>{});return;}
}
async function enabledTabs(){
  const {sitesEnabled={}}=await chrome.storage.local.get('sitesEnabled');
  const allowed={...SITES_DEFAULT,...sitesEnabled};
  return (await chrome.tabs.query({url:WORKSPACE_URLS})).filter(t=>t.id && siteFromUrl(t.url) && allowed[siteFromUrl(t.url)]!==false);
}
async function chooseTargets(source,scope,requestedId,desktopReady=false){
  const all=(await enabledTabs()).filter(t=>t.id!==source.id);
  if(requestedId!=null){const tab=all.find(t=>t.id===requestedId);if(!tab)throw Error('선택한 작업 탭을 찾을 수 없어요.');return [tab];}
  if(scope==='youtube')return [];
  if(scope==='desktop'){
    if(!desktopReady)throw Error('데스크톱을 먼저 페어링하고 활성화해 주세요.');
    return [];
  }
  if(scope==='all'){
    if(!all.length && !desktopReady)throw Error('열린 지원 사이트가 없어요. 작업 사이트를 열거나 데스크톱을 연결해 주세요.');
    // Avoid accidental heavy frame distribution to dozens of pages.
    if(all.length>8)throw Error('작업 탭이 8개를 초과해요. 필요 없는 탭을 닫거나 대상 1개를 선택해 주세요.');
    return all;
  }
  all.sort((a,b)=>Number(b.windowId===source.windowId)-Number(a.windowId===source.windowId)||(b.lastAccessed||0)-(a.lastAccessed||0));
  if(all.length)return [all[0]];
  if(desktopReady)return [];
  throw Error('열린 지원 사이트가 없어요. 작업 탭을 열고 다시 시도해 주세요.');
}
async function stopSession(resetMode=true,job){
  const session=await (job?job.wait(sessionGet()):sessionGet());job?.check();
  const tasks=[sessionClear(),cleanupSession(session)];
  if(resetMode)tasks.push(modeSet({mode:'demo'},job));
  const result=await (job?job.wait(Promise.allSettled(tasks)):Promise.allSettled(tasks));
  if(result.some(item=>item.status==='rejected'))throw Error('연결 정리를 확인하지 못했어요. 다시 확인해 주세요.');
}
async function startCapture(sourceTabId,scope,targetTabId,job){
  await job.wait(wbInit());
  const source=await job.wait(chrome.tabs.get(sourceTabId));
  if(!youtubePattern.test(source.url||''))throw Error('유튜브 영상 탭에서 확장 프로그램을 열어 연결해 주세요.');
  const {desktopEnabled=false,[DESKTOP_TOKEN_KEY]:desktopToken='',youtubeAmbientEnabled=true}=await job.wait(chrome.storage.local.get(['desktopEnabled',DESKTOP_TOKEN_KEY,'youtubeAmbientEnabled']));
  const desktopConfigured=scope!=='youtube' && desktopEnabled && TOKEN_RE.test(desktopToken);
  const targets=await job.wait(chooseTargets(source,scope,targetTabId,desktopConfigured));
  let desktopReady=false,desktopWarning='';
  if(desktopConfigured){
    try{
      await job.wait(ensureOffscreen());
      const ping=await job.wait(sendOffscreen('AW_OFFSCREEN_DESKTOP_PING',{token:desktopToken}));
      if(!ping?.ok)throw Error(ping?.error||'PC의 Desktop 앱을 실행해 주세요.');
      desktopReady=true;
    }catch(e){
      job.check();
      desktopWarning='데스크톱은 연결되지 않았어요: '+e.message;
      if(!targets.length)throw Error(desktopWarning);
      // Desktop app may be closed. Web backgrounds must still work independently.
    }
  }
  await stopSession(true,job);job.check();
  const crop=await getSourceCrop(source.id,job);
  if(!crop)throw Error('유튜브 플레이어의 영상 영역을 찾지 못했어요. 영상을 재생하고 새로고침해 주세요.');
  await job.wait(ensureOffscreen());
  // Prepare receivers before starting the single tab capture.
  const sessionId=crypto.randomUUID();
  const prepared=[];
  job.session={sessionId,sourceTabId:source.id,targetTabIds:targets.map(t=>t.id)};
  for(const tab of targets){
    try{
      await ensureWorkspaceScript(tab.id,job);job.check();
      const r=await job.wait(chrome.tabs.sendMessage(tab.id,{type:'AW_BEGIN_REMOTE',sessionId,crop}),()=>chrome.tabs.sendMessage(tab.id,{type:'AW_STOP_REMOTE',sessionId}));
      if(!r?.ok)throw Error(r?.error||'화면 준비 실패');
      prepared.push(tab);
    }catch(e){
      job.check();
      // Failing to inject one site should not discard the other selected tabs.
      await chrome.tabs.sendMessage(tab.id,{type:'AW_STOP_REMOTE',sessionId}).catch(()=>{});
    }
  }
  if(!prepared.length && !desktopReady && !(scope==='youtube'&&youtubeAmbientEnabled))throw Error('연결 대상이 없어요. YouTube 조명 모드 또는 웹/데스크톱 대상을 선택해 주세요.');
  let started=false;
  try{
    await job.wait(sessionSet({sessionId,sourceTabId:source.id,targetTabIds:prepared.map(t=>t.id),targetSites:prepared.map(t=>siteFromUrl(t.url)),visibleTabIds:prepared.filter(t=>t.active).map(t=>t.id),cropFound:true,youtubeVisible:Boolean(source.active)},job));
    const proof=await job.wait(verifySource(cachedSession,job));job.check();
    if(!proof)throw Error('유튜브 문서와 영상 영역을 확인하지 못했어요. 이동이 끝난 뒤 다시 연결해 주세요.');
    const streamId=await job.wait(chrome.tabCapture.getMediaStreamId({targetTabId:source.id}));
    const {performanceMode='balanced',sourceMode='video',fps=5,youtubeAmbientEnabled=true,youtubeAmbientFps=2,desktopVideoEnabled=false}=await job.wait(chrome.storage.local.get(['performanceMode','sourceMode','fps','youtubeAmbientEnabled','youtubeAmbientFps','desktopVideoEnabled']));
    await job.wait(dcInit(dcEpoch));
    const result=await job.wait(sendOffscreen('AW_OFFSCREEN_START',{streamId,sessionId,crop:sourceGuard.crop,source:proof,performanceMode,sourceMode,fps,control:wbEnvelope(),webVisible:prepared.some(t=>t.active),youtubeAmbientEnabled,youtubeVisible:Boolean(source.active),youtubeAmbientFps,desktopEnabled:desktopReady,desktopToken:desktopReady?desktopToken:'',desktopVideoEnabled:desktopReady&&desktopVideoEnabled}),()=>cleanupSession(job.session));
    if(!result?.ok)throw Error(result?.error||'영상 캡처 준비 실패');
    await job.wait(sendOffscreen('AW_OFFSCREEN_SET_ACTIVE',{sessionId,active:prepared.some(t=>t.active)}));
    if(youtubeAmbientEnabled){await job.wait(chrome.tabs.sendMessage(source.id,{type:'AW_YT_AMBIENT_START',sessionId})).catch(()=>{});job.check();}
    await job.wait(modeSet({mode:'live',enabled:true},job));
    started=true;
  }finally{
    if(!started&&!job.controller.signal.aborted)await stopSession(true,job);
  }
  return {ok:true,session:{sessionId,sourceTabId:source.id,targetTabIds:prepared.map(t=>t.id),targetSites:prepared.map(t=>siteFromUrl(t.url)),visibleTabIds:prepared.filter(t=>t.active).map(t=>t.id),cropFound:true,youtubeVisible:Boolean(source.active)},connectedCount:prepared.length,requestedCount:targets.length,desktopConnected:desktopReady,desktopWarning};
}
async function validSession(job){
  const session=await job.wait(sessionGet());if(!session)return null;
  try{
    const r=await job.wait(sendOffscreen('AW_OFFSCREEN_STATUS'));
    if(r?.active && r.sessionId===session.sessionId){
      await job.wait(verifySource(session,job));
      return cachedSession?.sessionId===session.sessionId?{...session,cropFound:sourceGuard?.ready===true}:null;
    }
  }catch{job.check();}
  await stopSession(true,job);return null;
}
async function refreshCrop(job){
  const session=await job.wait(sessionGet());if(!session)throw Error('유튜브 연결이 없어요.');
  blockSource(session,'refresh');
  const proof=await job.wait(verifySource(session,job));
  await job.wait(sessionSet({...session,cropFound:!!proof},job));
  return {ok:true,cropFound:!!proof};
}
async function removeTarget(tabId,sessionId,job){
  const session=await job.wait(sessionGet()); if(!session||session.sessionId!==sessionId||!session.targetTabIds.includes(tabId))return;
  const ids=session.targetTabIds.filter(id=>id!==tabId);
  if(!ids.length){
    const {desktopEnabled=false,[DESKTOP_TOKEN_KEY]:token='',youtubeAmbientEnabled=true}=await job.wait(chrome.storage.local.get(['desktopEnabled',DESKTOP_TOKEN_KEY,'youtubeAmbientEnabled']));
    if(!(desktopEnabled&&TOKEN_RE.test(token))&&!youtubeAmbientEnabled){await stopSession(true,job);return;}
  }
  const visibleTabIds=(session.visibleTabIds||[]).filter(id=>id!==tabId);
  await job.wait(sessionSet({...session,targetTabIds:ids,visibleTabIds},job));
  await sendOffscreen('AW_OFFSCREEN_SET_ACTIVE',{sessionId:session.sessionId,active:visibleTabIds.length>0}).catch(()=>{});
}
// This listener receives frame images ONLY from our private offscreen document.
chrome.runtime.onMessage.addListener(function onRuntimeMessage(msg,sender,sendResponse){
  if(!msg?.type)return;
  if(popupRequests.has(msg.type)&&!isOwnPopup(sender)||offscreenRequests.has(msg.type)&&!isOffscreen(sender)){
    sendResponse({ok:false,error:'허용되지 않은 확장 메시지예요.'});return;
  }
  // Offscreen-directed traffic must be handled only by the offscreen listener.
  if(msg.target==='aw-offscreen')return;
  if(!storageBoundaryReady){
    storageBoundary.then(ok=>{if(ok)onRuntimeMessage(msg,sender,sendResponse);else sendResponse({ok:false,error:'확장 저장소 보호를 확인하지 못했어요. 확장을 다시 로드해 주세요.'});});return true;
  }
  if(AW_PROFILES.isBusy()&&['AW_START_CAPTURE','AW_REFRESH_CROP','AW_WINDOWS_CONNECT','AW_WEB_PAUSE_SET','AW_DESKTOP_PAIR','AW_DESKTOP_TOGGLE','AW_DESKTOP_FORGET','AW_DESKTOP_CONTROL_SET'].includes(msg.type)){
    sendResponse({ok:false,error:'설정 백업·복원이 진행 중이에요. 완료 후 다시 시도해 주세요.'});return;
  }
  if(['AW_NATIVE_PROFILE_LIST','AW_NATIVE_PROFILE_EXPORT','AW_NATIVE_PROFILE_IMPORT'].includes(msg.type)){
    if(!isOwnPopup(sender)){sendResponse({ok:false});return;}
    const operation=msg.type.split('_').at(-1).toLowerCase();
    AW_PROFILES.transfer(operation,{backupId:msg.backupId,confirmed:msg.confirmed===true},{
      captureActive:async()=>!!await sessionGet()||!!activeTask,
      idle:async()=>{dcReset();cancelNativeOffscreen();await Promise.all([dcTasks,dcWrites,wbWrites,storageWrites,sessionTasks]);},
      reset:async()=>{dcReset();await dcWrites;wbReady=false;await wbInit();await wbReconcile();}
    }).then(result=>sendResponse(result)).catch(error=>sendResponse({ok:false,error:[
      'profileBusy','profileStopCapture','profileConfirmationRequired','profileBackupFailed','profileInvalid','profileRecoveryRequired','profileImportFailedRestored'
    ].includes(error.message)?error.message:'profileNativeUnavailable'}));return true;
  }
  if(msg.type==='AW_RENDERER_SETTINGS_GET'){
    if(!wbSender(sender)&&!wbSender(sender,true)){sendResponse({ok:false});return;}
    publicSettingsView().then(view=>sendResponse({ok:true,...view})).catch(()=>sendResponse({ok:false}));return true;
  }
  if(msg.type==='AW_RENDERER_DEMO'){
    if(!wbSender(sender)){sendResponse({ok:false});return;}
    modeSet({mode:'demo'}).then(()=>sendResponse({ok:true})).catch(()=>sendResponse({ok:false}));return true;
  }
  if(['AW_WEB_CONTROL_SYNC','AW_WEB_CONTROL_ACK','AW_YT_CONTROL_SYNC','AW_YT_CONTROL_ACK'].includes(msg.type)){
    const youtube=msg.type.startsWith('AW_YT_'),registry=youtube?ytTargets:wbTargets;
    if(!wbSender(sender,youtube)||!DC_ID.test(msg.rendererId||'')){sendResponse({ok:false});return;}
    if(msg.type.endsWith('_ACK')){
      const target=registry.get(sender.tab.id);
      if(!target||target.loading||target.documentId&&target.documentId!==sender.documentId||target.rendererId&&target.rendererId!==msg.rendererId){sendResponse({ok:false});return;}
      target.documentId=sender.documentId;const applied=wbAck(target,msg,youtube);sendResponse({ok:youtube?applied===true:true});return;
    }
    wbRegister(sender,msg,registry);
    // Visible enabled content wakes MV3 without a permanent worker timer or offscreen.
    // Windows observation runs separately from Chrome's durable pause response.
    dcObserve();
    const query=wbInit();
    query.then(async()=>sendResponse({ok:true,web:wbEnvelope(),publicSettings:await publicSettingsView()})).catch(()=>sendResponse({ok:false}));return true;
  }
  if(msg.type==='AW_NATIVE_STATUS'){
    if(!isOwnPopup(sender)){sendResponse({ok:false});return;}
    AW_NATIVE.request({type:'native.status'}).then(native=>sendResponse({ok:true,extensionId:chrome.runtime.id,native}),
      error=>sendResponse({ok:false,extensionId:chrome.runtime.id,error:error.message}));return true;
  }
  if(msg.type==='AW_WEB_PAUSE_QUERY'||msg.type==='AW_WEB_PAUSE_SET'){
    const work=msg.type==='AW_WEB_PAUSE_SET'?wbSet(msg):wbInit().then(async()=>{
      await Promise.all([reconcileCapture(),wbReconcile()]);return wbView();
    });
    work.then(web=>sendResponse({ok:true,web}),error=>sendResponse({ok:false,error:error.message==='pauseConflict'?
      '다른 팝업에서 Chrome 상태가 바뀌었습니다. 다시 확인한 뒤 눌러 주세요.':'Chrome 일시정지 상태를 저장·확인하지 못했습니다. 기존 상태를 유지합니다.'}));return true;
  }
  if(msg.type==='AW_DESKTOP_CONTROL_QUERY'||msg.type==='AW_DESKTOP_CONTROL_SET'){
    if(!isOwnPopup(sender)){sendResponse({ok:false,error:'확장 팝업에서만 Desktop을 제어할 수 있어요.'});return;}
    (msg.type==='AW_DESKTOP_CONTROL_SET'?dcSet(msg):dcQuery()).then(control=>sendResponse({ok:true,control}))
      .catch(()=>sendResponse({ok:false,error:'Desktop 상태 미확인 · 팝업을 다시 열어 주세요.'}));return true;
  }
  const fromOffscreen=isOffscreen(sender);
  if(msg.type==='AW_NATIVE_CANCEL'){
    if(!fromOffscreen||!DC_ID.test(msg.requestId||'')){sendResponse({ok:false});return;}
    nativeOffscreenJobs.get(msg.requestId)?.abort();sendResponse({ok:true});return;
  }
  if(msg.type==='AW_NATIVE_REQUEST'){
    const packet=msg.packet,media=packet?.type==='colors'||packet?.type==='frame';
    if(!fromOffscreen||!DC_ID.test(msg.requestId||'')||nativeOffscreenJobs.has(msg.requestId)||nativeOffscreenJobs.size>=4||
      !packet||!['ping','colors','frame'].includes(packet.type)||media&&(!captureFrameAllowed(msg)||cachedSession?.sessionId!==msg.sessionId)){
      sendResponse({ok:false,error:'invalid'});return;
    }
    const controller=new AbortController();nativeOffscreenJobs.set(msg.requestId,controller);
    AW_NATIVE.request(packet,{signal:controller.signal,timeoutMs:1200}).then(result=>sendResponse({ok:true,result}),
      error=>sendResponse({ok:false,error:['pairingRequired','pairingRejected','bridgeUnavailable','nativeUnavailable','timeout','invalid','busy','aborted'].includes(error.message)?error.message:'nativeUnavailable'}))
      .finally(()=>{if(nativeOffscreenJobs.get(msg.requestId)===controller)nativeOffscreenJobs.delete(msg.requestId);});
    return true;
  }
  if(msg.type==='AW_CAPTURE_CONTROL_SYNC'){
    if(!fromOffscreen){sendResponse({ok:false});return;}
    const query=(async()=>{const session=await sessionGet();const source=session?await verifySource(session):null;
      // Source health must not wait behind a slow/offline Desktop native read.
      await wbInit();dcObserve();await reconcileCapture();return source;})();
    query.then(source=>sendResponse({ok:true,web:wbEnvelope(),source})).catch(()=>sendResponse({ok:false}));return true;
  }
  if((msg.type==='AW_FRAME_BROADCAST'||msg.type==='AW_GLOW_BROADCAST') && fromOffscreen){
    (async()=>{
      if(!captureFrameAllowed(msg))return;
      const s=await sessionGet();if(!captureFrameAllowed(msg)||!s||s.sessionId!==msg.sessionId)return;
      const ids=s.targetTabIds.filter(id=>(s.visibleTabIds||[]).includes(id));
      const data=msg.type==='AW_FRAME_BROADCAST'
        ? {type:'AW_REMOTE_FRAME',sessionId:s.sessionId,frame:msg.frame}
        : {type:'AW_REMOTE_GLOW',sessionId:s.sessionId,colors:msg.colors};
      const results=await Promise.allSettled(ids.map(id=>captureFrameAllowed(msg)?chrome.tabs.sendMessage(id,data):Promise.resolve(null)));
      let delivered=results.some(r=>r.status==='fulfilled'&&r.value?.ok===true);
      if(captureFrameAllowed(msg)&&msg.type==='AW_FRAME_BROADCAST' && msg.youtubeFrame && s.youtubeVisible){
        const reply=await chrome.tabs.sendMessage(s.sourceTabId,{type:'AW_YT_AMBIENT_FRAME',sessionId:s.sessionId,frame:msg.frame}).catch(()=>null);
        delivered=delivered||reply?.ok===true;
      }
      return delivered&&captureFrameAllowed(msg);
    })().then(delivered=>sendResponse({ok:delivered===true})).catch(()=>sendResponse({ok:false}));
    return true;
  }
  if(msg.type==='AW_OFFSCREEN_ENDED' && fromOffscreen){
    if(cachedSession?.sessionId===msg.sessionId||activeTask?.session?.sessionId===msg.sessionId)interruptSession().catch(()=>{});
    else withSession((s,job)=>{if(s?.sessionId===msg.sessionId)return stopSession(true,job);}).catch(()=>{});
    sendResponse({ok:true});return;
  }
  if(msg.type==='AW_SOURCE_SUSPEND'||msg.type==='AW_SOURCE_RECT_CHANGED'){
    if(!wbSender(sender,true))return;
    if(cachedSession?.sourceTabId===sender.tab.id){
      if(sourceGuard?.documentId&&sourceGuard.documentId!==sender.documentId)return;
      sourceNavigation(sender.tab.id,{reason:msg.type==='AW_SOURCE_SUSPEND'?'documentLeaving':'geometry'},sender.tab);
    }
    withSession(async(s,job)=>{
      if(s?.sourceTabId!==sender.tab.id)return;
      if(!sourceGuard||sourceGuard.sessionId!==s.sessionId)blockSource(s,'geometry');
      if(msg.type==='AW_SOURCE_RECT_CHANGED')await job.wait(verifySource(s,job));
    }).catch(()=>{});
    sendResponse({ok:true});return;
  }
  if(msg.type==='AW_YT_VISIBILITY'){
    if(!wbSender(sender,true)){sendResponse({ok:false});return;}
    if(sender.tab?.id)withSession(async(s,job)=>{
      if(s?.sourceTabId!==sender.tab.id)return;
      const youtubeVisible=Boolean(msg.visible);
      await job.wait(sessionSet({...s,youtubeVisible},job));
      await sendOffscreen('AW_OFFSCREEN_YOUTUBE_CONFIG',{sessionId:s.sessionId,visible:youtubeVisible}).catch(()=>{});
    }).catch(()=>{});
    sendResponse({ok:true});return;
  }
  if(msg.type==='AW_RECEIVER_VISIBILITY'){
    if(!wbSender(sender)){sendResponse({ok:false});return;}
    if(sender.tab?.id){
      withSession(async(s,job)=>{
        if(!s||s.sessionId!==msg.sessionId||!s.targetTabIds.includes(sender.tab.id))return;
        const visible=new Set(s.visibleTabIds||[]);
        if(msg.visible)visible.add(sender.tab.id);else visible.delete(sender.tab.id);
        const visibleTabIds=Array.from(visible);
        await job.wait(sessionSet({...s,visibleTabIds},job));
        await sendOffscreen('AW_OFFSCREEN_SET_ACTIVE',{sessionId:s.sessionId,active:visibleTabIds.length>0}).catch(()=>{});
      }).catch(()=>{});
    }
    sendResponse({ok:true});return;
  }
  if(msg.type==='AW_RECEIVER_LEFT'){
    if(!wbSender(sender)){sendResponse({ok:false});return;}
    if(sender.tab?.id)queueSessionTask(job=>removeTarget(sender.tab.id,msg.sessionId,job)).catch(()=>{});
    sendResponse({ok:true});return;
  }
  if(msg.type==='AW_GET_STATUS'){
    queueSessionTask(async job=>{
      const session=await validSession(job);
      let captureStats=null;
      if(session){
        try{captureStats=(await job.wait(sendOffscreen('AW_OFFSCREEN_STATUS')))?.stats||null;}catch{job.check();}
      }
      const {desktopEnabled=false,[DESKTOP_TOKEN_KEY]:pairingCode=''}=await job.wait(chrome.storage.local.get(['desktopEnabled',DESKTOP_TOKEN_KEY]));
      let desktopRuntime=null;
      if(session){try{desktopRuntime=(await job.wait(sendOffscreen('AW_OFFSCREEN_STATUS')))?.desktop||null;}catch{job.check();}}
      sendResponse({ok:true,session,captureStats,desktop:{enabled:desktopEnabled,paired:TOKEN_RE.test(pairingCode),runtime:desktopRuntime}});
    }).catch(e=>sendResponse({ok:false,error:e.message}));return true;
  }
  if(['AW_WINDOWS_CONNECT','AW_DESKTOP_PAIR','AW_DESKTOP_TOGGLE','AW_DESKTOP_FORGET','AW_DESKTOP_PING'].includes(msg.type)){
    queueSessionTask(async job=>{
      if(!isOwnPopup(sender))throw Error('확장 설정창에서만 연결할 수 있어요.');
      if(msg.type==='AW_DESKTOP_FORGET'){
        await job.wait(chrome.storage.local.remove([DESKTOP_TOKEN_KEY,'desktopEnabled']));
        const s=await job.wait(sessionGet());
        if(s)await sendOffscreen('AW_OFFSCREEN_DESKTOP_CONFIG',{sessionId:s.sessionId,enabled:false,token:''});
        return {ok:true};
      }
      let {desktopEnabled=false,[DESKTOP_TOKEN_KEY]:token=''}=await job.wait(chrome.storage.local.get(['desktopEnabled',DESKTOP_TOKEN_KEY]));
      const inputToken=msg.type==='AW_DESKTOP_PAIR'||msg.type==='AW_WINDOWS_CONNECT'&&typeof msg.token==='string'&&msg.token.trim();
      if(inputToken){
        token=String(msg.token||'').trim();
        if(!TOKEN_RE.test(token))throw Error('Desktop 앱에서 복사한 64자리 페어링 코드를 입력해 주세요.');
      }
      if(msg.type==='AW_DESKTOP_TOGGLE')desktopEnabled=Boolean(msg.enabled);
      const needsPing=msg.type==='AW_WINDOWS_CONNECT'||msg.type==='AW_DESKTOP_PAIR'||msg.type==='AW_DESKTOP_PING'||desktopEnabled;
      let connection=null;
      if(needsPing){
        // Retire the process bound to the previous registry path. A late Desktop
        // command stays unconfirmed and is never replayed on the new port.
        dcReset();cancelNativeOffscreen();AW_NATIVE.disconnect('connectionChanged');
        await job.wait(dcTasks);await job.wait(dcWrites);
        connection=await job.wait(AW_WINDOWS.check(token));
        if(!connection.ok)return {ok:true,connection};
      }
      if(inputToken)desktopEnabled=true;
      await job.wait(chrome.storage.local.set({[DESKTOP_TOKEN_KEY]:token,desktopEnabled}));
      const s=await job.wait(sessionGet());
      if(s){
        await sendOffscreen('AW_OFFSCREEN_DESKTOP_CONFIG',{sessionId:s.sessionId,enabled:desktopEnabled,token:desktopEnabled?token:''});
      }
      dcQuery().catch(()=>{});
      return {ok:true,enabled:desktopEnabled,paired:TOKEN_RE.test(token),...(connection?{connection}:{})};
    }).then(sendResponse).catch(e=>sendResponse({ok:false,error:e.message,cancelled:e.name==='AbortError'}));return true;
  }
  if(msg.type==='AW_START_CAPTURE'){
    queueSessionTask(async job=>{
      if(!isOwnPopup(sender))throw Error('확장 설정창에서 실행해 주세요.');
      const [tab]=await job.wait(chrome.tabs.query({active:true,currentWindow:true}));
      if(!tab?.id)throw Error('현재 유튜브 탭을 확인할 수 없어요.');
      job.sourceTabId=tab.id;
      return startCapture(tab.id,['all','desktop','youtube'].includes(msg.scope)?msg.scope:'recent',Number.isInteger(msg.targetTabId)?msg.targetTabId:null,job);
    }).then(sendResponse).catch(e=>sendResponse({ok:false,error:e.message,cancelled:e.name==='AbortError'}));return true;
  }
  if(msg.type==='AW_REFRESH_CROP'){
    queueSessionTask(refreshCrop).then(sendResponse).catch(e=>sendResponse({ok:false,error:e.message}));return true;
  }
  if(msg.type==='AW_STOP_CAPTURE'){
    interruptSession().then(sendResponse).catch(e=>sendResponse({ok:false,error:e.message}));return true;
  }
});
chrome.tabs.onRemoved.addListener(tabId=>{
  wbTargets.delete(tabId);ytTargets.delete(tabId);
  if(cachedSession?.sourceTabId===tabId||activeTask?.sourceTabId===tabId){interruptSession().catch(()=>{});return;}
  withSession((s,job)=>{if(!s)return;if(s.sourceTabId===tabId)return stopSession(true,job);if(s.targetTabIds.includes(tabId))return removeTarget(tabId,s.sessionId,job);}).catch(()=>{});
});
chrome.tabs.onUpdated.addListener((id,info,tab)=>{
  if(info.status==='loading'||info.url)sourceNavigation(id,info,tab);
  if(info.status==='loading'||info.url){wbTargets.delete(id);ytTargets.delete(id);}
  if(info.status==='loading'&&siteFromUrl(tab.url||info.url))wbTargets.set(id,{loading:true});
  if(info.status==='loading'&&youtubePattern.test(tab.url||info.url||''))ytTargets.set(id,{loading:true});
  if(info.status==='complete'&&(siteFromUrl(tab.url)||youtubePattern.test(tab.url||''))){
    const target=(youtubePattern.test(tab.url||'')?ytTargets:wbTargets).get(id);if(target)target.loading=false;
    wbInit().then(wbReconcile).catch(()=>{});
  }
  if(!info.url && info.status!=='complete')return;
  withSession(async(s,job)=>{
    if(!s)return;
    if(s.sourceTabId===id){
      if(!youtubePattern.test(tab.url||info.url||'')){blockSource(s,'restoredNavigation');await stopSession(true,job);return;}
      if(info.status==='complete'||info.url){
        const proof=await job.wait(verifySource(s,job));
        if(proof){
          const yt=await job.wait(chrome.storage.local.get('youtubeAmbientEnabled'));
          if(yt.youtubeAmbientEnabled!==false)await job.wait(chrome.tabs.sendMessage(id,{type:'AW_YT_AMBIENT_START',sessionId:s.sessionId})).catch(()=>{});
          await job.wait(sendOffscreen('AW_OFFSCREEN_YOUTUBE_CONFIG',{sessionId:s.sessionId,visible:Boolean(tab.active)}));
          await job.wait(sessionSet({...s,cropFound:true,youtubeVisible:Boolean(tab.active)},job));
        }
      }
      return;
    }
    if(!s.targetTabIds.includes(id))return;
    if(!siteFromUrl(tab.url||info.url||''))return removeTarget(id,s.sessionId,job);
    if(info.status==='complete'){
      try{
        await ensureWorkspaceScript(id,job);job.check();
        await job.wait(chrome.tabs.sendMessage(id,{type:'AW_BEGIN_REMOTE',sessionId:s.sessionId,crop:s.cropFound?{x:0,y:0,w:1,h:1}:null}),()=>chrome.tabs.sendMessage(id,{type:'AW_STOP_REMOTE',sessionId:s.sessionId}));
      }catch{}
    }
  }).catch(()=>{});
});
chrome.tabCapture.onStatusChanged.addListener(info=>{
  if(!['stopped','error'].includes(info.status))return;
  // A delayed "stopped" event can belong to the previous capture of this tab.
  withSession(async(s,job)=>{if(s?.sourceTabId===info.tabId)await validSession(job);}).catch(()=>{});
});
chrome.commands.onCommand.addListener(async command=>{if(command!=='toggle-ambient')return;const {enabled=true}=await chrome.storage.local.get('enabled');await chrome.storage.local.set({enabled:!enabled});});
chrome.runtime.onInstalled.addListener(details=>queueSessionTask(async job=>{
  if(details.reason==='update'){
    await stopSession(true,job);
    try{await job.wait(sendOffscreen('AW_OFFSCREEN_STOP'));}catch{job.check();}
  }
  const current=await job.wait(chrome.storage.local.get(null));const patch={};
  for(const [key,val] of Object.entries(SETTINGS_DEFAULTS))if(current[key]===undefined)patch[key]=val;
  if(current.sitesEnabled)patch.sitesEnabled={...SITES_DEFAULT,...current.sitesEnabled};
  if(Object.keys(patch).length)await chrome.storage.local.set(patch);
}).catch(()=>{}));

// Settings are applied to the live offscreen capture without forcing reconnection.
chrome.storage.onChanged.addListener((changes,area)=>{
  if(area==='local'){
    const publicChanges=Object.fromEntries(PUBLIC_SETTING_KEYS.filter(key=>changes[key]).map(key=>[key,{newValue:changes[key].newValue??SETTINGS_DEFAULTS[key]}]));
    if(Object.keys(publicChanges).length){
      const revision=++publicSettingsRevision;
      chrome.tabs.query({url:[...WORKSPACE_URLS,'https://www.youtube.com/*','https://youtube.com/*']}).then(tabs=>{
        for(const tab of tabs)chrome.tabs.sendMessage(tab.id,{type:'AW_RENDERER_SETTINGS_CHANGED',changes:publicChanges,workerId:wbWorker,revision},{frameId:0}).catch(()=>{});
      }).catch(()=>{});
    }
  }
  if(area==='local'&&changes[DESKTOP_TOKEN_KEY]){dcReset();dcQuery().catch(()=>{});}
  if(area!=='local'||(!changes.sourceMode&&!changes.performanceMode&&!changes.fps&&!changes.desktopEnabled&&!changes.desktopVideoEnabled&&!changes[DESKTOP_TOKEN_KEY]&&!changes.youtubeAmbientEnabled&&!changes.youtubeAmbientFps&&!changes.youtubeAmbientStrength&&!changes.youtubeAmbientBlur&&!changes.youtubeAmbientSpread))return;
  withSession(async(session,job)=>{
    if(!session)return;
    const params={sessionId:session.sessionId};
    if(changes.sourceMode)params.sourceMode=changes.sourceMode.newValue;
    if(changes.performanceMode)params.performanceMode=changes.performanceMode.newValue;
    if(changes.fps)params.fps=changes.fps.newValue;
    if(changes.sourceMode||changes.performanceMode||changes.fps)await job.wait(sendOffscreen('AW_OFFSCREEN_CONFIGURE',params));
    if(changes.youtubeAmbientEnabled||changes.youtubeAmbientFps){
      const {youtubeAmbientEnabled=true,youtubeAmbientFps=2}=await job.wait(chrome.storage.local.get(['youtubeAmbientEnabled','youtubeAmbientFps']));
      await job.wait(sendOffscreen('AW_OFFSCREEN_YOUTUBE_CONFIG',{sessionId:session.sessionId,enabled:youtubeAmbientEnabled,fps:youtubeAmbientFps}));
      await chrome.tabs.sendMessage(session.sourceTabId,{type:youtubeAmbientEnabled?'AW_YT_AMBIENT_START':'AW_YT_AMBIENT_STOP',sessionId:session.sessionId}).catch(()=>{});
    }
    if(changes.desktopEnabled||changes.desktopVideoEnabled||changes[DESKTOP_TOKEN_KEY]){
      const {desktopEnabled=false,desktopVideoEnabled=false,[DESKTOP_TOKEN_KEY]:token=''}=await job.wait(chrome.storage.local.get(['desktopEnabled','desktopVideoEnabled',DESKTOP_TOKEN_KEY]));
      await sendOffscreen('AW_OFFSCREEN_DESKTOP_CONFIG',{sessionId:session.sessionId,enabled:desktopEnabled&&TOKEN_RE.test(token),token:desktopEnabled?token:'',videoEnabled:desktopVideoEnabled});
    }
  }).catch(()=>{});
});
