// Loaded by the trusted worker only. Chrome launches the registered private host.
// No TCP/HTTP transport or fallback. Aborting a port invalidates all queued work.
(() => {
  const host='org.ambientworkspace.bridge',pending=new Map();
  let port=null;
  function connectionError(message='') {
    if(/specified native messaging host not found/i.test(message))return 'hostNotRegistered';
    if(/access to the specified native messaging host is forbidden/i.test(message))return 'hostForbidden';
    if(/failed to start native messaging host/i.test(message))return 'hostStartFailed';
    return 'nativeUnavailable';
  }
  function disconnect(reason='nativeDisconnected') {
    const previous=port;port=null;
    for(const job of pending.values()){job.cleanup();job.reject(Error(reason));}
    pending.clear();try{previous?.disconnect();}catch{}
  }
  function connect() {
    if(port)return port;
    let connection;try{connection=chrome.runtime.connectNative(host);}catch{throw Error('nativeUnavailable');}
    port=connection;
    connection.onMessage.addListener(reply=>{
      if(connection!==port)return;
      if(!reply||typeof reply!=='object'||Array.isArray(reply)||typeof reply.id!=='string'){disconnect('invalidNativeResponse');return;}
      const job=pending.get(reply.id);if(!job){disconnect('invalidNativeResponse');return;}
      pending.delete(reply.id);job.cleanup();
      if(reply.transport==='ok'&&reply.result&&typeof reply.result==='object'&&!Array.isArray(reply.result))job.resolve(reply.result);
      else job.reject(Error(['pairingRequired','pairingRejected','bridgeUnavailable','timeout','invalid','busy'].includes(reply.transport)?reply.transport:'invalidNativeResponse'));
    });
    connection.onDisconnect.addListener(()=>{const reason=connectionError(chrome.runtime.lastError?.message);if(connection===port)disconnect(reason);});
    return connection;
  }
  function exchange(packet,{signal,timeoutMs=1800}={}) {
    return new Promise((resolve,reject)=>{
      if(signal?.aborted){reject(Error('aborted'));return;}
      if(!packet||typeof packet!=='object'||Array.isArray(packet)){reject(Error('invalid'));return;}
      if(pending.size>=8){reject(Error('busy'));return;}
      const id=crypto.randomUUID().replaceAll('-',''),message={id,packet};
      try{if(new TextEncoder().encode(JSON.stringify(message)).length>524288){reject(Error('invalid'));return;}}catch{reject(Error('invalid'));return;}
      let connection;try{connection=connect();}catch{reject(Error('nativeUnavailable'));return;}
      const abort=()=>{if(pending.has(id))disconnect('aborted');};
      const timer=setTimeout(()=>{if(pending.has(id))disconnect('timeout');},timeoutMs);
      const cleanup=()=>{clearTimeout(timer);signal?.removeEventListener('abort',abort);};
      pending.set(id,{resolve,reject,cleanup});signal?.addEventListener('abort',abort,{once:true});
      if(signal?.aborted){abort();return;}
      try{connection.postMessage(message);}catch{disconnect('nativeUnavailable');}
    });
  }
  async function request(packet,options={}) {
    try{return await exchange(packet,options);}catch(error){
      // A live port still points at the installation Chrome originally launched.
      // Reopen only idempotent reads once. Never replay commands or media.
      if(error.message!=='bridgeUnavailable'||options.signal?.aborted||
        !['native.status','ping','control.hello','control.query'].includes(packet?.type))throw error;
      disconnect('connectionChanged');
      return exchange(packet,options);
    }
  }
  globalThis.AW_NATIVE=Object.freeze({host,request,disconnect});
})();
