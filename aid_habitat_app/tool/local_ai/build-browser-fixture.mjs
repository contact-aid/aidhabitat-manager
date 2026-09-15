// Diagnostic build for synthetic browser tests only; never a release asset.
import {build} from 'esbuild';
import {readFile} from 'node:fs/promises';
const source = (await readFile(new URL('worker.mjs',import.meta.url),'utf8'))
  .replace('} catch (_) {','} catch (error) { self.postMessage({id, error: String(error)});');
await build({stdin:{contents:source,resolveDir:import.meta.dirname,sourcefile:'worker.mjs'},
  bundle:true,format:'iife',outfile:process.argv[2],minify:false});
