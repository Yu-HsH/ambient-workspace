(() => {
  if (globalThis.__ambientWorkspaceLoaded) return;
  globalThis.__ambientWorkspaceLoaded = true;

  const DEFAULTS = {
    enabled: true, mode: 'demo', intensity: 30, blur: 13, dim: 30,
    saturation: 88, protectCenter: true, focusWidth: 70, focusHeight: 115,
    sourceMode: 'video', fps: 5, palette: 'twilight', motion: 'vertical', motionSpeed: 65, performanceMode:'balanced', sitesEnabled:{chatgpt:true,claude:true,gemini:true,notion:true}
  };
  const PALETTES = {
    twilight: ['#5269ce', '#913da2', '#21afa1'],
    forest: ['#296b63', '#438151', '#b9a451'],
    sunset: ['#e1974d', '#c95e7b', '#715bc3'],
    ocean: ['#2064a5', '#26a9be', '#3655a8'],
    aurora: ['#4c8cdd', '#47bb90', '#9e61d4']
  };
  const state = {...DEFAULTS};
  function currentSite() {
    const host = location.hostname;
    if (host === 'chatgpt.com' || host === 'chat.openai.com') return 'chatgpt';
    if (host === 'claude.ai') return 'claude';
    if (host === 'gemini.google.com') return 'gemini';
    if (['notion.so','www.notion.so','notion.com','www.notion.com','app.notion.com','app.notion.so'].includes(host)) return 'notion';
    return null;
  }
  const pageSite = currentSite();
  const PERFORMANCE = {
    eco: {fps:2, width:400, height:225, sampleEvery:2, maxBlur:8},
    balanced: {fps:5, width:560, height:315, sampleEvery:3, maxBlur:24},
    quality: {fps:10, width:960, height:540, sampleEvery:3, maxBlur:40}
  };
  const profile = () => PERFORMANCE[state.performanceMode] || PERFORMANCE.balanced;
  const preferred = () => state.enabled && state.sitesEnabled?.[pageSite] !== false;
  const allowed = () => settingsLoaded && preferred() && webReady && !webPaused;
  let drawStats = {frames:0, totalMs:0};
  const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, Number(x) || 0));
  let root, visual, canvas, ctx, hiddenVideo, demo, glow, sample, sampleCtx;
  let stream = null, sessionId = null, renderTimer = null, crop = null;
  let remoteSessionId = null, remoteBusy = false, remoteImage = null;
  let averagedColors = null, frameNumber = 0;
  const rendererId=crypto.randomUUID().replaceAll('-',''),retiredWorkers=new Set();
  let webReady=false,webPaused=false,webWorker=null,webGeneration=-1,renderGeneration=0;
  let webTimer=null,webQuerying=false,webAgain=false,webSequence=0,webFailures=0,webPageActive=true;
  function invalidateRender(){
    renderGeneration++;cancelDraw();remoteBusy=false;
    if(remoteImage){remoteImage.onload=null;remoteImage.onerror=null;remoteImage.removeAttribute('src');remoteImage=null;}
  }
  function webAck(){return {ok:webReady,rendererId,workerId:webWorker,generation:webGeneration,paused:webPaused,
    enabled:!!preferred(),mode:state.mode,hidden:!root?.isConnected||root.style.display==='none',appliedAt:Date.now()};}
  function applyWebControl(web){
    if(!web?.ready||!/^[a-f0-9]{32}$/.test(web.workerId||'')||!Number.isSafeInteger(web.generation)||web.generation<0||typeof web.paused!=='boolean'||typeof web.fresh!=='boolean')return false;
    if(retiredWorkers.has(web.workerId)||web.workerId===webWorker&&web.generation<webGeneration)return false;
    if(webWorker&&webWorker!==web.workerId)retiredWorkers.add(webWorker);
    // A cached/failed connection can hold pause, but only a fresh Desktop query can resume it.
    const paused=web.paused||webPaused&&!web.fresh;
    if(webWorker!==web.workerId||webGeneration!==web.generation||webPaused!==paused)invalidateRender();
    webWorker=web.workerId;webGeneration=web.generation;webPaused=paused;webReady=true;
    applyVisuals();return true;
  }
  function scheduleWebQuery(){
    if(webTimer!==null){clearTimeout(webTimer);webTimer=null;}
    if(!webPageActive||document.hidden||!preferred())return;
    webTimer=setTimeout(()=>{webTimer=null;return syncWebControl();},Math.min(10000,1000*2**Math.min(webFailures,4)));
  }
  async function syncWebControl(){
    if(webQuerying){webAgain=true;return;}
    if(webTimer!==null){clearTimeout(webTimer);webTimer=null;}
    webQuerying=true;const sequence=++webSequence;let deadline;
    try{
      const response=await Promise.race([chrome.runtime.sendMessage({type:'AW_WEB_CONTROL_SYNC',rendererId}),
        new Promise((_,reject)=>{deadline=setTimeout(()=>reject(Error('webControlTimeout')),3000);})]);
      if(sequence!==webSequence||!webPageActive)return;
      if(!response?.ok||!response.web?.ready)throw Error('webControlUnavailable');
      if(response.publicSettings)settingsChanged(response.publicSettings);
      applyWebControl(response.web);webFailures=response.web.fresh?0:Math.min(webFailures+1,4);
      await chrome.runtime.sendMessage({type:'AW_WEB_CONTROL_ACK',...webAck()});
    }catch{webFailures=Math.min(webFailures+1,4);/* Last confirmed pause survives every transport error. */}
    finally{
      clearTimeout(deadline);webQuerying=false;
      if(webAgain&&webPageActive){webAgain=false;syncWebControl();}else scheduleWebQuery();
    }
  }

  function mount() {
    if (root?.isConnected) return;
    root = document.createElement('div');
    root.id = 'ambient-workspace-root';
    root.setAttribute('aria-hidden', 'true');
    root.style.cssText = 'position:fixed;inset:0;overflow:hidden;z-index:2147483646;pointer-events:none;isolation:isolate;';
    const shadow = root.attachShadow({mode: 'closed'});
    const style = document.createElement('style');
    style.textContent = `
      :host { pointer-events:none!important; }
      .visual {position:absolute;inset:0;overflow:hidden;pointer-events:none;isolation:isolate;transition:opacity .22s ease;}
      .content {position:absolute;inset:0;width:100%;height:100%;object-fit:cover;}
      .demo {position:absolute;inset:-22%;background:
        radial-gradient(ellipse 34% 39% at 17% 37%,var(--aw-a,#5269ce) 0%,transparent 84%),
        radial-gradient(ellipse 37% 44% at 82% 64%,var(--aw-b,#913da2) 0%,transparent 83%),
        radial-gradient(ellipse 30% 42% at 60% 11%,var(--aw-c,#21afa1) 0%,transparent 86%),
        radial-gradient(ellipse 31% 40% at 43% 92%,var(--aw-a,#5269ce) 0%,transparent 85%);
        animation:aw-vertical var(--aw-speed,65s) ease-in-out infinite alternate;will-change:transform;}
      .glow {position:absolute;inset:-7%;background:
        radial-gradient(ellipse 36% 62% at 12% 47%,#5b7899,transparent 100%),
        radial-gradient(ellipse 36% 62% at 89% 53%,#3e776d,transparent 100%);}
      .demo[data-motion=vertical] {animation-name:aw-vertical}
      .demo[data-motion=horizontal] {animation-name:aw-horizontal}
      .demo[data-motion=drift] {animation-name:aw-drift}
      .demo[data-motion=none] {animation:none;will-change:auto}
      @keyframes aw-vertical {from{transform:translate3d(0,-7%,0) scale(1.04)}to{transform:translate3d(0,7%,0) scale(1.11)}}
      @keyframes aw-horizontal {from{transform:translate3d(-7%,0,0) scale(1.04)}to{transform:translate3d(7%,0,0) scale(1.11)}}
      @keyframes aw-drift {from{transform:translate3d(-6%,-5%,0) scale(1.03) rotate(-4deg)}to{transform:translate3d(6%,7%,0) scale(1.10) rotate(4deg)}}
      @media (prefers-reduced-motion:reduce) {.demo {animation:none!important;will-change:auto!important}}
      video {position:absolute;width:2px;height:2px;opacity:0;pointer-events:none;}
    `;
    visual = document.createElement('div'); visual.className = 'visual';
    demo = document.createElement('div'); demo.className = 'demo';
    glow = document.createElement('div'); glow.className = 'glow';
    canvas = document.createElement('canvas'); canvas.className = 'content';
    canvas.width = 640; canvas.height = 360;
    ctx = canvas.getContext('2d', {alpha:false, desynchronized:true});
    sample = document.createElement('canvas'); sample.width = 48; sample.height = 24;
    sampleCtx = sample.getContext('2d', {willReadFrequently:true});
    hiddenVideo = document.createElement('video');
    hiddenVideo.muted = true; hiddenVideo.autoplay = true; hiddenVideo.playsInline = true;
    visual.append(demo, glow, canvas, hiddenVideo);
    shadow.append(style, visual);
    (document.body || document.documentElement).append(root);
    applyVisuals();
  }

  function ovalMask() {
    if (!state.protectCenter) return 'none';
    // Hole in the ambient overlay, not a black ellipse painted above ChatGPT.
    // Width follows the reading area; height protects the bottom composer, too.
    const rx = (clamp(state.focusWidth, 48, 88) / 2).toFixed(1);
    const ry = (clamp(state.focusHeight, 85, 135) / 2).toFixed(1);
    return `radial-gradient(ellipse ${rx}% ${ry}% at 55% 50%,
      transparent 0%,transparent 72%,rgba(0,0,0,.10) 78%,
      rgba(0,0,0,.48) 88%,black 100%)`;
  }

  function applyVisuals() {
    if (!root?.isConnected) return;
    root.style.display = allowed() ? 'block' : 'none';
    demo.style.animationPlayState=allowed()?'running':'paused';
    const perf = profile();
    if (canvas.width !== perf.width || canvas.height !== perf.height) {
      canvas.width = perf.width; canvas.height = perf.height;
    }
    // Without a valid player rectangle, show the chosen palette; do not leak
    // YouTube's sidebar/recommendations as a whole-tab fallback.
    const live = state.mode === 'live' && Boolean(stream || remoteSessionId) && Boolean(crop);
    const isGlow = live && state.sourceMode === 'glow';
    visual.style.opacity = String(isGlow
      ? clamp(.24 + clamp(state.intensity,0,60) * .009, 0, .85)
      : clamp(state.intensity,0,60)/100);
    visual.style.filter = isGlow
      ? `blur(${Math.min(clamp(state.blur,0,40),perf.maxBlur)}px) brightness(${(1.4-clamp(state.dim,0,90)/180).toFixed(2)}) saturate(${clamp(state.saturation,0,150)/100})`
      : `blur(${Math.min(clamp(state.blur,0,40),perf.maxBlur)}px) brightness(${(100-clamp(state.dim,0,90))/100}) saturate(${clamp(state.saturation,0,150)/100})`;
    const mask = ovalMask();
    visual.style.webkitMaskImage = mask;
    visual.style.maskImage = mask;
    const colors = PALETTES[state.palette] || PALETTES.twilight;
    demo.style.setProperty('--aw-a', colors[0]);
    demo.style.setProperty('--aw-b', colors[1]);
    demo.style.setProperty('--aw-c', colors[2]);
    demo.style.setProperty('--aw-speed', `${clamp(state.motionSpeed,30,120)}s`);
    demo.dataset.motion = state.performanceMode === 'eco' ? 'none' : (['vertical','horizontal','drift','none'].includes(state.motion) ? state.motion : 'vertical');
    demo.style.display = live ? 'none' : 'block';
    glow.style.display = isGlow ? 'block' : 'none';
    canvas.style.display = live && !isGlow ? 'block' : 'none';
    if (live && stream && allowed() && !document.hidden) scheduleDraw(); else cancelDraw();
  }

  function cancelDraw() {
    if (renderTimer !== null) { clearTimeout(renderTimer); renderTimer = null; }
  }

  function paintGlow() {
    const {data} = sampleCtx.getImageData(0, 0, sample.width, sample.height);
    const sides = [[0,0,0,0],[0,0,0,0]];
    for (let y=1;y<sample.height-1;y+=2) {
      for (let x=1;x<sample.width-1;x+=2) {
        if (x>=18 && x<=30) continue;
        const side = x<24 ? sides[0] : sides[1];
        const i=(y*sample.width+x)*4;
        side[0]+=data[i];side[1]+=data[i+1];side[2]+=data[i+2];side[3]++;
      }
    }
    const colors=sides.map((side,index)=>{
      const rgb=side.slice(0,3).map(c=>c/Math.max(1,side[3]));
      const luminance=rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722;
      const chroma=Math.max(...rgb)-Math.min(...rgb);
      if (luminance < 22 && chroma < 12) return index === 0 ? [76,92,153] : [51,133,112];
      const boost = Math.max(1, 110/Math.max(22,luminance));
      return rgb.map(c=>Math.round(Math.min(215, c*boost)));
    });
    if (!averagedColors) averagedColors=colors;
    else averagedColors=colors.map((rgb,i)=>rgb.map((c,j)=>Math.round(averagedColors[i][j]*.78+c*.22)));
    const [a,b]=averagedColors;
    glow.style.background = `radial-gradient(ellipse 36% 64% at 12% 48%,rgb(${a.join(',')}),transparent 98%),radial-gradient(ellipse 36% 64% at 88% 52%,rgb(${b.join(',')}),transparent 98%)`;
  }

  function scheduleDraw() {
    if (renderTimer !== null || !stream || !crop || !allowed() || document.hidden || state.mode !== 'live') return;
    function frame() {
      renderTimer = null;
      if (!stream || !crop || !allowed() || document.hidden || state.mode !== 'live') return;
      const started = performance.now();
      if (hiddenVideo.readyState >= 2 && hiddenVideo.videoWidth && hiddenVideo.videoHeight) {
        const W=hiddenVideo.videoWidth,H=hiddenVideo.videoHeight;
        let x=0,y=0,w=W,h=H;
        if (crop) {
          x=clamp(crop.x,0,1)*W; y=clamp(crop.y,0,1)*H;
          w=Math.min(clamp(crop.w,.05,1)*W,W-x);
          h=Math.min(clamp(crop.h,.05,1)*H,H-y);
        }
        try {
          const aspect=canvas.width/canvas.height;
          if (w/h>aspect) {const newW=h*aspect; x+=(w-newW)/2; w=newW;}
          else {const newH=w/aspect; y+=(h-newH)/2; h=newH;}
          if (state.sourceMode === 'glow') {
            if (++frameNumber % profile().sampleEvery === 0) {
              sampleCtx.drawImage(hiddenVideo,x,y,Math.max(1,w),Math.max(1,h),0,0,sample.width,sample.height);
              paintGlow();
            }
          } else {
            ctx.drawImage(hiddenVideo,x,y,Math.max(1,w),Math.max(1,h),0,0,canvas.width,canvas.height);
          }
        } catch { /* Source can resize while changing YouTube display modes. */ }
      }
      drawStats.frames += 1;
      drawStats.totalMs += performance.now() - started;
      renderTimer = setTimeout(frame, 1000/Math.min(profile().fps,clamp(state.fps,5,24)));
    }
    renderTimer = setTimeout(frame, 1000/Math.min(profile().fps,clamp(state.fps,5,24)));
  }

  function stopStream(notify=true, resetMode=true) {
    const oldId=sessionId || remoteSessionId;
    const wasRemote=Boolean(remoteSessionId);
    sessionId=null;remoteSessionId=null;invalidateRender();
    hiddenVideo?.pause();
    if (hiddenVideo) hiddenVideo.srcObject=null;
    if (stream) for (const track of stream.getTracks()) track.stop();
    stream=null;crop=null;averagedColors=null;frameNumber=0;drawStats={frames:0,totalMs:0};
    if (resetMode && !wasRemote && state.mode === 'live') {
      state.mode='demo';
      chrome.runtime.sendMessage({type:'AW_RENDERER_DEMO'}).catch(()=>{});
    }
    applyVisuals();
    if (notify && oldId) chrome.runtime.sendMessage({type:'AW_RECEIVER_LEFT',sessionId:oldId}).catch(()=>{});
  }

  async function startStream(message) {
    await initialized;
    mount();
    stopStream(false,false);
    if (state.sitesEnabled?.[pageSite] === false) throw new Error('이 사이트의 배경이 비활성화되어 있습니다.');
    const constraints={audio:false,video:{mandatory:{chromeMediaSource:'tab',chromeMediaSourceId:message.streamId},optional:[{maxFrameRate:30}]}};
    const media=await navigator.mediaDevices.getUserMedia(constraints);
    stream=media;sessionId=message.sessionId;crop=message.crop||null;
    const current=sessionId;
    media.getVideoTracks()[0]?.addEventListener('ended',()=>{if(sessionId===current)stopStream(true);},{once:true});
    hiddenVideo.srcObject=media;
    await hiddenVideo.play();
    state.mode='live';state.enabled=true;
    applyVisuals();
    return {ok:true};
  }

  async function beginRemote(message) {
    await initialized;
    mount();
    stopStream(false,false);
    if (!preferred()) return {ok:false,error:'이 사이트의 배경이 꺼져 있어요.'};
    remoteSessionId=message.sessionId;
    chrome.runtime.sendMessage({type:'AW_RECEIVER_VISIBILITY',sessionId:remoteSessionId,visible:!document.hidden}).catch(()=>{});
    crop=message.crop?{x:0,y:0,w:1,h:1}:null; // Cropped once in offscreen capture.
    state.mode='live';state.enabled=true;
    applyVisuals();
    return {ok:true};
  }
  function remoteGlow(message) {
    if(message.sessionId!==remoteSessionId || !crop || !allowed() || document.hidden || state.sourceMode!=='glow')return;
    const colors=message.colors;
    if(!Array.isArray(colors)||colors.length!==2||!colors.every(rgb=>Array.isArray(rgb)&&rgb.length===3&&rgb.every(c=>Number.isInteger(c)&&c>=0&&c<=255)))return;
    if (!averagedColors) averagedColors=colors;
    else averagedColors=colors.map((rgb,i)=>rgb.map((c,j)=>Math.round(averagedColors[i][j]*.74+c*.26)));
    const [a,b]=averagedColors;
    glow.style.background=`radial-gradient(ellipse 36% 64% at 12% 48%,rgb(${a.join(',')}),transparent 98%),radial-gradient(ellipse 36% 64% at 88% 52%,rgb(${b.join(',')}),transparent 98%)`;
    drawStats.frames++;
  }

  function remoteFrame(message) {
    if(message.sessionId!==remoteSessionId || !crop || !allowed() || document.hidden || remoteBusy || state.sourceMode!=='video')return;
    if(typeof message.frame!=='string'||!message.frame.startsWith('data:image/'))return;
    remoteBusy=true;
    // Reuse a single Image decoder per target; never accumulate per-frame DOM images.
    if(!remoteImage)remoteImage=new Image();
    const img=remoteImage;
    const generation=renderGeneration;
    img.onload=()=>{
      try{
        if(generation!==renderGeneration || message.sessionId!==remoteSessionId || !allowed() || document.hidden || state.sourceMode!=='video')return;
        const started=performance.now();
        ctx.drawImage(img,0,0,canvas.width,canvas.height);
        drawStats.frames++;
        drawStats.totalMs+=performance.now()-started;
      }catch{/* A resize or disconnect can interrupt a frame. */}
      finally{
        if(generation===renderGeneration){img.removeAttribute('src');remoteBusy=false;}
      }
    };
    img.onerror=()=>{if(generation===renderGeneration){img.removeAttribute('src');remoteBusy=false;}};
    img.src=message.frame;
  }

  const fromWorker=sender=>sender.id===chrome.runtime.id&&!sender.tab&&sender.url===`chrome-extension://${chrome.runtime.id}/source/background.js`;
  let settingsLoaded=false,settingsWorker=null,settingsRevision=-1;
  const earlySettings={},retiredSettingsWorkers=new Set();
  function settingsChanged(message){
    if(typeof message.workerId!=='string'||!Number.isSafeInteger(message.revision)||retiredSettingsWorkers.has(message.workerId))return;
    if(settingsWorker===message.workerId&&(message.revision<settingsRevision||message.revision===settingsRevision&&(!message.settings||settingsLoaded)))return;
    if(settingsWorker&&settingsWorker!==message.workerId){retiredSettingsWorkers.add(settingsWorker);if(retiredSettingsWorkers.size>16)retiredSettingsWorkers.delete(retiredSettingsWorkers.values().next().value);}
    settingsWorker=message.workerId;settingsRevision=message.revision;
    if(message.settings){message={...message,changes:Object.fromEntries(Object.keys(DEFAULTS).filter(key=>JSON.stringify(message.settings[key]??DEFAULTS[key])!==JSON.stringify(state[key])).map(key=>[key,{newValue:message.settings[key]??DEFAULTS[key]}]))};settingsLoaded=true;}
    if(!settingsLoaded)for(const key of Object.keys(DEFAULTS))if(message.changes?.[key])earlySettings[key]=message.changes[key].newValue;
    applySettingsChanges(message.changes||{});
  }
  chrome.runtime.onMessage.addListener((message,_sender,respond)=>{
    const popupStats=message?.type==='AW_PERF_STATS'&&_sender.id===chrome.runtime.id&&!_sender.tab&&_sender.url===`chrome-extension://${chrome.runtime.id}/source/popup.html`;
    if(!fromWorker(_sender)&&!popupStats){respond({ok:false});return;}
    if(message?.type==='AW_RENDERER_SETTINGS_CHANGED'){settingsChanged(message);respond({ok:true});return;}
    if(message?.type==='AW_WEB_CONTROL_APPLY'){
      if(_sender.id!==chrome.runtime.id){respond({ok:false});return;}
      initialized.then(()=>{applyWebControl(message.web);respond(webAck());});return true;
    }
    if (message?.type === 'AW_BEGIN_REMOTE') {
      beginRemote(message).then(respond).catch(e=>respond({ok:false,error:e.message}));
      return true;
    }
    if (message?.type === 'AW_REMOTE_FRAME') { remoteFrame(message);return; }
    if (message?.type === 'AW_REMOTE_GLOW') { remoteGlow(message);return; }
    if (message?.type === 'AW_STOP_REMOTE') {
      if(!message.sessionId || message.sessionId===remoteSessionId)stopStream(false);
      respond({ok:true});return;
    }
    if (message?.type === 'AW_START_STREAM') {
      startStream(message).then(respond).catch(e=>{stopStream(false);respond({ok:false,error:`영상 연결 실패: ${e.message}`});});
      return true;
    }
    if (message?.type === 'AW_PERF_STATS') {
      respond({ok:true, site:pageSite, performanceMode:state.performanceMode,
        canvas:{width:canvas?.width||0,height:canvas?.height||0},
        averageDrawMs:drawStats.frames ? Number((drawStats.totalMs/drawStats.frames).toFixed(2)) : 0,
        measuredFrames:drawStats.frames, rendering:renderTimer !== null, visible:!document.hidden});
      return;
    }
    if (message?.type === 'AW_STREAM_STATUS') {
      respond({ok:true, active:Boolean((stream?.active && sessionId) || remoteSessionId), sessionId:sessionId||remoteSessionId});
      return;
    }
    if (message?.type === 'AW_UPDATE_CROP') {
      if(message.sessionId&&message.sessionId!==(sessionId||remoteSessionId)){respond({ok:true});return;}
      crop=message.crop||null;
      if (!crop) cancelDraw();
      applyVisuals();
      respond({ok:true});
      return;
    }
    if (message?.type === 'AW_STOP_STREAM') {
      stopStream(false);
      respond({ok:true});
    }
  });
  const initialized=chrome.runtime.sendMessage({type:'AW_RENDERER_SETTINGS_GET'}).then(reply=>{
    if(!reply?.ok)throw Error('settingsUnavailable');
    if(!settingsLoaded&&(!settingsWorker||settingsWorker===reply.workerId)){
      Object.assign(state,DEFAULTS,reply.settings,earlySettings);settingsLoaded=true;
      if(settingsWorker===null||settingsWorker===reply.workerId){settingsWorker=reply.workerId;settingsRevision=Math.max(settingsRevision,reply.revision);}
    }else if(settingsWorker===reply.workerId)settingsChanged(reply);
    if(state.sourceMode === 'tab') state.sourceMode='video';
    mount();
    if (!stream && state.mode === 'live') state.mode='demo';
    applyVisuals();
  }).catch(()=>{mount();applyVisuals();});
  initialized.then(()=>syncWebControl());
  function applySettingsChanges(changes){
    for(const key of Object.keys(DEFAULTS))if(changes[key])state[key]=changes[key].newValue;
    if (!preferred() && (stream || remoteSessionId)) stopStream(true);

    if(state.sourceMode === 'tab') state.sourceMode='video';
    applyVisuals();
    if(Object.keys(DEFAULTS).some(key=>changes[key])){
      if(webReady)chrome.runtime.sendMessage({type:'AW_WEB_CONTROL_ACK',...webAck()}).catch(()=>{});
      scheduleWebQuery();if(!document.hidden&&preferred())syncWebControl();
    }
  }
  document.addEventListener('visibilitychange', () => {
    if(remoteSessionId)chrome.runtime.sendMessage({type:'AW_RECEIVER_VISIBILITY',sessionId:remoteSessionId,visible:!document.hidden}).catch(()=>{});
    if(document.hidden){cancelDraw();scheduleWebQuery();}
    else {webReady=false;invalidateRender();applyVisuals();syncWebControl();}
  });
  window.addEventListener('pageshow',()=>{webPageActive=true;webReady=false;applyVisuals();syncWebControl();});
  window.addEventListener('pagehide',()=>{webPageActive=false;webSequence++;scheduleWebQuery();stopStream(false,false);});
})();
