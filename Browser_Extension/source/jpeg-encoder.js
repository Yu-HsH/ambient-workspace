// Trusted offscreen document only. One private worker and one JPEG job at a time.
// No network, storage, token, or control state crosses this encoder boundary.
(() => {
  function create() {
    let worker=null,pending=null,serial=0;
    function finish(job,error,blob) {
      if(pending!==job)return;
      pending=null;clearTimeout(job.timer);
      error?job.reject(error):job.resolve(blob);
    }
    function close(reason='JPEG encoder stopped') {
      const previous=worker;worker=null;previous?.terminate();
      if(pending)finish(pending,Error(reason));
    }
    function connect() {
      if(worker)return worker;
      const current=new Worker(chrome.runtime.getURL('source/jpeg-worker.js'));worker=current;
      current.onmessage=event=>{
        if(current!==worker)return;
        const job=pending,value=event.data;
        if(!job||!value||value.id!==job.id||value.ok!==true||!(value.buffer instanceof ArrayBuffer)||value.buffer.byteLength<1||value.buffer.byteLength>90000){close('JPEG encoder returned invalid data');return;}
        finish(job,null,new Blob([value.buffer],{type:'image/jpeg'}));
      };
      current.onerror=()=>{if(current===worker)close('JPEG encoder unavailable');};
      current.onmessageerror=()=>{if(current===worker)close('JPEG encoder returned invalid data');};
      return current;
    }
    function encode(canvas,quality) {
      return new Promise((resolve,reject)=>{
        if(pending){reject(Error('JPEG encoder busy'));return;}
        const width=canvas.width,height=canvas.height;
        if(!Number.isInteger(width)||width<1||width>480||!Number.isInteger(height)||height<1||height>270||!Number.isFinite(quality)||quality<0||quality>1){reject(Error('Invalid JPEG dimensions or quality'));return;}
        let current;try{current=connect();}catch{reject(Error('JPEG encoder unavailable'));return;}
        const job={id:++serial,resolve,reject,timer:null};pending=job;
        job.timer=setTimeout(()=>{if(pending===job)close('JPEG encoder timed out');},1000);
        Promise.resolve().then(()=>createImageBitmap(canvas)).then(bitmap=>{
          if(pending!==job||worker!==current){bitmap.close();return;}
          try{current.postMessage({id:job.id,bitmap,width,height,quality},[bitmap]);}
          catch{bitmap.close();close('JPEG encoder unavailable');}
        },()=>{if(pending===job)close('JPEG snapshot unavailable');});
      });
    }
    return Object.freeze({encode,close});
  }
  globalThis.AW_JPEG_ENCODER=Object.freeze({create});
})();
