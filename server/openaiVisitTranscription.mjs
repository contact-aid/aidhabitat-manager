import { cleanVisitTranscript } from './openaiVisitCleanup.mjs';
import { transcribeVisitParts } from './openaiVisitAudio.mjs';
import { textProviderConfig } from './ai/provider.mjs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);
const fail = message => Object.assign(new Error(message), {statusCode:502});
const readJson = async filename => {
  try {return JSON.parse(await fs.readFile(filename,'utf8'));}
  catch(error) {if(error.code==='ENOENT') return null; throw error;}
};
async function checkpoint(filename, value) {
  const temporary = `${filename}.tmp`;
  await fs.writeFile(temporary,JSON.stringify(value),{mode:0o600});
  await fs.rename(temporary,filename);
}
export async function prepareVisitAudio({job,directory}) {
  // Stable numeric filenames only; all originals remain untouched.
  const list=path.join(directory,'audio-concat.txt');
  await fs.writeFile(list,job.chunks.map((_,i)=>`file '${i}.m4a'`).join('\n'),{mode:0o600});
  const output=path.join(directory,'diarization.webm');
  try {
    await run('ffmpeg',['-hide_banner','-loglevel','error','-y','-f','concat','-safe','1','-i',list,
      '-vn','-ac','1','-ar','16000','-c:a','libopus','-b:a','24k',output],{timeout:180000,maxBuffer:10000});
    await fs.chmod(output,0o600);
    const bytes=await fs.readFile(output);
    return bytes;
  } catch(error) {
    if(error.statusCode) throw error;
    throw fail('La préparation audio a échoué. Les fichiers originaux sont conservés.');
  }
}
export function createOpenAIRecordingTranscriber({env,fetchImpl=fetch,complete,onUsage=async()=>{},prepareAudio=prepareVisitAudio}) {
  return async ({job,directory}) => {
    const apiKey=textProviderConfig(env).apiKey;
    if(!apiKey) throw fail('La clé OpenAI de transcription n’est pas configurée.');
    const model=env.OPENAI_VISIT_TRANSCRIPTION_MODEL || 'gpt-4o-transcribe-diarize';
    // This specialized capability currently has no non-deprecated replacement.
    // Keep the model configurable; fail closed when the announced sunset arrives.
    if(model==='gpt-4o-transcribe-diarize' && Date.now()>=Date.parse('2027-02-26T00:00:00Z')) {
      throw fail('Le modèle de séparation des voix doit être mis à jour. Les sources sont conservées.');
    }
    const rawFile=path.join(directory,'openai-transcript-raw.json');
    let raw=await readJson(rawFile);
    if(!raw) {
      const bytes=await prepareAudio({job,directory});
      raw=await transcribeVisitParts({bytes,job,directory,model,apiKey,fetchImpl,onUsage});
      await checkpoint(rawFile,raw);

    }
    const speakers=[...new Set(raw.segments.map(s=>s.speaker))];
    const cleanedFile=path.join(directory,'openai-transcript-clean.json');
    let cleaned=await readJson(cleanedFile);
    if(!cleaned && raw.segments.length) {
      cleaned=await cleanVisitTranscript({segments:raw.segments,directory,complete});
      await checkpoint(cleanedFile,cleaned);
    }
    cleaned ??= {turns:[],speakers:[]};
    const texts=new Map(cleaned.turns.map(t=>[t.id,t.cleanText]));
    const roles=new Map(cleaned.speakers.map(s=>[s.id,s.role]));
    const labels=new Map();let participant=0;
    for(const speaker of speakers) {
      const role=roles.get(speaker)||'unknown';
      labels.set(speaker,role==='therapist' ? `${job.author||'Ergothérapeute'} · à confirmer` : `Interlocuteur ${++participant}`);
    }
    let start=0;
    return job.chunks.map((chunk,index)=>{
      const from=start;start+=chunk.duration;
      const turns=raw.segments.map((s,id)=>({...s,id})).filter(s=>s.start>=from && (s.start<start||index===job.chunks.length-1)).map(s=>({
        text:s.text,cleanText:texts.get(s.id)??s.text,speakerId:s.speaker,
        speakerName:labels.get(s.speaker),role:roles.get(s.speaker)==='therapist'?'therapist':'other',
        roleConfirmed:false,voice:'unknown',speakerNumber:speakers.indexOf(s.speaker)+1,
        startSeconds:s.start,endSeconds:s.end,
      }));
      return {index,startSeconds:from,text:turns.map(t=>t.text).join('\n'),turns};
    });
  };
}
