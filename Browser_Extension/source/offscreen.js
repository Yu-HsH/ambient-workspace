// Ambient Workspace v0.6 - single capture, web delivery + local desktop colors.
// Web glow delivers RGB; web video delivers WebP; desktop opt-in receives JPEG.
// Audio is not captured. Desktop frames use only the registered Native Messaging host through the trusted worker.
const profiles={
  eco:{w:400,h:225,fps:2,glowFps:2,q:.40},
  balanced:{w:560,h:315,fps:5,glowFps:3,q:.48},
  quality:{w:960,h:540,fps:10,glowFps:5,q:.62}
};
let stream=null,vid=null,canvas=null,ctx=null,sample=null,sampleCtx=null,timer=null;
let captureEpoch=0,endedTrack=null,endedHandler=null;
let sessionId=null,crop=null,profile=profiles.balanced,performanceMode='balanced';
let sourceMode='video',running=false,receiversVisible=true,userFpsCap=10;
let sentFrames=0,sentColors=0,encodedBytes=0,totalEncodeMs=0,startedAt=0;
let webFramePending=null,glowPending=null;
// Processing authority is separate from capture lifetime and output preferences.
let processingEpoch=0,controlSerial=0,captureControl=null,controlReady=false;
let controlPending=null,lastControlAt=-Infinity,transitionAt=0,appliedAtUtc=0,firstFrameMs=null;
const retiredWorkers=new Set();
const processingCounts=Object.fromEntries(['samples','canvasCopies','webpCalls','webpCompleted','jpegCalls','jpegCompleted','rgbBroadcasts','webpBroadcasts','bridgePosts','bridgeBytes','bridgeRgbPosts','bridgeJpegPosts','lateDropped','httpSettledAfterPause'].map(k=>[k,0]));
let pauseBoundary=null;
let sourceAuthority=null,sourceDeadline=0,sourceBoundary=null,sourceFence=null;
const sourceAllowed=()=>sourceAuthority?.ready===true&&sourceAuthority.workerId===captureControl?.workerId&&performance.now()<sourceDeadline;
const processingAllowed=()=>controlReady&&captureControl?.paused===false&&sourceAllowed();
const processingValid=epoch=>processingAllowed()&&epoch===processingEpoch;
const frameStamp=()=>({controlWorkerId:captureControl?.workerId,controlGeneration:captureControl?.generation,processingEpoch,sourceWorkerId:sourceAuthority?.workerId,sourceGeneration:sourceAuthority?.generation});
function processingSnapshot(){return {version:'2c3-gate-1',...captureControl,ready:controlReady,allowed:processingAllowed(),processingEpoch,observedAt:Date.now(),
  sessionId,active:running&&Boolean(stream?.active),trackIds:stream?.getVideoTracks().map(t=>t.id)||[],appliedAt:appliedAtUtc,firstFrameMs,
  inFlight:{webp:Boolean(webFramePending),jpeg:Boolean(desktopFramePending),rgb:Boolean(desktopInFlight),fanout:Boolean(glowPending),http:desktopRequests.size},
  counts:{...processingCounts},pauseBoundary,source:sourceSnapshot()};}
// A proof is short-lived: missing worker/content replies cannot preserve a crop.
function sourceSnapshot(){return {...sourceAuthority,allowed:sourceAllowed(),boundary:sourceBoundary};}
function closeSource(source=sourceAuthority,eventAt=null){
  sourceBoundary={eventAt,blockedAt:Date.now(),counts:{...processingCounts},inFlight:{webp:Boolean(webFramePending),jpeg:Boolean(desktopFramePending),http:desktopRequests.size}};
  sourceAuthority=source?{workerId:source.workerId,generation:source.generation,ready:false}:null;
  sourceDeadline=0;crop=null;lastColors=null;processingEpoch++;desktopEpoch++;
  for(const controller of desktopRequests)controller.abort();
  return {...sourceAuthority,...sourceBoundary};
}
function applySource(source,nextCrop){
  if(!source||source.ready!==true||typeof source.workerId!=='string'||!Number.isSafeInteger(source.generation)||!source.documentId||retiredWorkers.has(source.workerId))return false;
  if(sourceAuthority&&(sourceAuthority.workerId!==source.workerId||source.generation!==sourceAuthority.generation))return false;
  if(!nextCrop||!['x','y','w','h'].every(k=>Number.isFinite(nextCrop[k]))||nextCrop.x<0||nextCrop.y<0||nextCrop.w<=0||nextCrop.h<=0||nextCrop.x+nextCrop.w>1.001||nextCrop.y+nextCrop.h>1.001)return false;
  if(JSON.stringify(crop)!==JSON.stringify(nextCrop)||!sourceAllowed())processingEpoch++;
  sourceAuthority={...source};sourceDeadline=performance.now()+2500;crop=nextCrop;
  return true;
}
function noteFrame(){if(firstFrameMs===null&&processingAllowed())firstFrameMs=performance.now()-transitionAt;}
function applyCaptureControl(web){
  if(!web||typeof web.workerId!=='string'||!Number.isSafeInteger(web.generation)||web.generation<0||typeof web.paused!=='boolean'||typeof web.ready!=='boolean')return false;
  if(retiredWorkers.has(web.workerId)||captureControl?.workerId===web.workerId&&web.generation<captureControl.generation)return false;
  if(captureControl?.workerId===web.workerId&&web.generation===captureControl.generation&&captureControl.paused!==web.paused)return false;
  // A worker still loading its checkpoint must never release the last pause.
  if(!web.ready){
    controlReady=false;processingEpoch++;controlSerial++;desktopEpoch++;
    for(const controller of desktopRequests)controller.abort();
    lastColors=null;return false;
  }
  const changed=!controlReady||captureControl?.workerId!==web.workerId||captureControl?.generation!==web.generation||captureControl?.paused!==web.paused;
  if(changed){
    if(captureControl&&captureControl.workerId!==web.workerId){retiredWorkers.add(captureControl.workerId);if(retiredWorkers.size>16)retiredWorkers.delete(retiredWorkers.values().next().value);}
    processingEpoch++;controlSerial++;transitionAt=performance.now();appliedAtUtc=Date.now();firstFrameMs=null;
    if(web.paused){
      pauseBoundary={at:transitionAt,counts:{...processingCounts},inFlight:{webp:Boolean(webFramePending),jpeg:Boolean(desktopFramePending),rgb:Boolean(desktopInFlight),http:desktopRequests.size}};
      // Abort already dispatched native work; it may already have been applied.
      // Keep async slots occupied until their own finally to bound pending work.
      desktopEpoch++;for(const controller of desktopRequests)controller.abort();
    }
    lastColors=null;lastSampleAt=lastVideoAt=lastDesktopAt=lastYoutubeAt=lastDesktopFrameAt=-Infinity;
  }
  captureControl={workerId:web.workerId,generation:web.generation,paused:web.paused,instanceId:web.instanceId??null,revision:web.revision??null};controlReady=true;
  return true;
}
function syncCaptureControl(){
  if(controlPending||performance.now()-lastControlAt<1000)return;
  lastControlAt=performance.now();const work={serial:controlSerial};controlPending=work;
  const timeout=setTimeout(()=>{if(controlPending===work){controlPending=null;closeSource();}},1600);
  send({type:'AW_CAPTURE_CONTROL_SYNC'}).then(reply=>{
    if(controlPending===work&&work.serial===controlSerial){
      if(reply?.ok){applyCaptureControl(reply.web);if(!applySource(reply.source,crop))closeSource();}
      else closeSource();
    }
  }).finally(()=>{clearTimeout(timeout);if(controlPending===work)controlPending=null;});
}
// Local bridge: only RGB and opt-in low-resolution JPEG, never user text, URLs, or audio.
let desktopEnabled=false,desktopToken='',desktopOnline=false,desktopError='',desktopPackets=0;
let lastDesktopAt=0,lastSampleAt=0,lastVideoAt=0,desktopInFlight=null;
let desktopEpoch=0;
const desktopRequests=new Set();
let lastColors=null;
// Desktop video: JPEG snapshots only, low FPS, one in-flight frame max. Never audio.
let desktopVideoEnabled=false,desktopFramePending=null,lastDesktopFrameAt=-Infinity,desktopFrameCount=0;
let desktopExperimentalFps=0;
let desktopJpegEncoder=null;
function encodeDesktopJpeg(canvas,quality){
  if(!desktopJpegEncoder)desktopJpegEncoder=AW_JPEG_ENCODER.create();
  return desktopJpegEncoder.encode(canvas,quality);
}
let desktopCanvas=null,desktopCtx=null;
let youtubeAmbientEnabled=false,youtubeVisible=false,youtubeFps=2,lastYoutubeAt=-Infinity;
const desktopPeriod=650;
// Enabled only by the paired receiver's opt-in PerformanceMetrics response.
// Bounded numeric aggregates; no per-frame log, images, token or URLs.
let pipeline=null,pipelineEpoch=0;
function setPipelineEnabled(enabled){
  if(Boolean(pipeline)===enabled)return;
  const names=['tick','tickGap','captureCopy','desktopCopy','desktopGap','jpeg','postAttempt','http','ack','frameError','busySkipped','webp','fanout','webError','captureNotReady','tickError'];
  pipeline=enabled?{epoch:Date.now()*1000+(++pipelineEpoch%1000),started:performance.now(),stages:Object.fromEntries(names.map(name=>[name,{count:0,totalMs:0,maxMs:0}])),lastTick:null,lastDesktopCopy:null}:null;
}
function measureStage(name,ms=0,owner=pipeline){
  if(!owner||owner!==pipeline)return;
  const s=owner.stages[name]||(owner.stages[name]={count:0,totalMs:0,maxMs:0});
  s.count++;s.totalMs+=ms;s.maxMs=Math.max(s.maxMs,ms);
}
function pipelineSnapshot(){
  if(!pipeline)return null;
  let playback;try{playback=vid?.getVideoPlaybackQuality?.();}catch{}
  return {epoch:pipeline.epoch,elapsedMs:performance.now()-pipeline.started,utcMs:Date.now(),mode:performanceMode,targetFps:desktopExperimentalFps||(performanceMode==='eco'?1:performanceMode==='quality'?4:2),
    decodedFrames:playback?.totalVideoFrames??null,droppedFrames:playback?.droppedVideoFrames??null,
    stages:JSON.parse(JSON.stringify(pipeline.stages))};
}
const tokenValid=t=>/^[a-f0-9]{64}$/.test(String(t||''));
async function postDesktop(token,payload){
  if(!tokenValid(token))throw Error('잘못된 페어링 코드');
  const controller=new AbortController(),requestId=crypto.randomUUID().replaceAll('-','');
  desktopRequests.add(controller);
  const timeout=setTimeout(()=>controller.abort(),1200);
  let abortListener,dispatched=false;
  const media=payload.type==='colors'||payload.type==='frame',epoch=processingEpoch;
  try{
    const packet={token,...payload},body=JSON.stringify(packet);
    if(media&&!processingAllowed())throw Error('캡처 문서 미확인');
    if(media){processingCounts.bridgePosts++;processingCounts.bridgeBytes+=body.length;processingCounts[payload.type==='frame'?'bridgeJpegPosts':'bridgeRgbPosts']++;}
    const exchange=chrome.runtime.sendMessage({type:'AW_NATIVE_REQUEST',requestId,packet,sessionId,...(media?frameStamp():{})});
    dispatched=true;
    const cancelled=new Promise((_,reject)=>{abortListener=()=>{
      chrome.runtime.sendMessage({type:'AW_NATIVE_CANCEL',requestId}).catch(()=>{});reject(Error('aborted'));
    };controller.signal.addEventListener('abort',abortListener,{once:true});if(controller.signal.aborted)abortListener();});
    const response=await Promise.race([exchange,cancelled]);
    if(response?.ok!==true)throw Error(response?.error||'nativeUnavailable');
    if(response.result?.ok!==true)throw Error(response.result?.status||'invalid');
    return response.result;
  }finally{
    // Retain the diagnostic field for existing consumers. In native mode it
    // counts completed/cancelled IPC waits after a gate change, not HTTP traffic.
    if(media&&dispatched&&!processingValid(epoch))processingCounts.httpSettledAfterPause++;
    clearTimeout(timeout);if(abortListener)controller.signal.removeEventListener('abort',abortListener);desktopRequests.delete(controller);
  }
}
function cancelDesktopWork(){
  desktopEpoch++;
  for(const controller of desktopRequests)controller.abort();
  desktopRequests.clear();desktopInFlight=null;desktopFramePending=null;
  desktopJpegEncoder?.close();desktopJpegEncoder=null;
}
function desktopStatus(){return {enabled:desktopEnabled,online:desktopOnline,error:desktopError,packets:desktopPackets,videoEnabled:desktopVideoEnabled,videoFrames:desktopFrameCount,experimentalFps:desktopExperimentalFps,pipeline:pipelineSnapshot()};}
async function deliverDesktop(colors,id){
  if(!processingAllowed()||id!==sessionId||!running||desktopInFlight||!desktopEnabled||!tokenValid(desktopToken))return;
  const work={epoch:desktopEpoch,token:desktopToken};
  desktopInFlight=work;
  try{
    const result=await postDesktop(work.token,{type:'colors',colors});
    if(id===sessionId&&work.epoch===desktopEpoch){
      desktopOnline=true;desktopError='';desktopPackets++;
      const experiment=[5,10].includes(result.experimentalVideoFps)?result.experimentalVideoFps:0;
      if(experiment!==desktopExperimentalFps){setPipelineEnabled(false);desktopExperimentalFps=experiment;lastDesktopFrameAt=-Infinity;}
      setPipelineEnabled(result.diagnostics===true);
    }
  }catch(e){if(id===sessionId&&work.epoch===desktopEpoch){desktopOnline=false;desktopError=e.message;}}
  finally{if(desktopInFlight===work)desktopInFlight=null;}
}
async function deliverDesktopFrame(id){
  if(!processingAllowed())return;
  if(desktopFramePending)measureStage('busySkipped');
  if(id!==sessionId||!running||desktopFramePending||!desktopOnline||!desktopEnabled||!desktopVideoEnabled||!tokenValid(desktopToken)||!canvas)return;
  const work={epoch:desktopEpoch,processing:processingEpoch,token:desktopToken,metrics:pipeline};
  desktopFramePending=work;
  try{
    const w=performanceMode==='eco'?240:performanceMode==='quality'?480:360;
    const h=Math.round(w*9/16);
    if(!desktopCanvas){desktopCanvas=document.createElement('canvas');desktopCtx=desktopCanvas.getContext('2d',{alpha:false});}
    if(desktopCanvas.width!==w||desktopCanvas.height!==h){desktopCanvas.width=w;desktopCanvas.height=h;}
    const copyAt=performance.now();
    desktopCtx.drawImage(canvas,0,0,w,h);
    processingCounts.canvasCopies++;
    measureStage('desktopCopy',performance.now()-copyAt,work.metrics);
    if(work.metrics&&work.metrics===pipeline){if(pipeline.lastDesktopCopy!==null)measureStage('desktopGap',copyAt-pipeline.lastDesktopCopy);pipeline.lastDesktopCopy=copyAt;}
    const jpegAt=performance.now();
    processingCounts.jpegCalls++;
    const blob=await encodeDesktopJpeg(desktopCanvas,performanceMode==='eco'?0.36:0.46);
    processingCounts.jpegCompleted++;
    let data=null;
    if(processingValid(work.processing)){
      const bytes=new Uint8Array(await blob.arrayBuffer());
      if(processingValid(work.processing)){let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));data=btoa(binary);}
    }
    measureStage('jpeg',performance.now()-jpegAt,work.metrics);
    if(!processingValid(work.processing)){processingCounts.lateDropped++;return;}
    if(id!==sessionId||work.epoch!==desktopEpoch||!running||!desktopEnabled||!desktopVideoEnabled)return;
    // The receiver rejects overlarge data. Keep the network payload bounded.
    if(data.length>120000)throw Error('데스크톱 프레임 용량 초과');
    measureStage('postAttempt',0,work.metrics);
    const httpAt=performance.now();
    try { await postDesktop(work.token,{type:'frame',jpeg:data,...(pipeline?{diagnostics:pipelineSnapshot()}:{})}); }
    finally { measureStage('http',performance.now()-httpAt,work.metrics); }
    measureStage('ack',0,work.metrics);
    if(id===sessionId&&work.epoch===desktopEpoch&&processingValid(work.processing)){desktopFrameCount++;noteFrame();}
  }catch(e){measureStage('frameError',0,work.metrics);if(id===sessionId&&work.epoch===desktopEpoch)desktopError=e.message;}
  finally{if(desktopFramePending===work)desktopFramePending=null;}
}
function configureDesktop(enabled,token,videoEnabled=desktopVideoEnabled){
  cancelDesktopWork();
  setPipelineEnabled(false);
  desktopExperimentalFps=0;
  desktopEnabled=Boolean(enabled)&&tokenValid(token);
  desktopToken=desktopEnabled?token:'';
  desktopOnline=false;desktopError='';desktopVideoEnabled=Boolean(videoEnabled);
  lastDesktopAt=0;lastDesktopFrameAt=-Infinity;
}

const clamp=(x,min,max)=>Math.max(min,Math.min(max,Number(x)||0));
const send=msg=>chrome.runtime.sendMessage(msg).catch(()=>null);
function counters(){return {sentFrames,sentColors,encodedBytes,meanEncodeMs:sentFrames?+(totalEncodeMs/sentFrames).toFixed(2):0,elapsedSeconds:startedAt?Math.floor((Date.now()-startedAt)/1000):0};}
function configure({performanceMode:nextPerf,sourceMode:nextMode,fps:nextFps}={}){
  if(profiles[nextPerf]){const reset=performanceMode!==nextPerf&&Boolean(pipeline);performanceMode=nextPerf;profile=profiles[nextPerf];if(reset){setPipelineEnabled(false);setPipelineEnabled(true);}}
  if(nextMode==='video'||nextMode==='glow')sourceMode=nextMode;
  if(Number.isFinite(nextFps))userFpsCap=clamp(nextFps,1,30);
  if(canvas&&(canvas.width!==profile.w||canvas.height!==profile.h)){
    canvas.width=profile.w;canvas.height=profile.h;
  }
}
function stop(notify=false){
  const old=sessionId;
  controlSerial++;processingEpoch++;
  captureEpoch++;cancelDesktopWork();
  setPipelineEnabled(false);
  desktopExperimentalFps=0;
  webFramePending=null;glowPending=null;
  sessionId=null;running=false;crop=null;sourceAuthority=null;sourceDeadline=0;receiversVisible=false;
  lastSampleAt=-Infinity;lastVideoAt=-Infinity;lastDesktopAt=-Infinity;lastYoutubeAt=-Infinity;lastDesktopFrameAt=-Infinity;lastColors=null;desktopOnline=false;
  desktopEnabled=false;desktopToken='';desktopVideoEnabled=false;
  if(desktopCanvas){desktopCanvas.width=0;desktopCanvas.height=0;desktopCanvas=null;desktopCtx=null;}
  if(timer!==null){clearTimeout(timer);timer=null;}
  if(endedTrack&&endedHandler)endedTrack.removeEventListener?.('ended',endedHandler);
  endedTrack=null;endedHandler=null;
  if(vid){vid.pause();vid.srcObject=null;vid.load?.();vid.remove();vid=null;}
  if(stream){for(const t of stream.getTracks())t.stop();stream=null;}
  // A live track and decoder are explicitly released; cleared canvas releases frames.
  if(canvas){canvas.width=0;canvas.height=0;canvas=null;ctx=null;}
  if(sample){sample.width=0;sample.height=0;sample=null;sampleCtx=null;}
  if(notify&&old)send({type:'AW_OFFSCREEN_ENDED',sessionId:old});
}
async function start(msg){
  // Navigation may overtake a START message before getUserMedia even begins.
  // Preserve this fence across stop(); late START must not reopen its old proof.
  if(sourceFence&&(msg.source?.workerId!==sourceFence.workerId||msg.source.generation<sourceFence.generation))return {ok:false,error:'이동으로 취소된 캡처 요청이에요.'};
  stop(false);
  controlReady=false;
  applyCaptureControl(msg.control);
  const epoch=captureEpoch;
  configure(msg);
  configureDesktop(msg.desktopEnabled,msg.desktopToken,msg.desktopVideoEnabled);
  youtubeAmbientEnabled=Boolean(msg.youtubeAmbientEnabled);youtubeVisible=Boolean(msg.youtubeVisible);youtubeFps=clamp(msg.youtubeAmbientFps||2,1,4);lastYoutubeAt=-Infinity;
  sessionId=msg.sessionId;sourceAuthority=msg.source?{workerId:msg.source.workerId,generation:msg.source.generation,ready:false}:null;applySource(msg.source,msg.crop);
  sentFrames=0;sentColors=0;encodedBytes=0;totalEncodeMs=0;desktopPackets=0;desktopFrameCount=0;startedAt=Date.now();
  lastSampleAt=-Infinity;lastVideoAt=-Infinity;lastDesktopAt=-Infinity;
  try{
    const media=await navigator.mediaDevices.getUserMedia({audio:false,video:{mandatory:{chromeMediaSource:'tab',chromeMediaSourceId:msg.streamId}}});
    // getUserMedia cannot be cancelled; a superseded result must release its own tracks.
    if(epoch!==captureEpoch){for(const track of media.getTracks())track.stop();return {ok:false,error:'취소된 캡처 요청이에요.'};}
    stream=media;
    vid=document.createElement('video');vid.muted=true;vid.autoplay=true;vid.playsInline=true;
    vid.srcObject=stream;vid.style.display='none';document.body.append(vid);
    canvas=document.createElement('canvas');canvas.width=profile.w;canvas.height=profile.h;
    ctx=canvas.getContext('2d',{alpha:false});
    sample=document.createElement('canvas');sample.width=48;sample.height=24;
    sampleCtx=sample.getContext('2d',{willReadFrequently:true,alpha:false});
    const thisSession=sessionId;
    endedTrack=stream.getVideoTracks()[0];
    endedHandler=()=>{if(epoch===captureEpoch)stop(true);};
    endedTrack?.addEventListener('ended',endedHandler,{once:true});
    await vid.play();
    if(epoch!==captureEpoch)return {ok:false,error:'취소된 캡처 요청이에요.'};
    running=true;receiversVisible=Boolean(msg.webVisible);
    tick(thisSession);
    return {ok:true};
  }catch(e){if(epoch===captureEpoch)stop(false);return {ok:false,error:'탭 캡처에 실패했어요: '+e.message};}
}
function videoCrop(){
  const W=vid.videoWidth,H=vid.videoHeight;
  let x=clamp(crop.x,0,.99)*W,y=clamp(crop.y,0,.99)*H;
  let w=Math.min(clamp(crop.w,.01,1)*W,W-x),h=Math.min(clamp(crop.h,.01,1)*H,H-y);
  if(w<=1||h<=1)return null;
  const ar=canvas.width/canvas.height;
  if(w/h>ar){const nw=h*ar;x+=(w-nw)/2;w=nw;}
  else{const nh=w/ar;y+=(h-nh)/2;h=nh;}
  return {x,y,w,h};
}
function glowColors(rect){
  processingCounts.samples++;processingCounts.canvasCopies++;
  sampleCtx.drawImage(vid,rect.x,rect.y,rect.w,rect.h,0,0,48,24);
  const data=sampleCtx.getImageData(0,0,48,24).data;
  const sides=[[0,0,0,0],[0,0,0,0]];
  for(let y=1;y<23;y+=2){
    for(let x=1;x<47;x+=2){
      if(x>=18&&x<=30)continue;
      const side=sides[x<24?0:1],i=(y*48+x)*4;
      side[0]+=data[i];side[1]+=data[i+1];side[2]+=data[i+2];side[3]++;
    }
  }
  return sides.map((v,index)=>{
    const rgb=v.slice(0,3).map(c=>c/Math.max(1,v[3]));
    const lum=rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722;
    const chroma=Math.max(...rgb)-Math.min(...rgb);
    if(lum<22&&chroma<12)return index===0?[76,92,153]:[51,133,112];
    const boost=Math.max(1,110/Math.max(22,lum));
    return rgb.map(c=>Math.round(Math.min(215,c*boost)));
  });
}
function encodeWebp(c,q,valid){
  // Async encoding avoids the synchronous toDataURL blocking the capture loop.
  return new Promise((resolve,reject)=>c.toBlob(blob=>{
    processingCounts.webpCompleted++;
    if(!valid())return resolve(null);
    if(!blob)return reject(new Error('영상 압축 실패'));
    const reader=new FileReader();
    reader.onload=()=>resolve({frame:reader.result,bytes:blob.size});
    reader.onerror=()=>reject(new Error('압축 영상 읽기 실패'));
    reader.readAsDataURL(blob);
  },'image/webp',q));
}
// A slow web/YouTube receiver must not hold the shared capture scheduler.
// Keep the existing one-frame bound: while busy, use a fresh frame on the next eligible tick.
async function deliverWebFrame(id,forWeb,forYoutube){
  if(!processingAllowed()||webFramePending||!running||id!==sessionId)return;
  const work={epoch:captureEpoch,processing:processingEpoch,metrics:pipeline};webFramePending=work;
  try{
    const encodeAt=performance.now();
    processingCounts.webpCalls++;
    const result=await encodeWebp(canvas,profile.q,()=>processingValid(work.processing)&&work.epoch===captureEpoch);
    if(!result||!processingValid(work.processing)){processingCounts.lateDropped++;return;}
    const {frame,bytes}=result;
    measureStage('webp',performance.now()-encodeAt,work.metrics);
    if(!running||id!==sessionId||work.epoch!==captureEpoch)return;
    if(!(forWeb&&receiversVisible&&sourceMode==='video'||forYoutube&&youtubeAmbientEnabled&&youtubeVisible))return;
    totalEncodeMs+=performance.now()-encodeAt;encodedBytes+=bytes;sentFrames++;
    const fanoutAt=performance.now();
    processingCounts.webpBroadcasts++;
    const reply=await send({type:'AW_FRAME_BROADCAST',sessionId:id,frame,youtubeFrame:forYoutube,...frameStamp()});
    if(reply?.ok&&processingValid(work.processing))noteFrame();
    measureStage('fanout',performance.now()-fanoutAt,work.metrics);
  }catch{measureStage('webError',0,work.metrics); /* Keep Desktop and the next tick alive. */ }
  finally{if(webFramePending===work)webFramePending=null;}
}
async function deliverGlow(colors,id){
  if(!processingAllowed()||glowPending||!running||id!==sessionId)return;
  const work={epoch:captureEpoch,processing:processingEpoch};glowPending=work;
  try{processingCounts.rgbBroadcasts++;const reply=await send({type:'AW_GLOW_BROADCAST',sessionId:id,colors,...frameStamp()});if(running&&id===sessionId&&work.epoch===captureEpoch&&processingValid(work.processing)){sentColors++;if(reply?.ok)noteFrame();}}
  finally{if(glowPending===work)glowPending=null;}
}
async function tick(id){
  if(!running||id!==sessionId)return;
  if(sourceAuthority?.ready&&!sourceAllowed())closeSource();
  syncCaptureControl();
  const now=performance.now();
  if(pipeline){if(pipeline.lastTick!==null)measureStage('tickGap',now-pipeline.lastTick);pipeline.lastTick=now;measureStage('tick');}
  // No video encoding while only Desktop needs colors. No sampling when all receivers are inactive.
  const needWebVideo=receiversVisible&&sourceMode==='video';
  const needYoutube=youtubeAmbientEnabled&&youtubeVisible;
  const youtubeGap=1000/youtubeFps;
  const needDesktopVideo=desktopEnabled&&desktopVideoEnabled&&desktopOnline;
  const desktopVideoGap=desktopExperimentalFps?1000/desktopExperimentalFps:performanceMode==='eco'?1000:performanceMode==='quality'?250:500;
  const needEncode=needWebVideo||needYoutube||needDesktopVideo;
  const needWebGlow=receiversVisible&&sourceMode==='glow';
  const needDesktop=desktopEnabled&&tokenValid(desktopToken);
  const sampleGap=1000/(needWebGlow?profile.glowFps:(needDesktop?1000/desktopPeriod:1));
  const frameGap=1000/Math.min(profile.fps,userFpsCap);
  if(processingAllowed()&&(needEncode||needWebGlow||needDesktop)&&crop&&vid?.readyState>=2&&vid.videoWidth&&vid.videoHeight){
    try{
      const rect=videoCrop();
      if(rect){
        const shouldSample=(needWebGlow||needDesktop) && now-lastSampleAt>=sampleGap;
        if(shouldSample){
          const colors=glowColors(rect);
          lastColors=colors;lastSampleAt=now;
          if(needWebGlow)deliverGlow(colors,id);
        }
        if(needDesktop && lastColors && now-lastDesktopAt>=desktopPeriod){
          lastDesktopAt=now;
          // Never block video frame delivery waiting for the local Windows listener.
          deliverDesktop(lastColors,id);
        }
        const forYoutube=needYoutube&&!webFramePending&&now-lastYoutubeAt>=youtubeGap;
        const forWeb=needWebVideo&&!webFramePending&&now-lastVideoAt>=frameGap;
        const forDesktop=needDesktopVideo && now-lastDesktopFrameAt>=desktopVideoGap;
        if(forWeb||forYoutube||forDesktop){
          if(forWeb)lastVideoAt=now;
          if(forYoutube)lastYoutubeAt=now;
          if(forDesktop)lastDesktopFrameAt=now;
          const copyAt=performance.now();
          ctx.drawImage(vid,rect.x,rect.y,rect.w,rect.h,0,0,canvas.width,canvas.height);
          processingCounts.canvasCopies++;
          measureStage('captureCopy',performance.now()-copyAt);
          if(forDesktop)deliverDesktopFrame(id);
          if(forWeb||forYoutube)deliverWebFrame(id,forWeb,forYoutube);
        }
      }
    }catch{measureStage('tickError'); /* Tab navigation/resize can interrupt a frame. */ }
  }else if(processingAllowed()&&(needEncode||needWebGlow||needDesktop)){measureStage('captureNotReady');}
  if(running&&sessionId===id){
    const targetDelay=needEncode?Math.min(needWebVideo?frameGap:1000,needYoutube?youtubeGap:1000,needDesktopVideo?desktopVideoGap:1000,desktopPeriod):
      needWebGlow?Math.min(sampleGap,desktopPeriod):needDesktop?desktopPeriod:1000;
    timer=setTimeout(()=>{timer=null;tick(id);},Math.max(70,targetDelay-(performance.now()-now)));
  }
}

chrome.runtime.onMessage.addListener((msg,_sender,respond)=>{
  if(msg?.target!=='aw-offscreen')return;
  if(_sender.id!==chrome.runtime.id||_sender.tab||_sender.url!==`chrome-extension://${chrome.runtime.id}/source/background.js`){respond({ok:false});return;}
  if(msg.type==='AW_OFFSCREEN_SOURCE_BLOCK'){
    if(!msg.source||retiredWorkers.has(msg.source.workerId)||sourceFence?.workerId===msg.source.workerId&&msg.source.generation<sourceFence.generation){respond({ok:false});return;}
    sourceFence={workerId:msg.source.workerId,generation:msg.source.generation};
    if((!msg.sessionId||sessionId===msg.sessionId)&&(!sourceAuthority||sourceAuthority.workerId!==msg.source?.workerId||msg.source?.generation>=sourceAuthority.generation)){
      respond({ok:true,source:closeSource(msg.source,msg.eventAt)});
    }else respond({ok:sessionId!==msg.sessionId});return;
  }
  if(msg.type==='AW_OFFSCREEN_SOURCE_APPLY'){
    respond({ok:sessionId!==msg.sessionId||applySource(msg.source,msg.crop)});return;
  }
  if(msg.type==='AW_OFFSCREEN_CONTROL_APPLY'){
    const ok=applyCaptureControl(msg.control);respond({ok,gate:processingSnapshot()});return;
  }
  if(msg.type==='AW_OFFSCREEN_DESKTOP_PING'){
    postDesktop(msg.token,{type:'ping'}).then(()=>respond({ok:true})).catch(e=>respond({ok:false,error:e.message}));return true;
  }
  if(msg.type==='AW_OFFSCREEN_DESKTOP_CONFIG'){
    if(!msg.sessionId||msg.sessionId===sessionId)configureDesktop(msg.enabled,msg.token,msg.videoEnabled);respond({ok:true});return;
  }
  if(msg.type==='AW_OFFSCREEN_START'){
    start(msg).then(respond).catch(e=>respond({ok:false,error:e.message}));return true;
  }
  if(msg.type==='AW_OFFSCREEN_STOP'){
    if(!msg.sessionId||sessionId===msg.sessionId)stop(false);
    respond({ok:true});return;
  }
  if(msg.type==='AW_OFFSCREEN_SET_ACTIVE'){
    if(sessionId===msg.sessionId)receiversVisible=Boolean(msg.active);
    respond({ok:true});return;
  }
  if(msg.type==='AW_OFFSCREEN_YOUTUBE_CONFIG'){
    if(sessionId===msg.sessionId){
      if(msg.enabled!==undefined)youtubeAmbientEnabled=Boolean(msg.enabled);
      if(msg.visible!==undefined)youtubeVisible=Boolean(msg.visible);
      if(msg.fps!==undefined)youtubeFps=clamp(msg.fps,1,4);
      lastYoutubeAt=-Infinity;
    }
    respond({ok:true});return;
  }
  if(msg.type==='AW_OFFSCREEN_CROP'){
    // Legacy crop updates may revoke a proof but cannot authorize a document.
    if(sessionId===msg.sessionId)closeSource();
    respond({ok:true});return;
  }
  if(msg.type==='AW_OFFSCREEN_CONFIGURE'){
    if(sessionId===msg.sessionId)configure(msg);
    respond({ok:true});return;
  }
  if(msg.type==='AW_OFFSCREEN_STATUS'){
    respond({ok:true,active:running&&Boolean(stream?.active),sessionId,mode:sourceMode,performanceMode,stats:counters(),processing:processingSnapshot(),desktop:desktopStatus(),youtubeAmbient:{enabled:youtubeAmbientEnabled,visible:youtubeVisible,fps:youtubeFps}});return;
  }
});
