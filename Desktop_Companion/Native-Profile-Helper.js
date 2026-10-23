// This trusted helper runs only in a newly copied, private Chrome profile.
let active=false,status='waiting';
async function backupCopy(){
  if(active)return;active=true;status='saving';
  let port,timer;
  const finish=next=>{clearTimeout(timer);status=next;active=false;try{port?.disconnect();}catch{}};
  try{
    await chrome.storage.local.setAccessLevel({accessLevel:'TRUSTED_CONTEXTS'});
    const data=await chrome.storage.local.get(null);
    if(!Object.keys(data).length){finish('empty');return;}
    port=chrome.runtime.connectNative('__HOST__');
    const id=crypto.randomUUID().replaceAll('-','');
    port.onMessage.addListener(reply=>{
      if(reply.id===id)finish(reply.transport==='ok'&&reply.result?.ok===true?'saved':'failed');
    });
    port.onDisconnect.addListener(()=>{void chrome.runtime.lastError;if(active)finish('failed');});
    timer=setTimeout(()=>finish('failed'),10000);
    port.postMessage({id,packet:{type:'native.profile.export',data}});
  }catch{finish('failed');}
}
chrome.runtime.onInstalled.addListener(()=>{backupCopy();chrome.tabs.create({url:chrome.runtime.getURL('helper.html')}).catch(()=>{});});
chrome.runtime.onStartup.addListener(backupCopy);
chrome.runtime.onMessage.addListener((message,sender,reply)=>{
  if(sender.id!==chrome.runtime.id||sender.url!==chrome.runtime.getURL('helper.html'))return;
  if(message?.type==='retry')backupCopy();
  reply({status});
});
