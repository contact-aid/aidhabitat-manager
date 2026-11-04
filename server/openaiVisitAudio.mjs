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
    '-t',String(duration),'-vn','-ac','1','-ar','16000',...(reference?['-c:a','pcm_s16le']:['-c:a','libopus','-b:a','24k']),output],{timeout:180000,maxBuffer:10000});
  await fs.chmod(output,0o600);return fs.readFile(output);
}
export async function transcribeVisitParts({bytes,job,directory,model,apiKey,fetchImpl=fetch,onUsage=async()=>{},sliceAudio=slice}) {
  const duration=job.chunks.reduce((sum,c)=>sum+c.duration,0);
  const partSeconds=900;
  const count=Math.max(1,Math.ceil(duration/partSeconds));
  const source=path.join(directory,'diarization.webm');
  if(count>1) await fs.writeFile(source,bytes,{mode:0o600});
  const result=[];const references=new Map();let nextVoice=1;
  for(let index=0;index<count;index++) {
    const offset=index*partSeconds;
    const partDuration=Math.min(partSeconds,duration-offset);
    const filename=path.join(directory,`openai-audio-part-${index}.json`);
    let raw=await read(filename);
    if(!raw) {
      const audio=count===1?bytes:await sliceAudio({source,output:path.join(directory,`part-${index}.webm`),start:offset,duration:partDuration});
      if(audio.length>24*1024*1024) throw error('Un extrait dépasse la taille de transcription autorisée. Les sources sont conservées.');
      const form=new FormData();form.append('file',new Blob([audio],{type:'audio/webm'}),'visit.webm');
      for(const [k,v] of Object.entries({model,response_format:'diarized_json',chunking_strategy:'auto'}))form.append(k,v);
      for(const [name,file] of references) {
        form.append('known_speaker_names[]',name);
        form.append('known_speaker_references[]','data:audio/wav;base64,'+(await fs.readFile(file)).toString('base64'));
      }
      const response=await fetchImpl('https://api.openai.com/v1/audio/transcriptions',{
        method:'POST',headers:{Authorization:`Bearer ${apiKey}`},body:form,signal:AbortSignal.timeout(300000)});
      if(!response.ok) throw error('OpenAI n’a pas pu transcrire un extrait. Les fichiers audio et les extraits déjà traités sont conservés.');
      raw=await response.json();
      if(!Array.isArray(raw.segments)||raw.segments.some(s=>typeof s.text!=='string'||typeof s.speaker!=='string'||!s.speaker.trim()||
        !Number.isFinite(s.start)||!Number.isFinite(s.end)||s.start<0||s.end<s.start))throw error('La séparation des voix OpenAI est inexploitable.');
      await write(filename,raw);
      await Promise.resolve().then(()=>onUsage({task:'transcription',provider:'openai',model,recordingId:job.id,dossierId:job.dossierId,
        part:index,audioSeconds:partDuration,at:new Date().toISOString()})).catch(()=>{});
    }
    const aliases=new Map();
    for(const id of [...new Set(raw.segments.map(s=>s.speaker))]) {
      // Known reference labels are stable. Unmatched labels are kept separate,
      // never equated to an earlier A/B label solely because its spelling matches.
      const voice=references.has(id)?id:`voice_${nextVoice++}`;
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
  return {segments:result};
}
