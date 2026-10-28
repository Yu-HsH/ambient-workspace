// Trusted worker flow. Registration stays in the consent-driven Windows UI.
(() => {
  const describe = code => ({
    hostNotRegistered:'Windows 연결 경로가 등록되지 않았습니다. 설치 폴더의 Setup-Chrome.bat 또는 Desktop 설정 → 연결 → Chrome 연결 등록에서 직접 등록한 뒤 다시 연결하세요.',
    hostForbidden:'현재 확장 ID의 Host 접근이 허용되지 않습니다. Desktop의 Chrome 연결 등록에서 아래 공개 ID를 확인하세요.',
    hostStartFailed:'등록된 Host를 시작하지 못했습니다. 설치 폴더의 위치·파일·권한을 확인한 뒤 승인하여 재등록하세요.',
    desktopNotRunning:'Host 등록은 확인했습니다. 등록한 폴더의 Start.bat으로 Desktop을 실행한 뒤 다시 연결하세요.',
    pairingRequired:'Host와 Desktop을 확인했습니다. 처음 연결할 때만 Desktop 설정 → 연결에서 기존 페어링 코드를 복사해 입력하세요.',
    pairingRejected:'Desktop 코드로 인증하지 못했습니다. 실행 중인 Desktop의 기존 코드를 확인하세요. 설정이나 키를 초기화할 필요는 없습니다.',
    timeout:'연결 응답 시간이 초과되었습니다. Desktop이 응답하는지 확인하고 다시 연결하세요.',
    bridgeUnavailable:'Host는 응답했지만 Desktop 수신기에 연결하지 못했습니다. 등록한 폴더의 Desktop이 실행 중인지 확인하세요.',
    nativeUnavailable:'Host 연결을 확인하지 못했습니다. Desktop에서 등록 경로·권한을 확인하고 다시 연결하세요. 계속 실패하면 chrome://extensions에서 확장을 새로고침하세요.',
    busy:'다른 연결 작업이 진행 중입니다. 잠시 후 다시 연결하세요.'
  })[code] || 'Windows 연결 응답을 확인하지 못했습니다. 고급 진단에서 Host와 인증 상태를 확인하세요.';
  async function check(token) {
    const state={host:'unknown',desktop:'unknown',authentication:'unknown',code:'',message:''};
    try {
      const status=await AW_NATIVE.request({type:'native.status'});
      if(!status?.ok||status.transport!=='native'||typeof status.bridgeAvailable!=='boolean')throw Error('nativeUnavailable');
      state.host='registered';state.desktop=status.bridgeAvailable?'running':'stopped';
      if(!status.bridgeAvailable)throw Error('desktopNotRunning');
      if(!/^[a-f0-9]{64}$/.test(token||'')){state.authentication='required';throw Error('pairingRequired');}
      const reply=await AW_NATIVE.request({type:'ping',token});
      if(!reply?.ok)throw Error(reply?.status||'bridgeUnavailable');
      state.authentication='authenticated';
      return {ok:true,...state,message:'Windows 연결 완료 · 기존 인증을 사용합니다.'};
    } catch(error) {
      const code=Object.hasOwn({hostNotRegistered:1,hostForbidden:1,hostStartFailed:1,desktopNotRunning:1,pairingRequired:1,pairingRejected:1,timeout:1,bridgeUnavailable:1,nativeUnavailable:1,busy:1},error.message)?error.message:'nativeUnavailable';
      if(code==='hostNotRegistered')state.host='unregistered';
      if(code==='pairingRejected')state.authentication='rejected';
      return {ok:false,...state,code,message:describe(code)};
    }
  }
  globalThis.AW_WINDOWS=Object.freeze({check,describe});
})();
