import { rewriteInstructions } from '../../shared/aiRewritePrompt.mjs';
const DEFAULT_BASE_URL = 'http://127.0.0.1:11434';
const DEFAULT_MODEL = 'gemma3:4b';
const DEFAULT_LLAMA_MODEL = 'Qwen3-4B-Instruct-2507-Q4_K_M.gguf';
const DEFAULT_TIMEOUT_MS = 120_000;
const DEFAULT_KEEP_ALIVE = '10m';

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

const cleanBaseUrl = (value) => String(value || DEFAULT_BASE_URL)
  .trim()
  .replace(/\/+$/, '');

const positiveNumber = (value, fallback) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
};

export const getRewriteConfig = (env = process.env) => {
  const provider = env.AI_REWRITE_PROVIDER === 'llama.cpp' ? 'llama.cpp' : 'ollama';
  return {
    provider,
    webEnabled: env.AI_REWRITE_WEB_ENABLED === 'true',
    baseUrl: cleanBaseUrl(provider === 'llama.cpp'
      ? (env.LLAMA_REWRITE_BASE_URL || 'http://127.0.0.1:8080')
      : env.OLLAMA_BASE_URL),
    model: provider === 'llama.cpp'
      ? String(env.LLAMA_REWRITE_MODEL || DEFAULT_LLAMA_MODEL).trim() || DEFAULT_LLAMA_MODEL
      : String(env.OLLAMA_REWRITE_MODEL || DEFAULT_MODEL).trim() || DEFAULT_MODEL,
    timeoutMs: positiveNumber(env.AI_REWRITE_TIMEOUT_MS || env.OLLAMA_REWRITE_TIMEOUT_MS, DEFAULT_TIMEOUT_MS),
    keepAlive: String(env.OLLAMA_REWRITE_KEEP_ALIVE ?? DEFAULT_KEEP_ALIVE).trim() || DEFAULT_KEEP_ALIVE,
  };
};

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

const rewriteError = (message, statusCode = 503) => {
  const error = new Error(message);
  error.statusCode = statusCode;
  return error;
};

const fetchWithTimeout = async (url, options, timeoutMs, fetchImpl) => {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImpl(url, {
      ...options,
      signal: controller.signal,
    });
  } catch (error) {
    if (error?.name === 'AbortError') {
      throw rewriteError("La reformulation locale a dépassé le délai d'attente.", 504);
    }
    throw rewriteError('Le service de reformulation locale est indisponible.');
  } finally {
    clearTimeout(timeoutId);
  }
};

export const getLocalAiStatus = async ({
  fetchImpl = fetch,
  config = getRewriteConfig(),
} = {}) => {
  try {
    const response = await fetchWithTimeout(
      `${config.baseUrl}/${config.provider === 'llama.cpp' ? 'health' : 'api/tags'}`,
      { headers: { Accept: 'application/json' } },
      Math.min(config.timeoutMs, 5_000),
      fetchImpl,
    );
    if (!response.ok) {
      return {
        ready: false,
        model: config.model,
        installed: false,
      };
    }

    const payload = await response.json();
    const models = Array.isArray(payload?.models) ? payload.models : [];
    const installed = config.provider === 'llama.cpp'
      ? payload?.status === 'ok'
      : models.some((entry) => (
        entry?.name === config.model || entry?.model === config.model
      ));
    return {
      ready: installed,
      model: config.model,
      installed,
      ...(config.webEnabled ? { webEnabled: true } : {}),
    };
  } catch {
    return {
      ready: false,
      model: config.model,
      installed: false,
    };
  }
};

export const rewriteNote = async ({
  text,
  mode = 'professional',
  context = 'general',
  fetchImpl = fetch,
  config = getRewriteConfig(),
}) => {
  const usesLlama = config.provider === 'llama.cpp';
  const response = await fetchWithTimeout(
    `${config.baseUrl}/${usesLlama ? 'v1/chat/completions' : 'api/chat'}`,
    {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(usesLlama ? {
        model: config.model,
        stream: false,
        messages: buildRewriteMessages(text, mode, context),
        temperature: 0,
        max_tokens: 2048,
        chat_template_kwargs: { enable_thinking: false },
      } : {
        model: config.model,
        stream: false,
        keep_alive: config.keepAlive ?? DEFAULT_KEEP_ALIVE,
        messages: buildRewriteMessages(text, mode, context),
        options: {
          temperature: 0,
          num_ctx: 4096,
          num_predict: 2048,
        },
      }),
    },
    config.timeoutMs,
    fetchImpl,
  );

  if (!response.ok) {
    if (response.status === 404) {
      throw rewriteError(`Le modèle local ${config.model} n'est pas installé.`);
    }
    throw rewriteError('La reformulation locale a échoué.');
  }

  const payload = await response.json();
  if ((usesLlama && payload?.choices?.[0]?.finish_reason !== 'stop') ||
      (!usesLlama && payload?.done_reason === 'length')) {
    throw rewriteError("La proposition est incomplète. La note a été conservée.", 422);
  }
  const rewrittenText = String(usesLlama
    ? payload?.choices?.[0]?.message?.content || ''
    : payload?.message?.content || '').trim();
  if (!rewrittenText) {
    throw rewriteError("Le modèle local n'a renvoyé aucun texte.");
  }

  const missingFragments = findMissingProtectedFragments(text, rewrittenText);
  if (missingFragments.length > 0) {
    throw rewriteError(
      "La proposition n'était pas assez fidèle à la note originale. La note a été conservée.",
      422,
    );
  }

  return {
    text: rewrittenText,
    model: config.model,
    mode: normalizeRewriteMode(mode),
  };
};
