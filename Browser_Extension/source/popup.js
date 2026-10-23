const DEFAULTS = {enabled:true,mode:'demo',intensity:30,blur:13,dim:30,saturation:88,
  protectCenter:true,focusWidth:70,focusHeight:115,sourceMode:'video',fps:5,
  palette:'twilight',motion:'vertical',motionSpeed:65,performanceMode:'balanced',sitesEnabled:{chatgpt:true,claude:true,gemini:true,notion:true},youtubeAmbientEnabled:true,youtubeAmbientStrength:84,youtubeAmbientBlur:118,youtubeAmbientSpread:440,youtubeAmbientFps:2,desktopVideoEnabled:false};
const PRESETS = {
  focus: {intensity:24,blur:22,dim:52,saturation:76,protectCenter:true,focusWidth:78,focusHeight:120,sourceMode:'glow',fps:2},
  balanced: {intensity:36,blur:12,dim:34,saturation:88,protectCenter:true,focusWidth:70,focusHeight:115,sourceMode:'video',fps:5},
  immersive: {intensity:52,blur:6,dim:18,saturation:110,protectCenter:true,focusWidth:62,focusHeight:105,sourceMode:'video',fps:10}
};
const YT_LIGHT_PRESETS={
  subtle:{youtubeAmbientStrength:34,youtubeAmbientSpread:140,youtubeAmbientBlur:56},
  balanced:{youtubeAmbientStrength:58,youtubeAmbientSpread:250,youtubeAmbientBlur:88},
  cinematic:{youtubeAmbientStrength:84,youtubeAmbientSpread:440,youtubeAmbientBlur:118}
};
const $ = id => document.getElementById(id);
const SITE_URLS = ['https://chatgpt.com/*','https://chat.openai.com/*','https://claude.ai/*','https://gemini.google.com/*','https://notion.so/*','https://www.notion.so/*','https://notion.com/*','https://www.notion.com/*','https://app.notion.com/*','https://app.notion.so/*'];
const SITE_NAMES = {chatgpt:'ChatGPT',claude:'Claude',gemini:'Gemini',notion:'Notion'};
function siteFromUrl(url='') {
  try { const host = new URL(url).hostname;
    if(['chatgpt.com','chat.openai.com'].includes(host)) return 'chatgpt';
    if(host==='claude.ai') return 'claude';
    if(host==='gemini.google.com') return 'gemini';
    if(['notion.so','www.notion.so','notion.com','www.notion.com','app.notion.com','app.notion.so'].includes(host)) return 'notion';
  }catch{} return null;
}
let sitesEnabled={...DEFAULTS.sitesEnabled};
let targetOptions=[];
let targetSignature='';
let activeTabInfo=null;
function fillSiteOptions(){
  document.querySelectorAll('[data-site]').forEach(input=>input.checked=sitesEnabled[input.dataset.site]!==false);
}
async function loadTargets(){
  const select=$('targetTab');
  const last=select.value;
  targetOptions=(await chrome.tabs.query({url:SITE_URLS})).filter(t=>sitesEnabled[siteFromUrl(t.url)]!==false && t.id);
  targetOptions.sort((a,b)=>(b.lastAccessed||0)-(a.lastAccessed||0));
  select.disabled=!/^https:\/\/(?:www\.)?youtube\.com\//i.test(activeTabInfo?.url||'');
  const signature=JSON.stringify(targetOptions.map(tab=>[tab.id,tab.title,siteFromUrl(tab.url)]));
  if(signature===targetSignature)return;
  targetSignature=signature;
  select.replaceChildren();
  const all=document.createElement('option');all.value='all';all.textContent=targetOptions.length?`모든 지원 탭 (${targetOptions.length}개) + Windows`:'모든 지원 탭 + Windows (웹 탭 없음)';select.append(all);
  const desktop=document.createElement('option');desktop.value='desktop';desktop.textContent='Desktop만 (웹 탭 없이)';select.append(desktop);
  const youtube=document.createElement('option');youtube.value='youtube';youtube.textContent='YouTube 조명만';select.append(youtube);
  const auto=document.createElement('option');auto.value='auto';auto.textContent='최근 작업 탭 1개';select.append(auto);
  for(const tab of targetOptions){
    const item=document.createElement('option');
    item.value=String(tab.id);
    item.textContent=`${SITE_NAMES[siteFromUrl(tab.url)]} · ${String(tab.title||'새 탭').slice(0,30)}`;
    select.append(item);
  }
  select.value=[...select.options].some(o=>o.value===last)?last:'all';
}
function powerNote(){
  const profile=$('powerNote');
  const map={eco:'절전: 영상 400×225 · 최대 2 FPS / 색상 2회·초, 그라데이션 정지, 흐림 최대 8px.',balanced:'균형: 영상 560×315 · 최대 5 FPS / 색상 3회·초.',quality:'고품질: 영상 960×540 · 최대 10 FPS / 색상 5회·초.'};
  const selected=document.querySelector('[data-power].selected')?.dataset.power||'balanced';
  profile.textContent=map[selected]+' 반사광 모드는 영상 이미지 없이 색상 2개만 전달합니다.';
}
function setPower(mode){
  document.querySelectorAll('[data-power]').forEach(button=>{
    const selected=button.dataset.power===mode;
    button.classList.toggle('selected',selected);
    button.setAttribute('aria-pressed',String(selected));
  });
  powerNote();
  $('desktopFpsNote').textContent=({eco:'Desktop 영상 상한: 240×135 · 1 FPS',balanced:'Desktop 영상 상한: 360×203 · 2 FPS',quality:'Desktop 영상 상한: 480×270 · 4 FPS'})[mode]+'. YouTube 조명은 별도 1/2/4 FPS입니다. 수치는 상한이며 실측값이 아닙니다.';
}
const fields = ['intensity','blur','dim','saturation','focusWidth','focusHeight','motionSpeed'];
const suffixes = {intensity:'%',blur:'px',dim:'%',saturation:'%',focusWidth:'%',focusHeight:'%',motionSpeed:'초 / 왕복 방향'};
let busy = false;
let desktopPending = false;
let desktopView = {paired:false,enabled:false,videoEnabled:false};
let currentSession = null;
let selectedPreset = null;
let confirmedSettings = {...DEFAULTS};
let settingsQueue = Promise.resolve();
let settingsPending = 0;
let statusSequence = 0;
let statusLoading = false;
let stopPending = false;
let demoPending = false;
let errorSource = null;
let refreshTimer;
let pollTimer;
const ytFields = {youtubeAmbientStrength:'%',youtubeAmbientSpread:'px',youtubeAmbientBlur:'px'};

function selectTab(name, focus=false) {
  const tabs=[...document.querySelectorAll('[data-tab]')];
  if(!tabs.some(tab=>tab.dataset.tab===name))return;
  for(const tab of tabs){
    const selected=tab.dataset.tab===name;
    tab.setAttribute('aria-selected',String(selected));tab.tabIndex=selected?0:-1;
    $(tab.getAttribute('aria-controls')).hidden=!selected;
    if(selected&&focus)tab.focus();
  }
  $('panelScroll').scrollTop=0;
}
function initTabs() {
  const tabs=[...document.querySelectorAll('[data-tab]')];
  tabs.forEach((tab,index)=>{
    tab.addEventListener('click',()=>selectTab(tab.dataset.tab));
    tab.addEventListener('keydown',event=>{
      const next=event.key==='ArrowRight'?(index+1)%tabs.length:event.key==='ArrowLeft'?(index+tabs.length-1)%tabs.length:event.key==='Home'?0:event.key==='End'?tabs.length-1:null;
      if(next===null)return;
      event.preventDefault();selectTab(tabs[next].dataset.tab,true);
    });
  });
  $('openPairing').addEventListener('click',()=>{selectTab('pairing');$('desktopCode').focus();});
}
function setPairError(message='') {
  $('pairError').hidden=!message;$('pairError').textContent=message;
  $('desktopCode').setAttribute('aria-invalid',String(Boolean(message)));
}
function setSettingsError(message='') {
  $('settingsError').hidden=!message;$('settingsError').textContent=message;
}
function syncYtPresets(values) {
  let selected=null;
  document.querySelectorAll('[data-yt-light]').forEach(button=>{
    const match=Object.entries(YT_LIGHT_PRESETS[button.dataset.ytLight]).every(([key,value])=>Number(values[key])===value);
    button.classList.toggle('selected',match);button.setAttribute('aria-pressed',String(match));
    if(match)selected=button.dataset.ytLight;
  });
  $('ytPresetStatus').textContent=({subtle:'은은함',balanced:'균형',cinematic:'풍부함'})[selected]||'직접 조절';
}
function syncYoutubeAmbient(enabled) {
  $('youtubeAmbientEnabled').checked=enabled;
  $('youtubeAmbientToggle').setAttribute('aria-pressed',String(enabled));
  $('youtubeAmbientToggle').textContent=enabled?'조명 끄기':'조명 다시 켜기';
  const state=enabled?(currentSession?'조명 켜짐 · 영상 연결됨':'조명 켜짐 · YouTube 연결 대기')
    :(currentSession?'조명 꺼짐 · 캡처 연결 유지':'조명 꺼짐');
  $('youtubeAmbientStatus').textContent=state;
  $('youtubeAmbientOutputState').textContent=state;
}
function changeYoutubeAmbient(enabled) {
  syncYoutubeAmbient(enabled);
  return save({youtubeAmbientEnabled:enabled});
}
function applySettings(values) {
  sitesEnabled={...DEFAULTS.sitesEnabled,...values.sitesEnabled};fillSiteOptions();
  setPower(values.performanceMode||'balanced');fillForm(values);
  selectedPreset=inferPreset(values);updatePresetUI();
  syncYoutubeAmbient(values.youtubeAmbientEnabled!==false);
  $('youtubeAmbientFps').value=String([1,2,4].includes(Number(values.youtubeAmbientFps))?values.youtubeAmbientFps:2);
  for(const [field,suffix] of Object.entries(ytFields)){
    $(field).value=values[field]??DEFAULTS[field];$(field+'Value').textContent=$(field).value+suffix;
  }
  syncYtPresets(values);
}
// Serialize saves so a failed earlier slider event cannot overwrite a later confirmed value.
function patchSettings(patch) {
  settingsPending++;$('saveStatus').textContent='설정 저장 중…';
  const saving=settingsQueue.then(async()=>{
    try{
      await chrome.storage.local.set(patch);Object.assign(confirmedSettings,patch);
      setSettingsError('');$('saveStatus').textContent='설정 저장됨';
    }catch(error){
      setSettingsError('설정을 저장하지 못했어요. 마지막 확인값으로 복원합니다. 다시 조절해 주세요. '+error.message);
      $('saveStatus').textContent='저장 실패 · 다시 시도해 주세요';throw error;
    }finally{
      settingsPending--;
      if(!settingsPending)applySettings(confirmedSettings);
    }
  });
  settingsQueue=saving.catch(()=>{});
  return saving;
}
function save(patch) { return patchSettings(patch).catch(()=>{}); }
function scheduleRefresh() {
  clearTimeout(refreshTimer);
  refreshTimer=setTimeout(()=>{if(!busy&&!desktopPending&&!stopPending)refreshStatus();},100);
}
async function refreshStatus() {
  try{await loadStatus();if(errorSource==='status')setError('');}catch(error){
    $('statusLabel').textContent='연결 상태 확인 불가';
    $('desktopStatus').textContent='Chrome 송신: 상태 확인 불가 · 다시 검사해 주세요.';
    $('captureBtn').disabled=true;$('stopBtn').hidden=false;$('stopBtn').disabled=stopPending;$('stopBtn').textContent='취소·해제';
    $('desktopEnabled').disabled=true;$('desktopVideoEnabled').disabled=true;
    $('pairState').textContent='상태 미확인';
    $('captureHelp').textContent='자동으로 다시 확인합니다. 연결 설정의 다시 검사로도 확인할 수 있어요.';
    setError(error.message,'status');
  }
}
function watchStatus() {
  const storageChanged=(changes,area)=>{
    if(area==='local'){
      for(const key of Object.keys(DEFAULTS))if(Object.hasOwn(changes,key))confirmedSettings[key]=changes[key].newValue??DEFAULTS[key];
      if(!settingsPending)applySettings(confirmedSettings);
    }
    if(area==='local'||area==='session')scheduleRefresh();
  };
  const tabsChanged=()=>scheduleRefresh();
  chrome.storage.onChanged.addListener(storageChanged);
  chrome.tabs.onActivated.addListener(tabsChanged);chrome.tabs.onUpdated.addListener(tabsChanged);chrome.tabs.onRemoved.addListener(tabsChanged);
  pollTimer=setInterval(()=>{if(!document.hidden&&!busy&&!desktopPending&&!stopPending&&!statusLoading)refreshStatus();},2500);
  window.addEventListener('unload',()=>{
    clearInterval(pollTimer);clearTimeout(refreshTimer);
    chrome.storage.onChanged.removeListener(storageChanged);
    chrome.tabs.onActivated.removeListener(tabsChanged);chrome.tabs.onUpdated.removeListener(tabsChanged);chrome.tabs.onRemoved.removeListener(tabsChanged);
  },{once:true});
}
function inferPreset(settings) {
  return Object.entries(PRESETS).find(([,preset]) => Object.entries(preset).every(([key,value]) => settings[key] === value))?.[0] || null;
}
function setError(message, source='action') {
  errorSource=message?source:null;
  const humanMessage = message && /Receiving end does not exist|Could not establish connection/i.test(message)
    ? '탭 연결 메시지를 받을 수 없어요. 유튜브와 연결 대상 사이트를 새로고침하고 다시 연결해 주세요.'
    : message;
  $('errorBox').hidden = !humanMessage;
  $('errorBox').textContent = humanMessage || '';
}
function updateSourceNote(override) {
  if (override) { $('sourceNote').textContent = override; return; }
  const selected = document.querySelector('input[name="sourceMode"]:checked')?.value;
  if (!currentSession) {
    $('sourceNote').textContent = '미연결 상태: 웹 배경이 켜져 있으면 선택한 그라데이션을 보여줍니다.';
  } else if (!currentSession.cropFound) {
    $('sourceNote').textContent = '⚠️ 영상 위치를 감지하지 못했어요. 영역 새로고침을 눌러주세요.';
    $('connectionDetails').open=true;
  } else if (selected === 'glow') {
    $('sourceNote').textContent = '영상 영역 감지됨 · 중앙을 비우고 바깥에 영상 색감이 퍼집니다.';
  } else {
    $('sourceNote').textContent = '영상 영역 감지됨 · 중앙을 비우고 바깥에 플레이어 영상만 표시합니다.';
  }
}
// Separate from capture/status polling: a missing capture or send OFF cannot block control.
let desktopControlView=null,desktopControlBusy=false,desktopControlSequence=0;
const desktopControlMessages={
  nativeUnavailable:'Chrome 연결 등록·현재 폴더 권한을 확인해 주세요.',bridgeUnavailable:'Desktop 수신기가 없습니다. Windows 앱을 확인해 주세요.',pairingRequired:'기존 Desktop 페어링 코드를 먼저 저장해 주세요.',pairingRejected:'페어링 인증 실패 · 코드를 다시 확인해 주세요.',
  unsupported:'이 Bridge는 프로필 제어를 지원하지 않아요. Desktop을 업데이트해 주세요.',
  leaseConflict:'다른 Chrome 프로필이 제어 중입니다. 해당 프로필을 닫고 제어권 만료 후 다시 확인해 주세요.',
  leaseExpired:'제어권이 만료됐어요. 상태를 다시 확인해 주세요.',
  conflict:'다른 조작으로 상태가 바뀌었어요. 최신 상태를 확인하고 다시 눌러 주세요.',
  instanceChanged:'Desktop이 다시 시작됐어요. 최신 상태를 확인하고 다시 조작해 주세요.',
  saveFailed:'Desktop 저장 실패 · 현재 상태를 확인하세요. 일시정지는 미저장 적용될 수 있고, 재개는 이전 상태를 유지합니다.',
  checkpointFailed:'Chrome 제어 상태 저장 실패 · 적용 여부를 다시 확인해 주세요.',
  expired:'요청이 만료됐어요. 최신 상태를 확인하고 다시 조작해 주세요.',
  busy:'Desktop이 다른 요청을 처리 중입니다. 상태를 다시 확인해 주세요.',
  accepted:'접수됨 · Desktop 적용 확인 중…',requesting:'요청 중 · Desktop 적용 확인 중…',
  unconfirmed:'적용 여부 미확인 · 조회로 다시 확인합니다. 자동으로 재전송하거나 반대 명령을 보내지 않습니다.',
  resultUnknown:'이전 요청 결과 미확인 · 아래 상태는 새 조회값입니다. 필요하면 다시 조작해 주세요.',
  timeout:'Desktop 응답 시간 초과 · 적용 여부 미확인. 상태를 다시 확인해 주세요.'
};
function renderDesktopControl(view){
  desktopControlView=view;
  const state=view?.state,button=$('desktopPause');
  button.disabled=desktopControlBusy||!view?.canSet||!view?.fresh;
  button.textContent=state?.globalPaused?'통합 효과 재개':'통합 효과 일시정지';
  const confirmed=state?`${state.globalPaused?'일시정지':'재개'} 상태${state.persisted?' · 저장됨':' · 저장 안 됨'}`:'확인값 없음';
  const note=desktopControlMessages[view?.notice]||(view?.notice&&view.notice!=='applied'?'Desktop 상태 미확인 · 앱과 연결을 확인해 주세요.':'');
  $('desktopControlStatus').textContent=`Desktop 제어: ${view?.fresh?'':'마지막 확인값 / '}${confirmed}${note?' · '+note:''}`;
  const integration=view?.integration,parts=integration?.parts||{};
  const phase=state?.globalPaused?'일시정지':'재개';
  const status=!view?.fresh?'error':state?.persisted===false?'saveFailed':view?.pending||['requesting','accepted'].includes(view?.notice)?'waiting':integration?.status||'waiting';
  $('integrationStatus').textContent=({complete:`전체 ${phase} 적용 완료`,partial:'일부 적용 · 나머지 확인 중',waiting:'적용 확인 중…',error:'통신 오류 · 전체 적용 여부 미확인',saveFailed:'저장 실패 · 현재 상태 확인 필요'})[status]||'적용 상태 미확인';
  const describe=(part,none)=>({applied:`${phase} 적용 확인`,off:'사용자 설정 OFF · 유지됨',notRequired:none,waiting:'상태 미확인 · 확인 대기'})[part]||'상태 미확인 · 확인 대기';
  $('webControlStatus').textContent='웹 배경: '+describe(parts.web,'열린 지원 탭 없음');
  $('youtubeControlStatus').textContent='YouTube 조명: '+describe(parts.youtube,'열린 YouTube 탭 없음')+
    (!view?.youtube&&view?.web?.ready?' · DEV 확장과 YouTube 페이지를 새로고침해 주세요.':'');
  $('captureControlStatus').textContent='캡처 처리: '+describe(parts.capture,'캡처 연결 없음');
  $('desktopDisplayStatus').textContent=state?`Desktop 설정: 전체 ${state.desktopOutput.enabled?'ON':'OFF'} · RGB ${state.desktopOutput.rgbEnabled?'ON':'OFF'} · 영상 ${state.desktopOutput.videoEnabled?'ON':'OFF'}. 실제 창 표시는 대상 앱·수신 상태에 따라 달라집니다.`:'Desktop 표시: 상태 미확인 · Windows 트레이에서도 확인할 수 있어요.';
}
async function refreshDesktopControl(){
  if(desktopControlBusy)return;
  const sequence=++desktopControlSequence;
  try{
    const reply=await send({type:'AW_DESKTOP_CONTROL_QUERY'});
    if(sequence===desktopControlSequence)renderDesktopControl(reply.control);
  }catch{
    if(sequence===desktopControlSequence)renderDesktopControl({...desktopControlView,fresh:false,canSet:false,notice:'unavailable'});
  }
}
async function changeDesktopPause(){
  const view=desktopControlView;
  if(desktopControlBusy||!view?.canSet||!view.fresh)return;
  desktopControlBusy=true;desktopControlSequence++;
  renderDesktopControl({...view,canSet:false,notice:'requesting'});
  try{
    const reply=await send({type:'AW_DESKTOP_CONTROL_SET',paused:!view.state.globalPaused,instanceId:view.state.instanceId,revision:view.state.revision});
    desktopControlBusy=false;renderDesktopControl(reply.control);
  }catch{
    desktopControlBusy=false;renderDesktopControl({...view,fresh:false,canSet:false,notice:'unconfirmed'});
  }
}
function startDesktopControlUI(){
  $('desktopPause').addEventListener('click',changeDesktopPause);
  $('desktopControlRefresh').addEventListener('click',refreshDesktopControl);
  let querying=false;
  const poll=async()=>{if(querying||document.hidden||desktopControlBusy)return;querying=true;try{await refreshDesktopControl();}finally{querying=false;}};
  const timer=setInterval(poll,1000);
  window.addEventListener('unload',()=>{clearInterval(timer);desktopControlSequence++;},{once:true});
  poll();
}
async function send(message) {
  const response=await chrome.runtime.sendMessage(message);
  if (!response?.ok) {const error=new Error(response?.error || '작업을 완료할 수 없어요.');if(response?.cancelled)error.name='AbortError';throw error;}
  return response;
}
function renderDesktopControls() {
  $('desktopEnabled').checked=desktopView.enabled;
  $('desktopVideoEnabled').checked=desktopView.videoEnabled;
  $('desktopEnabled').disabled=desktopPending||!desktopView.paired;
  $('desktopVideoEnabled').disabled=desktopPending||!desktopView.paired||!desktopView.enabled;
  $('desktopPair').disabled=desktopPending;
  $('desktopPing').disabled=desktopPending;
  $('desktopForget').disabled=desktopPending||!desktopView.paired;
  $('pairState').textContent=desktopView.paired?'코드 저장됨':'페어링 필요';
  $('openPairing').hidden=desktopView.paired;
  if(desktopPending)$('desktopStatus').textContent='Chrome 송신: 설정 변경 중…';
}
async function changeDesktopOutput(work) {
  if(desktopPending)return;
  desktopPending=true;renderDesktopControls();
  try{await work();setError('');}catch(e){setError(e.message);}
  finally{
    desktopPending=false;
    try{await loadStatus();}catch(e){
      renderDesktopControls();
      $('desktopStatus').textContent='Chrome 송신: 상태 확인 불가 · 다시 검사해 주세요.';
      setError(e.message);
    }
  }
}
async function loadStatus() {
  const sequence=++statusSequence;statusLoading=true;
  try{
  const [{session,captureStats,desktop},[active]]=await Promise.all([
    send({type:'AW_GET_STATUS'}), chrome.tabs.query({active:true,currentWindow:true})
  ]);
  const videoPreference=await chrome.storage.local.get('desktopVideoEnabled');
  if(sequence!==statusSequence)return;
  currentSession=session || null;
  syncYoutubeAmbient($('youtubeAmbientEnabled').checked);
  activeTabInfo=active || null;
  await loadTargets();
  if(sequence!==statusSequence)return;
  const isYoutube=/^https:\/\/(?:www\.)?youtube\.com\//i.test(active?.url||'');
  $('captureBtn').disabled=!isYoutube||busy||stopPending||demoPending;
  $('captureBtn').hidden=Boolean(session)&&!busy;
  $('refreshCrop').disabled=!session||busy||stopPending;
  $('stopBtn').hidden=!session&&!busy;
  $('stopBtn').textContent=stopPending?'연결 정리 중…':busy?'연결 취소':'연결 해제';
  $('stopBtn').disabled=stopPending;
  $('statusLabel').textContent=busy?'YouTube 연결 중…':session?'YouTube 연결됨':'YouTube 미연결';
  $('sessionSummary').textContent=session?`현재 웹 ${session.targetTabIds?.length||0}개 탭 · Windows 송신 ${desktop?.enabled?'허용':'꺼짐'} · YouTube ${session.youtubeVisible?'표시 대상':'숨김/비활성'}`:'';
  desktopView={paired:Boolean(desktop?.paired),enabled:Boolean(desktop?.enabled),videoEnabled:Boolean(videoPreference.desktopVideoEnabled)};
  renderDesktopControls();
  const bridge=desktop?.runtime;
  $('desktopStatus').textContent=desktopPending?'Chrome 송신: 설정 변경 중…':!desktop?.paired?'Chrome 송신: 페어링 필요 · 먼저 코드를 저장해 주세요.':!desktop.enabled?'Chrome 송신: 꺼짐 · RGB와 영상 모두 중단':!session?'Chrome 송신: YouTube 연결 대기':bridge?.online?`Chrome 송신: Bridge 응답 확인 · 누적 색상 ${bridge.packets}회 / 영상 ${bridge.videoFrames||0}프레임 · 영상 추가 전송 ${desktopView.videoEnabled?'허용':'꺼짐'}${bridge.experimentalFps?` · 실험 ${bridge.experimentalFps}FPS`:''}`:(bridge?.error?`Chrome 송신: 연결 재시도 중 · ${bridge.error}`:'Chrome 송신: 캡처 연결됨 · Bridge 응답 대기');
  $('captureHelp').textContent=session?'대상 변경은 연결 해제 후 다시 연결하세요.'
    :(isYoutube?'연결하면 웹 배경도 켜집니다.':'이 탭에서는 연결을 시작할 수 없어요. YouTube 탭을 열어 주세요.');
  if(session?.targetTabIds?.length){
    try {const stats=await chrome.tabs.sendMessage(session.targetTabIds[0],{type:'AW_PERF_STATS'});
      if(sequence!==statusSequence)return;
      const transmitted=captureStats?.encodedBytes!=null ? ` · 누적 압축 영상 ${(captureStats.encodedBytes/1048576).toFixed(1)}MB` : '';
      const capture=captureStats ? ` · 영상 ${captureStats.sentFrames}프레임 / 색상 ${captureStats.sentColors}회${transmitted}` : '';
      $('perfNote').textContent=`수신 캔버스 ${stats.canvas.width}×${stats.canvas.height} · 평균 그리기 ${stats.averageDrawMs}ms${capture}`;
    } catch {$('perfNote').textContent='성능 측정: 수신 탭에 연결한 뒤 확인할 수 있어요.';}
  } else $('perfNote').textContent=session?.sourceTabId?(desktop?.enabled?'Desktop / YouTube 연결 · 웹 수신 탭 없음':'YouTube 조명 연결 · 웹 수신 탭 없음'):'';
  updateSourceNote();
  }finally{if(sequence===statusSequence)statusLoading=false;}
}
function updateLabels() {
  for (const field of fields) $(field+'Value').textContent=$(field).value+(field==='motionSpeed'?'초 / 방향':suffixes[field]);
  $('toggleText').textContent=$('enabled').checked?'켜짐':'꺼짐';
}
function updatePresetUI() {
  document.querySelectorAll('[data-preset]').forEach(button=>{
    const selected=button.dataset.preset===selectedPreset;
    button.classList.toggle('selected',selected);button.setAttribute('aria-pressed',String(selected));
  });
  $('presetStatus').textContent=({focus:'집중',balanced:'균형',immersive:'몰입'})[selectedPreset]||'직접 조절';
}
function updatePaletteUI(selected) {
  document.querySelectorAll('[data-palette]').forEach(btn=>{
    const active=btn.dataset.palette===selected;
    btn.classList.toggle('selected',active);
    btn.setAttribute('aria-pressed',String(active));
  });
}
function fillForm(values) {
  for(const field of fields) $(field).value=values[field] ?? DEFAULTS[field];
  $('enabled').checked=values.enabled;
  $('protectCenter').checked=values.protectCenter;
  $('fps').value=String([2,5,10].includes(Number(values.fps))?values.fps:5);
  $('motion').value=['vertical','horizontal','drift','none'].includes(values.motion)?values.motion:'vertical';
  const radio=document.querySelector(`input[name="sourceMode"][value="${values.sourceMode}"]`);
  (radio||document.querySelector('input[name="sourceMode"][value="video"]')).checked=true;
  updatePaletteUI(values.palette || 'twilight');
  updateLabels();
  updateSourceNote();
}
function setupNativeConnection(){
  const profileErrors={profileBusy:'다른 백업 작업이 진행 중이에요.',profileStopCapture:'YouTube 연결을 해제하고 다시 시도하세요.',profileConfirmationRequired:'백업을 선택하고 변경 확인에 체크하세요.',profileBackupFailed:'현재 설정 백업을 확인하지 못해 복원하지 않았습니다.',profileInvalid:'선택한 백업을 확인하지 못했습니다.',profileRecoveryRequired:'복원과 되돌리기를 확인하지 못했습니다. Chrome을 종료하고 개인 백업을 보존해 주세요.',profileImportFailedRestored:'복원에 실패해 변경한 설정을 이전 값으로 되돌렸습니다.',profileNativeUnavailable:'개인 Host·백업 접근을 확인하지 못했습니다. 연결 등록과 폴더 권한을 확인하세요.'};
  let profilePending=false;
  const profileAction=async operation=>{
    if(profilePending)return;profilePending=true;
    for(const id of ['nativeBackupList','nativeBackupExport','nativeBackupImport'])$(id).disabled=true;
    $('nativeBackupStatus').textContent='개인 백업 확인 중…';
    try{
      const reply=await chrome.runtime.sendMessage({type:'AW_NATIVE_PROFILE_'+operation,backupId:$('nativeBackupSelect').value,confirmed:$('nativeBackupConfirm').checked});
      if(reply?.ok!==true)throw Error(reply?.error||'profileNativeUnavailable');
      if(operation==='LIST'){
        $('nativeBackupSelect').replaceChildren();
        for(const item of reply.backups||[]){const option=document.createElement('option');option.value=item.backupId;option.textContent=`${item.utc} · ${item.fieldCount}개 항목${item.hasPairing?' · 코드 포함':''}`;$('nativeBackupSelect').append(option);}
        $('nativeBackupStatus').textContent=(reply.backups||[]).length?'백업을 선택하고 변경 확인에 체크한 뒤 복원하세요.':'개인 백업이 없습니다. Desktop에서 이전 설정 준비를 완료하세요.';
      }else if(operation==='IMPORT'){
        $('nativeBackupConfirm').checked=false;
        $('nativeBackupStatus').textContent='설정과 기존 코드를 복원했습니다. 팝업을 닫았다 다시 열고 연결을 확인하세요.';
      }else $('nativeBackupStatus').textContent='현재 설정을 개인 폴더에 백업했습니다. 백업 목록에서 확인할 수 있습니다.';
    }catch(error){$('nativeBackupStatus').textContent=profileErrors[error.message]||profileErrors.profileNativeUnavailable;}
    finally{profilePending=false;for(const id of ['nativeBackupList','nativeBackupExport','nativeBackupImport'])$(id).disabled=false;}
  };
  for(const [id,operation] of [['nativeBackupList','LIST'],['nativeBackupExport','EXPORT'],['nativeBackupImport','IMPORT']])$(id).addEventListener('click',()=>profileAction(operation));
  $('nativeExtensionId').value=chrome.runtime.id;
  $('nativeCopyId').addEventListener('click',async()=>{
    try{await navigator.clipboard.writeText(chrome.runtime.id);$('nativeStatus').textContent='등록용 ID를 복사했습니다. Desktop의 Chrome 연결 등록 창에 붙여넣으세요.';}
    catch{$('nativeExtensionId').focus();$('nativeExtensionId').select();$('nativeStatus').textContent='복사하지 못했습니다. 위 ID를 직접 복사하세요.';}
  });
  $('nativeCheck').addEventListener('click',async()=>{
    $('nativeCheck').disabled=true;
    try{
      const reply=await chrome.runtime.sendMessage({type:'AW_NATIVE_STATUS'});
      $('nativeStatus').textContent=reply?.ok===true&&reply.native?.transport==='native'
        ? reply.native.bridgeAvailable?'등록된 Host와 Desktop 수신기를 확인했습니다. 기존 페어링 코드로 연결하세요.':'등록된 Host를 확인했습니다. Desktop 앱을 먼저 실행하세요.'
        :'Host 연결을 확인하지 못했습니다. Desktop의 Chrome 연결 등록 창에서 현재 ID·등록 경로·권한을 확인하세요.';
    }catch{$('nativeStatus').textContent='Host 연결을 확인하지 못했습니다. 현재 사용자 등록과 폴더 권한을 확인하세요.';}
    finally{$('nativeCheck').disabled=false;}
  });
}
async function init() {
  setupNativeConnection();
  initTabs();
  // Register connection/cancel before awaiting status: a reopened popup can cancel a pending capture.
  $('captureBtn').addEventListener('click',async()=>{
    if(busy||stopPending||demoPending)return;
    busy=true;setError('');$('captureBtn').disabled=true;$('stopBtn').hidden=false;
    $('stopBtn').textContent='연결 취소';$('statusLabel').textContent='YouTube 연결 중…';
    const before=$('captureBtn').innerHTML;
    $('captureBtn').textContent='연결 중…';
    try {
      const targetId=$('targetTab').value;
      const result=await send({type:'AW_START_CAPTURE',...(targetId==='all'?{scope:'all'}:targetId==='desktop'?{scope:'desktop'}:targetId==='youtube'?{scope:'youtube'}:targetId==='auto'?{scope:'recent'}:{targetTabId:Number(targetId)})});
      if(result.desktopWarning)setError(result.desktopWarning);
      if(result.connectedCount<result.requestedCount)setError(`${result.requestedCount}개 중 ${result.connectedCount}개 연결됨. 나머지 사이트를 새로고침하고 다시 시도해 주세요.`);
      confirmedSettings.enabled=true;$('enabled').checked=true;updateLabels();
    }catch(e){if(e.name!=='AbortError')setError(e.message);}
    finally{busy=false;$('captureBtn').innerHTML=before;await refreshStatus();}
  });
  $('demoBtn').addEventListener('click',async()=>{
    if(busy||stopPending||demoPending)return;
    demoPending=true;setError('');$('demoBtn').disabled=true;$('captureBtn').disabled=true;
    try {
      await send({type:'AW_STOP_CAPTURE'});
      await patchSettings({enabled:true,mode:'demo'});
      await loadStatus();
      const chosen=targetOptions.find(t=>String(t.id)===$('targetTab').value);
      const origin=activeTabInfo&&siteFromUrl(activeTabInfo.url)?activeTabInfo:null;
      const tabs=await chrome.tabs.query({url:SITE_URLS});
      const dest=chosen||origin||tabs.find(t=>sitesEnabled[siteFromUrl(t.url)]!==false);
      if(dest)await chrome.tabs.update(dest.id,{active:true});
      else await chrome.tabs.create({url:'https://chatgpt.com/'});
    }catch(e){setError(e.message);}
    finally{demoPending=false;$('demoBtn').disabled=false;await refreshStatus();}
  });
  $('stopBtn').addEventListener('click',async()=>{
    if(stopPending)return;
    stopPending=true;setError('');$('stopBtn').disabled=true;$('stopBtn').textContent='연결 정리 중…';
    try{const result=await send({type:'AW_STOP_CAPTURE'});if(result.cleanupPending)setError('연결을 중지했어요. 일부 정리 응답을 기다리고 있으니 캡처 표시가 남는지 확인해 주세요.');}
    catch(e){setError(e.message);}
    finally{stopPending=false;await refreshStatus();}
  });
  $('refreshCrop').addEventListener('click',async()=>{
    setError('');$('refreshCrop').disabled=true;
    try {
      const result=await send({type:'AW_REFRESH_CROP'});
      if(currentSession)currentSession.cropFound=result.cropFound;
      updateSourceNote(result.cropFound?'영상 영역을 갱신했어요.':'영상 위치를 찾지 못했어요. YouTube 탭을 새로고침해 주세요.');
      if(!result.cropFound)$('connectionDetails').open=true;
    }catch(e){setError(e.message);}
    finally{$('refreshCrop').disabled=!currentSession;}
  });
  const pairAction=async(type)=>{
    if(desktopPending)return;
    desktopPending=true;renderDesktopControls();setPairError('');$('pairStatus').textContent='연결 처리 중…';
    try{
      await send({type,...(type==='AW_DESKTOP_PAIR'?{token:$('desktopCode').value.trim()}:{})});
      $('desktopCode').value='';
      $('pairStatus').textContent=type==='AW_DESKTOP_FORGET'?'Chrome 페어링을 해제했어요.':type==='AW_DESKTOP_PAIR'?'페어링 완료 · Windows 전송 켜짐':'Desktop 연결 응답을 확인했어요.';
    }catch(e){setPairError(e.message);$('pairStatus').textContent='연결 처리 실패 · 입력 코드와 Desktop 앱을 확인해 주세요.';}
    finally{desktopPending=false;await refreshStatus();}
  };
  $('desktopPair').addEventListener('click',()=>pairAction('AW_DESKTOP_PAIR'));
  $('desktopPing').addEventListener('click',()=>pairAction('AW_DESKTOP_PING'));
  $('desktopForget').addEventListener('click',()=>pairAction('AW_DESKTOP_FORGET'));
  $('desktopCode').addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();pairAction('AW_DESKTOP_PAIR');}});
  $('desktopVideoEnabled').addEventListener('change',async()=>{
    if($('desktopVideoEnabled').disabled)return;
    const enabled=$('desktopVideoEnabled').checked;
    await changeDesktopOutput(()=>chrome.storage.local.set({desktopVideoEnabled:enabled}));
  });
  $('desktopEnabled').addEventListener('change',async()=>{
    if($('desktopEnabled').disabled)return;
    const enabled=$('desktopEnabled').checked;
    await changeDesktopOutput(()=>send({type:'AW_DESKTOP_TOGGLE',enabled}));
  });
  document.querySelectorAll('[data-site]').forEach(input=>input.addEventListener('change',async()=>{
    sitesEnabled={...sitesEnabled,[input.dataset.site]:input.checked};
    await save({sitesEnabled});scheduleRefresh();
  }));
  document.querySelectorAll('[data-power]').forEach(button=>button.addEventListener('click',async()=>{
    setPower(button.dataset.power);await save({performanceMode:button.dataset.power});scheduleRefresh();
  }));
  fields.forEach(field=>$(field).addEventListener('input',()=>{
    updateLabels();save({[field]:Number($(field).value)});
  }));
  $('enabled').addEventListener('change',()=>{updateLabels();save({enabled:$('enabled').checked});});
  $('protectCenter').addEventListener('change',()=>save({protectCenter:$('protectCenter').checked}));
  $('fps').addEventListener('change',()=>save({fps:Number($('fps').value)}));
  $('motion').addEventListener('change',()=>save({motion:$('motion').value}));
  document.querySelectorAll('[data-palette]').forEach(button=>button.addEventListener('click',()=>{
    updatePaletteUI(button.dataset.palette);save({palette:button.dataset.palette});
  }));
  document.querySelectorAll('input[name="sourceMode"]').forEach(radio=>radio.addEventListener('change',()=>{
    updateSourceNote();save({sourceMode:radio.value});
  }));
  document.querySelectorAll('[data-preset]').forEach(button=>button.addEventListener('click',()=>save(PRESETS[button.dataset.preset])));
  $('youtubeAmbientEnabled').addEventListener('change',()=>changeYoutubeAmbient($('youtubeAmbientEnabled').checked));
  $('youtubeAmbientToggle').addEventListener('click',()=>changeYoutubeAmbient(!$('youtubeAmbientEnabled').checked));
  $('youtubeAmbientFps').addEventListener('change',()=>save({youtubeAmbientFps:Number($('youtubeAmbientFps').value)}));
  for(const [field,suffix] of Object.entries(ytFields)){
    $(field).addEventListener('input',()=>{
      const value=Number($(field).value);$(field+'Value').textContent=value+suffix;save({[field]:value});
    });
  }
  document.querySelectorAll('[data-yt-light]').forEach(button=>button.addEventListener('click',()=>save(YT_LIGHT_PRESETS[button.dataset.ytLight])));
  // Existing compatibility migrations, with the original keys and defaults.
  const values=await chrome.storage.local.get(DEFAULTS);
  confirmedSettings={...DEFAULTS,...values};
  if(![2,5,10].includes(Number(values.fps))){values.fps=5;await patchSettings({fps:5});}
  if(values.sourceMode==='tab'){values.sourceMode='video';await patchSettings({sourceMode:'video'});}
  applySettings(confirmedSettings);
  $('settingsControls').disabled=false;$('saveStatus').textContent='저장된 설정 반영됨';
  watchStatus();
  startDesktopControlUI();
  await refreshStatus();
}
init().catch(error=>{setSettingsError('저장된 설정을 불러오지 못했어요. 팝업을 다시 열어 주세요. '+error.message);$('saveStatus').textContent='설정 불러오기 실패';});
