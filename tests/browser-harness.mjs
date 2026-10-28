// Real extension scripts in isolated VM contexts; synthetic storage/ports/tabs only.
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
export const source=name=>readFileSync(new URL('../Browser_Extension/source/'+name,import.meta.url),'utf8');
export const copy=value=>value===undefined?undefined:JSON.parse(JSON.stringify(value));
export function event(){const listeners=[];return {listeners,addListener(fn){listeners.push(fn);},removeListener(fn){const i=listeners.indexOf(fn);if(i>=0)listeners.splice(i,1);},emit(...args){for(const fn of [...listeners])fn(...args);}};}
export const globals={URL,TextEncoder,AbortController,crypto:{randomUUID},setTimeout,clearTimeout,performance,console};
export async function worker({local={},session={},tabs=[],native,sendTab,sendOffscreen}={}){
  const localData=copy(local),sessionData=copy(session),changed=event(),messages=[],requests=[],disconnects=[];
  let failSave=false;
  function storage(data,area){return {
    async setAccessLevel(){},
    async get(keys){
      if(keys===null)return copy(data);
      if(typeof keys==='string')keys=[keys];
      if(Array.isArray(keys))return Object.fromEntries(keys.filter(k=>k in data).map(k=>[k,copy(data[k])]));
      return {...copy(keys),...Object.fromEntries(Object.keys(keys).filter(k=>k in data).map(k=>[k,copy(data[k])]))};
    },
    async set(patch){if(failSave&&area==='local')throw Error('synthetic storage failure');const changes={};
      for(const [k,v] of Object.entries(patch)){if(JSON.stringify(data[k])!==JSON.stringify(v)){changes[k]={oldValue:copy(data[k]),newValue:copy(v)};data[k]=copy(v);}}
      if(Object.keys(changes).length)changed.emit(changes,area);
    },
    async remove(keys){if(typeof keys==='string')keys=[keys];const changes={};for(const k of keys)if(k in data){changes[k]={oldValue:copy(data[k])};delete data[k];}if(Object.keys(changes).length)changed.emit(changes,area);}
  };}
  const chrome={
    runtime:{id:'ncbcjbbidoaallpikijfbjdmijjljhoe',getURL:path=>'chrome-extension://ncbcjbbidoaallpikijfbjdmijjljhoe/'+path,onMessage:event(),onInstalled:event(),
      async getContexts(){return [{contextType:'OFFSCREEN_DOCUMENT'}];},
      async sendMessage(msg){messages.push(copy(msg));return sendOffscreen?sendOffscreen(msg):{ok:true};}},
    storage:{local:storage(localData,'local'),session:storage(sessionData,'session'),onChanged:changed},
    tabs:{onRemoved:event(),onUpdated:event(),onActivated:event(),async query(query){return query.active?tabs.filter(t=>t.active):tabs;},async get(id){const tab=tabs.find(t=>t.id===id);if(!tab)throw Error('missing tab');return tab;},async sendMessage(id,msg){messages.push({tabId:id,...copy(msg)});
      if(sendTab)return sendTab(id,msg);
      if(msg.type==='AW_WEB_CONTROL_APPLY'||msg.type==='AW_YT_CONTROL_APPLY')return {ok:true,rendererId:id.toString(16).padStart(32,'0'),...msg.web,hidden:msg.web.paused,enabled:true,mode:'demo',appliedAt:Date.now(),rendererVersion:'2c2-root-2',gateOpen:!msg.web.paused,rootCount:1,connected:true};
      if(msg.type==='AW_VIDEO_RECT')return {x:.1,y:.1,w:.7,h:.7};return {ok:true};}},
    scripting:{async executeScript({target}){return [{frameId:0,documentId:'document-'+target.tabId,result:tabs.find(t=>t.id===target.tabId)?.url}];}},
    tabCapture:{onStatusChanged:event(),async getMediaStreamId(){return 'synthetic-stream';}},
    offscreen:{async createDocument(){},async closeDocument(){}},commands:{onCommand:event()}
  };
  const context=vm.createContext({...globals,chrome});
  context.importScripts=(...names)=>{for(const name of names)vm.runInContext(source(name),context,{filename:name});};
  vm.runInContext(source('background.js'),context,{filename:'background.js'});
  context.AW_NATIVE={disconnect(reason){disconnects.push(reason);},async request(packet){requests.push(copy(packet));if(native)return native(packet);throw Error('hostNotRegistered');}};
  await Promise.resolve();
  const evaluate=code=>vm.runInContext(code,context);
  const popup={id:chrome.runtime.id,url:chrome.runtime.getURL('source/popup.html')};
  async function dispatch(message,sender=popup){return new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>reject(Error('test message timed out: '+message.type)),2500);
    const respond=result=>{clearTimeout(timer);resolve(copy(result));};
    try{const async=chrome.runtime.onMessage.listeners[0](message,sender,respond);if(!async){clearTimeout(timer);resolve(undefined);}}catch(error){clearTimeout(timer);reject(error);}
  });}
  return {context,chrome,local:localData,session:sessionData,messages,requests,disconnects,evaluate,dispatch,popup,tabs,setFailSave(value){failSave=value;}};
}
export function desktopReply(packet,{paused=false,revision=0}={}){
  if(packet.type==='native.status')return {ok:true,transport:'native',bridgeAvailable:true};
  if(packet.type==='ping')return {ok:true};
  if(packet.type==='control.applied')return {ok:true,status:'clientApplied'};
  return {ok:true,protocolVersion:1,profileLeaseSupported:true,capabilities:['desktop-pause-control','integration-status','independent-chrome-pause'],
    state:{instanceId:'d'.repeat(32),revision,globalPaused:paused,persisted:true,desktopOutput:{enabled:true,rgbEnabled:true,videoEnabled:true}},
    lease:{leaseId:'e'.repeat(32),instanceId:'d'.repeat(32),expiresAt:Date.now()+10000}};
}
