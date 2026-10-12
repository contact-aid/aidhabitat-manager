// Keep every character and every word intact. Only the pinned nine-buffer
// runtime needs separate, empty-context prompts below its prefill chunk size.
export function rewriteParts(text, countPromptTokens, limit = 900) {
  if (countPromptTokens(text) <= limit) return [text];
  const sentences = [...new Intl.Segmenter('fr', {granularity: 'sentence'}).segment(text)].map(item => item.segment);
  const parts = [];
  let current = '';
  for (const sentence of sentences) {
    const units = countPromptTokens(sentence) <= limit ? [sentence]
      : [...new Intl.Segmenter('fr', {granularity: 'word'}).segment(sentence)].map(item => item.segment);
    for (const unit of units) {
      if (countPromptTokens(unit) > limit) throw new Error('unsplittable');
      if (current && countPromptTokens(current + unit) > limit) {
        parts.push(current); current = '';
      }
      current += unit;
    }
  }
  if (current) parts.push(current);
  if (parts.join('') !== text || parts.some(part => countPromptTokens(part) > limit)) throw new Error('partition');
  return parts;
}
