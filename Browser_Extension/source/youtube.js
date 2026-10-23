(() => {
  if (globalThis.__ambientWorkspaceYoutubeLoaded) return;
  globalThis.__ambientWorkspaceYoutubeLoaded = true;

  // Original approach: video-image projection through rescaled 2D canvases and
  // a gradual shadow. Adapted in 2026 for Ambient Workspace's shared tab capture.
  // Inspiration: Wessel Kroos, youtube-ambilight, Projector2d/ProjectorShadow
  // (MIT; see THIRD_PARTY_NOTICES.md and licenses/youtube-ambilight-MIT.txt).
  const DEFAULTS={youtubeAmbientEnabled:true,youtubeAmbientStrength:84,
    youtubeAmbientSpread:440,youtubeAmbientBlur:118};
  let opts={...DEFAULTS},settingsReady=false,session=null,frameAt=0,frameNumber=0;
  let root=null,layers=[],host=null,decodeBusy=false,pendingFrame=null;
  let lastImage=null,rendererEpoch=0,decodeTask=null,decodingImage=null;
  const clamp=(v,a,b)=>Math.max(a,Math.min(b,Number(v)||0));
  const listen=chrome.runtime.onMessage.addListener.bind(chrome.runtime.onMessage);
  // Same Desktop authority/checkpoint and worker generation as the web renderer.
  const rendererId=crypto.randomUUID().replaceAll('-',''),retiredWorkers=new Set();
  const RENDERER_VERSION='2c2-root-2',ROOT_ID='aw-youtube-ambient';
  const ownedRoots=()=>[...document.querySelectorAll(`#${ROOT_ID}`)].filter(node=>
    !node.getAttribute('data-aw-extension')||node.getAttribute('data-aw-extension')===chrome.runtime.id);
  // Extension reload creates a new isolated world but leaves its old page DOM.
  // Discard legacy/unowned projectors before acknowledging this renderer's gate.
  for(const node of ownedRoots()){
    node.style.display='none';
    for(const canvas of node.querySelectorAll('canvas')){canvas.width=1;canvas.height=1;}
    node.remove();
  }
  let controlReady=false,controlPaused=false,controlWorker=null,controlGeneration=-1;
  let controlQuerying=false,controlAgain=false,controlSequence=0,controlFailures=0,nextControlAt=0,pageActive=true;
  function controlAck(){
    const roots=ownedRoots(),gateOpen=active(),hidden=roots.every(node=>getComputedStyle(node).display==='none');
    if(root?.isConnected)for(const [key,value] of Object.entries({paused:controlPaused,ready:controlReady,gate:gateOpen,worker:controlWorker,generation:controlGeneration}))
      root.setAttribute(`data-aw-${key}`,String(value));
    return {ok:controlReady&&roots.length<=1&&(!controlPaused||!gateOpen&&hidden),rendererId,rendererVersion:RENDERER_VERSION,workerId:controlWorker,generation:controlGeneration,paused:controlPaused,
      enabled:!!opts.youtubeAmbientEnabled,connected:!!session,gateOpen,rootCount:roots.length,hidden,appliedAt:Date.now()};
  }
  function applyControl(web,fromQuery=false){
    if(!web?.ready||!/^[a-f0-9]{32}$/.test(web.workerId||'')||!Number.isSafeInteger(web.generation)||web.generation<0||
      typeof web.paused!=='boolean'||typeof web.fresh!=='boolean'||retiredWorkers.has(web.workerId)||
      web.workerId===controlWorker&&web.generation<controlGeneration)return false;
    // An unfamiliar worker push cannot retire the current authority. Verify the
    // switch through a new runtime query; invalidate queries started before it.
    if(controlWorker&&controlWorker!==web.workerId&&!fromQuery){
      controlSequence++;controlReady=false;controlPaused=controlPaused||web.paused;
      releaseRenderer();void syncControl(true);return false;
    }
    if(controlWorker&&controlWorker!==web.workerId)retiredWorkers.add(controlWorker);
    const paused=web.paused||controlPaused&&!web.fresh;
    if(controlWorker!==web.workerId||controlGeneration!==web.generation||controlPaused!==paused)releaseRenderer();
    controlWorker=web.workerId;controlGeneration=web.generation;controlPaused=paused;controlReady=true;
    render();return true;
  }
  async function syncControl(force=false){
    if(!pageActive)return;
    if(controlQuerying){if(force)controlAgain=true;return;}
    if(!force&&(!opts.youtubeAmbientEnabled||Date.now()<nextControlAt))return;
    controlQuerying=true;const sequence=++controlSequence,requestWorker=controlWorker;let deadline;
    try{
      const reply=await Promise.race([chrome.runtime.sendMessage({type:'AW_YT_CONTROL_SYNC',rendererId}),
        new Promise((_,reject)=>{deadline=setTimeout(()=>reject(Error('controlTimeout')),3000);})]);
      if(sequence!==controlSequence||!pageActive)return;
      if(requestWorker!==controlWorker&&reply?.web?.workerId!==controlWorker)throw Error('workerChanged');
      if(!reply?.ok)throw Error('controlUnavailable');
      if(reply.publicSettings)settingsChanged(reply.publicSettings);
      if(!applyControl(reply.web,true))throw Error('controlUnavailable');
      controlFailures=reply.web.fresh?0:Math.min(controlFailures+1,4);
      await chrome.runtime.sendMessage({type:'AW_YT_CONTROL_ACK',...controlAck()});
    }catch{controlFailures=Math.min(controlFailures+1,4);/* A transport error never resumes a confirmed pause. */}
    finally{
      clearTimeout(deadline);controlQuerying=false;
      nextControlAt=Date.now()+Math.min(10000,1000*2**controlFailures);
      if(controlAgain&&pageActive){controlAgain=false;void syncControl(true);}
    }
  }
  function refreshControl(){controlReady=false;releaseRenderer();void syncControl(true);}

  function findVideo(){return document.querySelector('#movie_player video.html5-main-video')
    ||document.querySelector('video.html5-main-video')||document.querySelector('video');}
  function geometry(){
    const r=findVideo()?.getBoundingClientRect();
    if(!r||r.width<180||r.height<100||r.right<0||r.left>innerWidth||r.top>innerHeight||r.bottom<0)return null;
    return {left:r.left,top:r.top,width:r.width,height:r.height,right:r.right,bottom:r.bottom};
  }
  // The shared capture engine expects normalized source-video geometry.
  function videoRect(){
    const r=geometry();if(!r||innerWidth<100||innerHeight<100)return null;
    const x=clamp(r.left,0,innerWidth),y=clamp(r.top,0,innerHeight);
    const right=clamp(r.right,0,innerWidth),bottom=clamp(r.bottom,0,innerHeight);
    if(right-x<80||bottom-y<80)return null;
    return {x:x/innerWidth,y:y/innerHeight,w:(right-x)/innerWidth,h:(bottom-y)/innerHeight};
  }
  function active(){return !!(settingsReady && controlReady && !controlPaused && pageActive && session && opts.youtubeAmbientEnabled && document.visibilityState==='visible'
    && location.pathname==='/watch' && !document.fullscreenElement);}

  function makeLayer(){
    const c=document.createElement('canvas');
    Object.assign(c.style,{position:'fixed',left:'0',top:'0',width:'100vw',height:'100vh',
      pointerEvents:'none',display:'block',transform:'translateZ(0)'});
    return c;
  }
  function setup(){
    if(root?.isConnected)return;
    // Place the projector BEHIND the YouTube columns rather than tinting
    // recommendation titles and buttons on top of them (v0.7.1 regression).
    host=document.querySelector('ytd-watch-flexy #columns')||document.querySelector('#columns');
    root=document.createElement('div');root.id=ROOT_ID;
    root.setAttribute('data-aw-extension',chrome.runtime.id);
    root.setAttribute('data-aw-renderer',rendererId);
    root.setAttribute('data-aw-version',RENDERER_VERSION);
    Object.assign(root.style,{position:'fixed',inset:'0',pointerEvents:'none',
      zIndex:host?'0':'1999',display:'none',overflow:'hidden',isolation:'isolate'});
    root.setAttribute('aria-hidden','true');
    layers=[makeLayer(),makeLayer()];root.append(...layers);
    if(host){
      // Keep the interaction layer above the projected glow. We avoid any
      // changes to the player's own styles and restore only our decorations.
      host.style.position=host.style.position||'relative';
      host.style.isolation='isolate';
      for(const selector of ['#primary','#secondary']){
        const child=host.querySelector(selector);
        if(child){child.style.position='relative';child.style.zIndex='1';}
      }
      host.prepend(root);
    } else {
      document.documentElement.append(root);
    }
  }
  function hidden(){if(root)root.style.display='none';}
  function clearLayers(){for(const c of layers){c.width=1;c.height=1;}}
  // Ported geometric idea from the upstream 2D projector: the same frame is
  // projected into increasingly expanded planes. Unlike a flat RGB wash,
  // strips of real edge pixels are extended into the surrounding space.
  function drawProjection(ctx,img,r,spread){
    const iw=img.naturalWidth||img.width,ih=img.naturalHeight||img.height;
    if(!iw||!ih)return;
    const x=r.left,y=r.top,w=r.width,h=r.height,s=spread;
    const edgeX=Math.max(2,Math.round(iw*.065)),edgeY=Math.max(2,Math.round(ih*.075));
    // Soft large-scale image echo: context from actual video is retained.
    ctx.globalAlpha=.38;
    ctx.drawImage(img,0,0,iw,ih,x-s,y-s,w+s*2,h+s*2);
    ctx.globalAlpha=1;
    // Edge projection: the last 6.5% / 7.5% of each video edge is stretched.
    // These are genuine video pixels rather than average color blocks.
    ctx.drawImage(img,0,0,edgeX,ih,x-s,y,s,h);
    ctx.drawImage(img,iw-edgeX,0,edgeX,ih,x+w,y,s,h);
    ctx.drawImage(img,0,0,iw,edgeY,x,y-s,w,s);
    ctx.drawImage(img,0,ih-edgeY,iw,edgeY,x,y+h,w,s);
    // Real image corners eliminate empty triangles where strips meet.
    ctx.drawImage(img,0,0,edgeX,edgeY,x-s,y-s,s,s);
    ctx.drawImage(img,iw-edgeX,0,edgeX,edgeY,x+w,y-s,s,s);
    ctx.drawImage(img,0,ih-edgeY,edgeX,edgeY,x-s,y+h,s,s);
    ctx.drawImage(img,iw-edgeX,ih-edgeY,edgeX,edgeY,x+w,y+h,s,s);
    ctx.clearRect(x-1,y-1,w+2,h+2);
  }
  function updateCanvas(c,img,r,spread,blur,opacity,near){
    // Keep backing surfaces bounded. Pixels are enlarged by CSS, but the
    // actual video is already downsampled by the shared capture pipeline.
    const scale=Math.min(1,1100/innerWidth,680/innerHeight);
    const W=Math.max(1,Math.round(innerWidth*scale));
    const H=Math.max(1,Math.round(innerHeight*scale));
    if(c.width!==W||c.height!==H){c.width=W;c.height=H;}
    const ctx=c.getContext('2d',{alpha:true});if(!ctx)return;
    ctx.setTransform(scale,0,0,scale,0,0);
    ctx.clearRect(0,0,innerWidth,innerHeight);
    drawProjection(ctx,img,r,spread);
    c.style.filter=`blur(${blur}px) saturate(${near?145:132}%) brightness(${near?1.08:1.02})`;
    c.style.opacity=String(opacity);
    // The far glow fades out at the window edge, while near edge pixels stay
    // strong around the player. No artificial radial attenuation at the center.
    const fade=near?'88%':'68%';
    const mx=clamp(r.left+r.width/2,0,innerWidth),my=clamp(r.top+r.height/2,0,innerHeight);
    const gradient=`radial-gradient(ellipse 80% 86% at ${mx}px ${my}px, black 35%, black ${fade}, transparent 100%)`;
    c.style.maskImage=gradient;c.style.webkitMaskImage=gradient;
  }
  function render(){
    if(!active()||!lastImage){hidden();return;}
    const r=geometry();if(!r){hidden();return;}
    const strength=clamp(opts.youtubeAmbientStrength,0,100)/100;
    if(!strength){hidden();return;}
    setup();
    const spread=clamp(opts.youtubeAmbientSpread,40,600),blur=clamp(opts.youtubeAmbientBlur,12,180);
    // A near crisp-ish extension and one larger soft projector. Old approach
    // laid a translucent sheet over the playlist; the host layer avoids that.
    updateCanvas(layers[0],lastImage,r,spread*1.2,Math.round(blur*.75),Math.min(.95,strength*.86),false);
    updateCanvas(layers[1],lastImage,r,spread*.70,Math.round(blur*.26),Math.min(1,strength*.96),true);
    if(!host){ // Safe fallback for unexpected YouTube DOM: never wash the playlist.
      const l=clamp(r.left,0,innerWidth),t=clamp(r.top,0,innerHeight);
      const right=clamp(r.right,0,innerWidth),bot=clamp(r.bottom,0,innerHeight);
      const hole=`polygon(evenodd,0px 0px,${innerWidth}px 0px,${innerWidth}px ${innerHeight}px,0px ${innerHeight}px,0px 0px,${l}px ${t}px,${l}px ${bot}px,${right}px ${bot}px,${right}px ${t}px,${l}px ${t}px)`;
      root.style.clipPath=hole;
    }
    root.style.display='block';
  }
  function queueFrame(data){
    if(!active()){hidden();return;}
    pendingFrame=data;
    if(decodeBusy)return;
    const task={epoch:rendererEpoch};
    decodeTask=task;decodeBusy=true;
    const run=async()=>{
      try{while(pendingFrame&&active()&&decodeTask===task){
        const value=pendingFrame;pendingFrame=null;
        const img=new Image();decodingImage=img;img.src=value;
        try{if(typeof img.decode==='function')await img.decode();else await new Promise((ok,fail)=>{img.onload=ok;img.onerror=fail;});}
        catch{img.removeAttribute?.('src');continue;}
        finally{img.onload=null;img.onerror=null;}
        if(task.epoch!==rendererEpoch||!active()){img.removeAttribute?.('src');break;}
        lastImage?.removeAttribute?.('src');
        lastImage=img;frameAt=Date.now();frameNumber++;
        try{render();}catch{hidden();}
      }}finally{
        if(decodeTask===task){decodeTask=null;decodingImage=null;decodeBusy=false;}
      }
    };
    void run();
  }
  function releaseRenderer(){
    rendererEpoch++;pendingFrame=null;decodeTask=null;decodeBusy=false;
    if(decodingImage){decodingImage.onload=null;decodingImage.onerror=null;decodingImage.removeAttribute?.('src');decodingImage=null;}
    lastImage?.removeAttribute?.('src');lastImage=null;hidden();clearLayers();
  }
  function stop(id){
    if(id&&id!==session)return;
    session=null;releaseRenderer();
  }
  function visibility(){refreshControl();chrome.runtime.sendMessage({type:'AW_YT_VISIBILITY',visible:document.visibilityState==='visible'&&!document.fullscreenElement&&location.pathname==='/watch'}).catch(()=>{});render();}
  // Never flash the default ON state before the saved preference is available.
  const initialChanges={};
  chrome.runtime.sendMessage({type:'AW_RENDERER_SETTINGS_GET'}).then(reply=>{if(!reply?.ok)throw Error('settingsUnavailable');if(!settingsReady&&(!settingsWorker||settingsWorker===reply.workerId)){opts={...DEFAULTS,...reply.settings,...initialChanges};settingsReady=true;if(settingsWorker===null||settingsWorker===reply.workerId){settingsWorker=reply.workerId;settingsRevision=Math.max(settingsRevision,reply.revision);}}else if(settingsWorker===reply.workerId)settingsChanged(reply);render();void syncControl(true);}).catch(()=>{});
  let settingsWorker=null,settingsRevision=-1;const retiredSettingsWorkers=new Set();
  function applySettingsChanges(changes){let changed=false;
    for(const key of Object.keys(DEFAULTS))if(changes[key]){
      opts[key]=changes[key].newValue??DEFAULTS[key];
      if(!settingsReady)initialChanges[key]=opts[key];
      changed=true;
    }
    // Do not wait for the background's queued OFF RPC: hide and invalidate
    // pending image work immediately, while leaving the shared capture alone.
    if(changed){if(!opts.youtubeAmbientEnabled)releaseRenderer();else render();void syncControl(true);}
  }
  const fromWorker=sender=>sender.id===chrome.runtime.id&&!sender.tab&&sender.url===`chrome-extension://${chrome.runtime.id}/source/background.js`;
  function settingsChanged(message){
    if(typeof message.workerId!=='string'||!Number.isSafeInteger(message.revision)||retiredSettingsWorkers.has(message.workerId))return;
    if(settingsWorker===message.workerId&&(message.revision<settingsRevision||message.revision===settingsRevision&&(!message.settings||settingsReady)))return;
    if(settingsWorker&&settingsWorker!==message.workerId){retiredSettingsWorkers.add(settingsWorker);if(retiredSettingsWorkers.size>16)retiredSettingsWorkers.delete(retiredSettingsWorkers.values().next().value);}
    settingsWorker=message.workerId;settingsRevision=message.revision;
    if(message.settings){message={...message,changes:Object.fromEntries(Object.keys(DEFAULTS).filter(key=>(message.settings[key]??DEFAULTS[key])!==opts[key]).map(key=>[key,{newValue:message.settings[key]??DEFAULTS[key]}]))};settingsReady=true;}
    applySettingsChanges(message.changes||{});
  }
  listen((message,_sender,respond)=>{
    if(!fromWorker(_sender)){respond({ok:false});return;}
    if(message?.type==='AW_RENDERER_SETTINGS_CHANGED'){settingsChanged(message);respond({ok:true});return;}
    if(message?.type==='AW_YT_CONTROL_APPLY'){
      if(_sender.id!==chrome.runtime.id||!pageActive){respond({ok:false});return;}
      applyControl(message.web);respond(controlAck());return;
    }
    if(message?.type==='AW_YT_AMBIENT_START'){
      stop();session=message.sessionId;void syncControl(true);respond({ok:true});return;
    }
    if(message?.type==='AW_YT_AMBIENT_STOP'){stop(message.sessionId);respond({ok:true});return;}
    if(message?.type==='AW_YT_AMBIENT_FRAME'){
      if(message.sessionId===session&&typeof message.frame==='string'&&message.frame.startsWith('data:image/'))queueFrame(message.frame);
      respond({ok:true});return;
    }
    if(message?.type==='AW_YT_AMBIENT_STATUS'){
      respond({ok:true,connected:!!session,visible:root?.style.display==='block',lastFrameAt:frameAt,frames:frameNumber,control:controlAck()});return;
    }
  });
  window.addEventListener('resize',render,{passive:true});
  document.addEventListener('fullscreenchange',visibility);
  document.addEventListener('yt-navigate-finish',visibility);
  document.addEventListener('visibilitychange',visibility);
  chrome.runtime.sendMessage({type:'AW_YT_VISIBILITY',visible:document.visibilityState==='visible'&&!document.fullscreenElement&&location.pathname==='/watch'}).catch(()=>{});
  let last='',debounce=null,sourceNavigating=false;
  function broadcast(force=false){const value=JSON.stringify(videoRect());if(value===last&&!force)return;last=value;chrome.runtime.sendMessage({type:'AW_SOURCE_RECT_CHANGED',crop:videoRect()}).catch(()=>{});}
  function queueRect(){if(debounce!==null)clearTimeout(debounce);debounce=setTimeout(()=>{debounce=null;broadcast();render();},220);}
  listen((message,_sender,respond)=>{if(!fromWorker(_sender))return;if(message?.type==='AW_VIDEO_RECT'){const crop=pageActive&&!sourceNavigating&&findVideo()?.readyState>=2?videoRect():null;last=JSON.stringify(crop);respond(crop);}});
  window.addEventListener('resize',queueRect,{passive:true});
  window.addEventListener('fullscreenchange',queueRect);
  document.addEventListener('yt-navigate-start',()=>{sourceNavigating=true;chrome.runtime.sendMessage({type:'AW_SOURCE_SUSPEND'}).catch(()=>{});});
  document.addEventListener('yt-navigate-finish',()=>{sourceNavigating=false;last='';queueRect();});
  document.addEventListener('visibilitychange',queueRect);
  // Reuse the existing geometry tick (including hidden YouTube tabs). No new
  // repeating timer/offscreen; worker coalesces this with existing web/popup reads.
  setInterval(()=>{broadcast();void syncControl();},1100);queueRect();
  window.addEventListener('pageshow',()=>{pageActive=true;refreshControl();});
  window.addEventListener('pagehide',()=>{chrome.runtime.sendMessage({type:'AW_SOURCE_SUSPEND'}).catch(()=>{});pageActive=false;controlReady=false;controlSequence++;releaseRenderer();});
})();
