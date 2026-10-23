// Explicit, trusted-context profile transfer. Backup contents never reach renderers.
(() => {
  let busy=false;
  const clone=value=>JSON.parse(JSON.stringify(value));
  function validData(value){
    return !!value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).length>0&&
      new TextEncoder().encode(JSON.stringify(value)).length<=262144;
  }
  async function transfer(type,{backupId,confirmed=false}={},hooks){
    if(busy)throw Error('profileBusy');
    if(!['list','export','import'].includes(type))throw Error('profileInvalid');
    busy=true;
    try{
      if(type==='list')return await AW_NATIVE.request({type:'native.profile.list'},{timeoutMs:5000});
      if(await hooks.captureActive())throw Error('profileStopCapture');
      if(type==='import'&&(!confirmed||!/^[a-f0-9]{32}$/.test(backupId||'')))throw Error('profileConfirmationRequired');
      await hooks.idle();
      const before=clone(await chrome.storage.local.get(null));
      // A verified durable backup is mandatory before any local storage write.
      const saved=await AW_NATIVE.request({type:'native.profile.export',data:before},{timeoutMs:5000});
      if(saved?.ok!==true||!/^[a-f0-9]{32}$/.test(saved.backupId||''))throw Error('profileBackupFailed');
      if(type==='export')return {ok:true,backupId:saved.backupId,fieldCount:Object.keys(before).length};
      const restored=await AW_NATIVE.request({type:'native.profile.read',backupId},{timeoutMs:5000});
      if(restored?.ok!==true||restored.backupId!==backupId||!validData(restored.data))throw Error('profileInvalid');
      const patch=clone(restored.data),keys=Object.keys(patch);
      try{
        await chrome.storage.local.set(patch);
        const actual=await chrome.storage.local.get(keys);
        if(keys.some(key=>JSON.stringify(actual[key])!==JSON.stringify(patch[key])))throw Error('profileWriteUnconfirmed');
        await hooks.reset();
      }catch{
        try{
          const previous=Object.fromEntries(keys.filter(key=>Object.hasOwn(before,key)).map(key=>[key,before[key]]));
          const added=keys.filter(key=>!Object.hasOwn(before,key));
          if(Object.keys(previous).length)await chrome.storage.local.set(previous);
          if(added.length)await chrome.storage.local.remove(added);
          const actual=await chrome.storage.local.get(null);
          if(keys.some(key=>Object.hasOwn(before,key)!==Object.hasOwn(actual,key)||JSON.stringify(before[key])!==JSON.stringify(actual[key])))throw Error('rollback');
          await hooks.reset();
        }catch{throw Error('profileRecoveryRequired');}
        throw Error('profileImportFailedRestored');
      }
      return {ok:true,backupId,previousBackupId:saved.backupId,fieldCount:keys.length};
    }finally{busy=false;}
  }
  globalThis.AW_PROFILES=Object.freeze({transfer,isBusy:()=>busy});
})();
