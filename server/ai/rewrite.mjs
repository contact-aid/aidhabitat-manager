import { textProviderConfig, completionBody } from './provider.mjs';
import { rewriteInstructions } from '../../shared/aiRewritePrompt.mjs';
import { OPENROUTER_TEXT_MODEL, TEXT_PROVIDER_POLICY } from './models.mjs';
export const REWRITE_MODEL = OPENROUTER_TEXT_MODEL;
export const REWRITE_MODES = Object.freeze({
  professional: [
    "Corrige les fautes et reformule les tournures incorrectes ou maladroites dans un français professionnel.",
    'Conserve la structure et le vocabulaire précis de la note. Modifie seulement ce qui est nécessaire.',
  ].join(' '),
  concise: [
    "Reformule cette note dans un français professionnel adapté à un rapport d'ergothérapie.",
    'Rends-la plus concise tout en conservant chaque information utile.',
  ].join(' '),
  correct: [
    "Corrige uniquement l'orthographe, la grammaire et la ponctuation de cette note.",
    'Conserve au maximum la formulation et la structure originales.',
  ].join(' '),
});

export const getRewriteConfig = (env = process.env) => ({
  ...textProviderConfig(env),
  timeoutMs: 60_000,
});
export const getAiRewriteStatus = ({ config = getRewriteConfig() } = {}) => ({
  ready: Boolean(config.apiKey), webEnabled: true, provider: config.provider, model: config.model,
});

export const normalizeRewriteMode = (value) => (
  Object.hasOwn(REWRITE_MODES, value) ? value : 'professional'
);

export const buildRewriteMessages = (text, mode = 'professional', context = 'general') => {
  const normalizedMode = normalizeRewriteMode(mode);
  return [
    {
      role: 'system',
      content: rewriteInstructions(normalizedMode, context),
    },
    {
      role: 'user',
      content: text,
    },
  ];
};

export const findProtectedFragments = (text) => {
  const source = String(text || '');
  const matches = [
    ...source.matchAll(
      /\b(?:M(?:me|lle)?\.?|Mme|Mlle|Monsieur|Madame|Docteur|Dr\.?)\s+[\p{Lu}][\p{L}'’-]+(?:\s+[\p{Lu}][\p{L}'’-]+)?/gu,
    ),
    ...source.matchAll(/\bGIR\s*[1-6]\b/giu),
    ...source.matchAll(
      /\b\d+(?:[.,]\d+)?(?:\s*(?:mm|cm|m|kg|ans?|heures?|h|min|minutes?|%|€))?(?=\s|[.,;:!?)]|$)/giu,
    ),
  ];

  return [...new Set(matches.map((match) => match[0].trim()))];
};

const normalizeProtectedFragment = (value) => String(value)
  .normalize('NFC')
  .toLocaleLowerCase('fr')
  .replace(/\s+/g, ' ')
  .trim();

export const findMissingProtectedFragments = (sourceText, rewrittenText) => {
  const normalizedOutput = normalizeProtectedFragment(rewrittenText);
  return findProtectedFragments(sourceText).filter((fragment) => (
    !normalizedOutput.includes(normalizeProtectedFragment(fragment))
  ));
};

const rewriteError = (message, statusCode = 503) => Object.assign(new Error(message), { statusCode });

export const rewriteNote = async ({text, mode = 'professional', context = 'general',
  fetchImpl = fetch, config = getRewriteConfig()}) => {
  if (!config.apiKey) throw rewriteError('Le service de reformulation est indisponible. La note est conservée.');
  let response;
  try {
    response = await fetchImpl(config.url || 'https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST', signal: AbortSignal.timeout(config.timeoutMs),
      headers: { Authorization: `Bearer ${config.apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(completionBody({...config,model:config.model || REWRITE_MODEL}, {
        messages:buildRewriteMessages(text,mode,context),maxTokens:4096})),
    });
  } catch (error) {
    throw rewriteError('La reformulation est indisponible. La note est conservée.',
      ['AbortError', 'TimeoutError'].includes(error?.name) ? 504 : 503);
  }
  // Do not expose provider bodies, which may echo note content or credentials.
  if (!response.ok) throw rewriteError('Le prestataire IA est indisponible. La note est conservée.', 502);
  let payload;
  try { payload = await response.json(); }
  catch { throw rewriteError('La réponse IA est illisible. La note est conservée.', 502); }
  const choice = payload?.choices?.[0];
  const result = choice?.message?.content;
  if (choice?.finish_reason !== 'stop' || typeof result !== 'string' || !result.trim()) {
    throw rewriteError('La proposition est vide ou incomplète. La note est conservée.', 422);
  }
  const rewritten = result.trim();
  if (findMissingProtectedFragments(text, rewritten).length) {
    throw rewriteError("La proposition n'était pas assez fidèle à la note originale. La note a été conservée.", 422);
  }
  return { text: rewritten, mode: normalizeRewriteMode(mode), model: config.model || REWRITE_MODEL };
};
