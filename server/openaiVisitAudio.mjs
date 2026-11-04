import fs from 'node:fs/promises';
import path from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const exec=promisify(execFile);
const error=message=>Object.assign(new Error(message),{statusCode:502});
const read=async filename=>{try{return JSON.parse(await fs.readFile(filename,'utf8'));}catch(e){if(e.code==='ENOENT')return null;throw e;}};
const write=async(filename,data)=>{await fs.writeFile(filename+'.tmp',JSON.stringify(data),{mode:0o600});await fs.rename(filename+'.tmp',filename);};
async function slice({source,output,start,duration,reference=false}) {
  await exec('ffmpeg',['-hide_banner','-loglevel','error','-y','-ss',String(start),'-i',source,
    '-t',String(duration),'-vn','-ac','1','-ar','16000',...(reference?['-c:a','pcm_s16le']:['-c:a','aac','-b:a','32k']),output],{timeout:180000,maxBuffer:10000});
  await fs.chmod(output,0o600);return fs.readFile(output);
}
export async function readDiarizedResponse(response) {
  if(!response.headers.get('content-type')?.includes('text/event-stream'))return response.json();
  const segments=[];const decoder=new TextDecoder();let pending='';let completed=false;let hasText=false;
  stream:for await(const bytes of response.body) {
    pending=(pending+decoder.decode(bytes,{stream:true})).replace(/\r\n/g,'\n');let boundary;
    while((boundary=pending.indexOf('\n\n'))>=0) {
      const frame=pending.slice(0,boundary);pending=pending.slice(boundary+2);
      const data=frame.split('\n').filter(l=>l.startsWith('data:')).map(l=>l.slice(5).trimStart()).join('\n');
      if(!data)continue;
      if(data.trim()==='[DONE]'){completed=true;break stream;}
      let event;try{event=JSON.parse(data);}catch{throw error('Le flux de transcription est illisible. Les sources sont conservées.');}
      const type=event.type||frame.split('\n').find(l=>l.startsWith('event:'))?.slice(6).trim();
      if(typeof event.text==='string'&&event.text.trim()||typeof event.delta==='string'&&event.delta.trim())hasText=true;
      if(type==='error'||event.error)throw error('OpenAI a interrompu la transcription. Les sources sont conservées.');
      if(type==='transcript.text.segment')segments.push(event.segment||event);
      if(type==='transcript.text.done') {
        if(Array.isArray(event.segments))return {segments:event.segments};
        completed=true;break stream;
      }
    }
  }
  if(completed&&hasText&&!segments.length)throw error('Les annotations de voix sont manquantes. La source audio est conservée.');
  if(!completed)throw error('Le flux de transcription est incomplet. Les sources sont conservées.');
  return {segments};
}
export async function transcribeVisitParts({bytes,job,directory,model,apiKey,fetchImpl=fetch,onUsage=async()=>{},sliceAudio=slice}) {
  const duration=job.chunks.reduce((sum,c)=>sum+c.duration,0);
  const partSeconds=300;
  const count=Math.max(1,Math.ceil(duration/partSeconds));
  const source=path.join(directory,'diarization.webm');
  if(count>1) await fs.writeFile(source,bytes,{mode:0o600});
  const result=[];const references=new Map();let nextVoice=1;
  async function requestPart(index, referenceSnapshot) {
    const offset=index*partSeconds;
    const partDuration=Math.min(partSeconds,duration-offset);
    const filename=path.join(directory,`openai-audio-300-part-${index}.json`);
    let raw=await read(filename);
    if(!raw) {
      const audio=count===1?bytes:await sliceAudio({source,output:path.join(directory,`part-${index}.m4a`),start:offset,duration:partDuration});
      if(audio.length>24*1024*1024) throw error('Un extrait dépasse la taille de transcription autorisée. Les sources sont conservées.');
      const form=new FormData();form.append('file',new Blob([audio],{type:count===1?'audio/webm':'audio/mp4'}),count===1?'visit.webm':'visit.m4a');
      for(const [k,v] of Object.entries({model,response_format:'diarized_json',chunking_strategy:'auto',stream:'true'}))form.append(k,v);
      for(const [name,file] of referenceSnapshot) {
        form.append('known_speaker_names[]',name);
        form.append('known_speaker_references[]','data:audio/wav;base64,'+(await fs.readFile(file)).toString('base64'));
      }
      const response=await fetchImpl('https://api.openai.com/v1/audio/transcriptions',{
        method:'POST',headers:{Authorization:`Bearer ${apiKey}`},body:form,signal:AbortSignal.timeout(600000)});
      if(!response.ok) throw error('OpenAI n’a pas pu transcrire un extrait. Les fichiers audio et les extraits déjà traités sont conservés.');
      raw=await readDiarizedResponse(response);
      if(!Array.isArray(raw.segments)||raw.segments.some(s=>typeof s.text!=='string'||typeof s.speaker!=='string'||!s.speaker.trim()||
        !Number.isFinite(s.start)||!Number.isFinite(s.end)||s.start<0||s.end<s.start))throw error('La séparation des voix OpenAI est inexploitable.');
      raw.referenceNames=[...referenceSnapshot.keys()];
      await write(filename,raw);
      await Promise.resolve().then(()=>onUsage({task:'transcription',provider:'openai',model,recordingId:job.id,dossierId:job.dossierId,
        part:index,audioSeconds:partDuration,at:new Date().toISOString()})).catch(()=>{});
    }
    return {raw,offset,index};
  }
  for(let batch=0;batch<count;) {
    const end=batch===0?1:Math.min(count,batch+3);
    const snapshot=new Map(references);
    const outcomes=await Promise.allSettled(Array.from({length:end-batch},(_,i)=>requestPart(batch+i,snapshot)));
    const failure=outcomes.find(r=>r.status==='rejected');if(failure)throw failure.reason;
    for(const outcome of outcomes) {
      const {raw,offset,index}=outcome.value;
    const aliases=new Map();
    for(const id of [...new Set(raw.segments.map(s=>s.speaker))]) {
      // Known reference labels are stable. Unmatched labels are kept separate,
      // never equated to an earlier A/B label solely because its spelling matches.
      const voice=(raw.referenceNames||[]).includes(id)?id:`voice_${nextVoice++}`;
      aliases.set(id,voice);
      if(index<count-1&&!references.has(voice)&&references.size<4) {
        const sample=raw.segments.filter(s=>s.speaker===id&&s.end-s.start>=2).sort((a,b)=>(b.end-b.start)-(a.end-a.start))[0];
        if(sample) {
          const file=path.join(directory,`${voice}-reference.wav`);
          await sliceAudio({source,output:file,start:offset+sample.start,duration:Math.min(8,sample.end-sample.start),reference:true});
          references.set(voice,file);
        }
      }
    }
    result.push(...raw.segments.map(s=>({...s,speaker:aliases.get(s.speaker),start:s.start+offset,end:s.end+offset})));
    }
    batch=end;
  }
  return {segments:result};
}
