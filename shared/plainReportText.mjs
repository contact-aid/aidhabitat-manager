// Report fields are plain text on both iPad and web. Preserve the words,
// measurements and paragraph breaks when a model adds presentation markup.
export const PLAIN_REPORT_INSTRUCTIONS = 'Rédige en texte brut uniquement, sans gras, italique, balise HTML ni marqueur Markdown. Les intitulés éventuels sont de simples mots suivis de deux-points. Conserve les paragraphes séparés par une ligne vide.';
export function plainReportText(value) {
  let text=String(value??'').replace(/\r\n?/g,'\n');
  text=text.replace(/^\s*```(?:text|plaintext|markdown|md)?\s*\n([\s\S]*?)\n```\s*$/i,'$1');
  for(let pass=0;pass<2;pass++) {
    text=text.replace(/(^|[^\p{L}\p{N}_])(\*\*|__)(?=\S)([\s\S]*?\S)\2(?=$|[^\p{L}\p{N}_])/gu,'$1$3');
    text=text.replace(/(^|[\s([{])([*_])(?=\S)([^\n]*?\S)\2(?=$|[\s.,;:!?)\]}])/g,'$1$3');
  }
  return text.replace(/^ {0,3}#{1,6}[ \t]+/gm,'')
    .replace(/<br\s*\/?>/gi,'\n').replace(/<\/(?:p|div)>/gi,'\n\n')
    .replace(/<\/?(?:b|strong|i|em|u|span|p|div)(?:\s+[^>]*)?>/gi,'')
    .replace(/`([^`\n]+)`/g,'$1')
    .replace(/&nbsp;/gi,' ').replace(/&amp;/gi,'&')
    .replace(/[ \t]+\n/g,'\n').replace(/\n{3,}/g,'\n\n').trim();
}
