// Static extension worker; uses Chromium's built-in JPEG encoder off the UI thread.
let busy=false;
self.onmessage=async event=>{
  const value=event.data,bitmap=value?.bitmap;
  if(busy||!value||!Number.isSafeInteger(value.id)||value.id<1||!(bitmap instanceof ImageBitmap)||
      !Number.isInteger(value.width)||value.width<1||value.width>480||!Number.isInteger(value.height)||value.height<1||value.height>270||
      bitmap.width!==value.width||bitmap.height!==value.height||!Number.isFinite(value.quality)||value.quality<0||value.quality>1){
    bitmap?.close?.();self.postMessage({id:value?.id,ok:false});return;
  }
  busy=true;
  try{
    const canvas=new OffscreenCanvas(value.width,value.height),context=canvas.getContext('2d',{alpha:false});
    context.drawImage(bitmap,0,0);bitmap.close();
    const blob=await canvas.convertToBlob({type:'image/jpeg',quality:value.quality});
    const buffer=await blob.arrayBuffer();
    if(blob.type!=='image/jpeg'||buffer.byteLength<1||buffer.byteLength>90000)throw Error('Invalid JPEG');
    self.postMessage({id:value.id,ok:true,buffer},[buffer]);
  }catch{bitmap.close();self.postMessage({id:value.id,ok:false});}
  finally{busy=false;}
};
