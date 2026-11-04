import {transcribeFrenchChunks,arrangeFrenchTranscript} from './openaiFrenchTranscript.mjs';
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
export function createOpenAIRecordingTranscriber({env,fetchImpl=fetch,complete,onUsage=async()=>{},prepareAudio=prepareVisitAudio,probeAudioDuration}) {
  return async ({job,directory}) => {
    const apiKey=textProviderConfig(env).apiKey;
    if(!apiKey) throw fail('La clé OpenAI de transcription n’est pas configurée.');
    const model=env.OPENAI_VISIT_TRANSCRIPTION_MODEL || 'gpt-4o-transcribe-diarize';
    // This specialized capability currently has no non-deprecated replacement.
    // Keep it configurable; French text remains usable if voice analysis fails.
    const voiceModelExpired=model==='gpt-4o-transcribe-diarize' && Date.now()>=Date.parse('2027-02-26T00:00:00Z');
    const french=await transcribeFrenchChunks({job,directory,apiKey,fetchImpl,onUsage,model:env.OPENAI_VISIT_TEXT_TRANSCRIPTION_MODEL||'gpt-transcribe'});
    const rawFile=path.join(directory,'openai-fr-v1-transcript-raw.json');
    let raw;
    try {
    if(voiceModelExpired)throw fail('Le modèle de repérage vocal est indisponible.');
    raw=await readJson(rawFile);
    if(!raw) {
      const bytes=await prepareAudio({job,directory});
      raw=await transcribeVisitParts({bytes,job,directory,model,apiKey,fetchImpl,onUsage,probeAudioDuration});
      await checkpoint(rawFile,raw);

    }
    } catch(error) {
      raw={segments:[],referenceVoices:[]};
      await Promise.resolve().then(()=>onUsage({task:'voice_analysis_unavailable',recordingId:job.id,dossierId:job.dossierId,at:new Date().toISOString()})).catch(()=>{});
    }
      let references=raw.referenceVoices;
      if(!references) {
        const names=new Set();
        for(const file of(await fs.readdir(directory)).filter(n=>/^openai-audio-fr-300-part-\d+\.json$/.test(n))) {
          for(const name of(await readJson(path.join(directory,file)))?.referenceNames||[])names.add(name);
        }
        references=[...names].slice(0,4);
      }
      if(!references.length) {
        const durations=new Map();
        for(const s of raw.segments)if(s.end-s.start>=2)durations.set(s.speaker,(durations.get(s.speaker)||0)+(s.end-s.start));
        references=[...durations].sort((a,b)=>b[1]-a[1]).slice(0,4).map(([id])=>id);
      }
      const arranged=await arrangeFrenchTranscript({chunks:french,voiceSegments:raw.segments,referenceVoices:references,directory,complete});
      return arranged.formatted.map(chunk=>({index:chunk.index,startSeconds:chunk.startSeconds,
        text:chunk.turns.map(t=>t.text).join('\n'),speakerAttribution:chunk.speakerAttribution,
        turns:chunk.turns.map(turn=>{
          const id=arranged.nextTurn();const role=turn.speaker?arranged.roles.get(turn.speaker):'unknown';
          return {text:turn.text,cleanText:arranged.cleanTexts.get(id)??turn.text,role:role||'unknown',voice:'unknown',roleConfirmed:false,
            ...(turn.speaker?{speakerId:turn.speaker,speakerNumber:references.indexOf(turn.speaker)+1,
              speakerName:role==='therapist'?`${job.author||'Ergothérapeute'} · à confirmer`:arranged.labels.get(turn.speaker)}:
              {speakerName:'Voix à identifier'})};
        })}));
  };
}
