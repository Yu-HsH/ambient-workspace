const text={waiting:'저장 시작을 기다리고 있습니다.',saving:'개인 백업을 저장하고 있습니다.',saved:'저장 완료. 별도 Chrome을 종료하고 Desktop 이전 창에서 백업을 확인하세요.',empty:'복사본에 설정이 없습니다. 예전 확장 ID와 Chrome 프로필 경로를 확인하세요.',failed:'저장을 확인하지 못했습니다. 임시 등록·폴더 권한을 확인하고 다시 저장하세요.'};
async function refresh(type='status'){
  try{const reply=await chrome.runtime.sendMessage({type});document.getElementById('status').textContent=text[reply?.status]||text.failed;document.getElementById('retry').disabled=reply?.status==='saving';}
  catch{document.getElementById('status').textContent=text.failed;}
}
document.getElementById('retry').addEventListener('click',()=>refresh('retry'));
refresh();setInterval(refresh,1000);
