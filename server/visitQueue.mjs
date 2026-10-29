// Processing lives on the server; an iPad only uploads and polls progress.
// Per-recording file locks still protect against another process or old client.
export class VisitQueue {
  constructor({store,processor,retryDelayMs=30_000,onError=()=>{}}) {
    Object.assign(this,{store,processor,retryDelayMs,onError});
    this.running=new Map();this.closed=false;this.timers=new Set();
  }
  enqueue(dossierId,id) {
    const key=JSON.stringify([dossierId,id]);
    if(this.closed||this.running.has(key))return this.running.get(key);
    const promise=this.run(dossierId,id).finally(()=>this.running.delete(key));
    this.running.set(key,promise);return promise;
  }
  async pause(ms) {if(this.closed)return;await new Promise(resolve=>{const timer=setTimeout(()=>{this.timers.delete(timer);resolve();},ms);timer.unref?.();this.timers.add(timer);});}
  async run(dossierId,id) {
    while(!this.closed) {
      const before=await this.store.read(dossierId,id);
      if(!before||['uploading','complete','failed'].includes(before.status))return;
      const delay=Date.parse(before.retryAfter||'')-Date.now();
      if(delay>0)await this.pause(delay);
      if(this.closed)return;
      try {const job=await this.processor.step(dossierId,id);if(['complete','failed'].includes(job.status))return;}
      catch(error) {
        const job=await this.store.read(dossierId,id);
        if(!job||job.status==='failed')return;
        if(error.statusCode!==409&&!job.retryAfter){this.onError(error);return;}
        await this.pause(this.retryDelayMs);
      }
    }
  }
  async resume() {
    for(const job of await this.store.all()) {
      // Historical failures require an explicit retry, not a fresh billing loop.
      if(job.error||['uploading','complete','failed'].includes(job.status))continue;
      void this.enqueue(job.dossierId,job.id).catch(this.onError);
    }
  }
  close() {this.closed=true;for(const timer of this.timers)clearTimeout(timer);this.timers.clear();}
}
