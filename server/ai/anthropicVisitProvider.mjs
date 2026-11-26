import Anthropic from '@anthropic-ai/sdk';
import { providerQuotaError } from '../openaiProviderError.mjs';

// Claude handles the visit's text and vision tasks (handwriting, facts,
// drafting, questions). Audio stays with a speech-capable provider: the Claude
// API takes no audio input.
export const ANTHROPIC_VISIT_MODEL = 'claude-opus-5-5';
const FALLBACK_BETA = 'server-side-fallback-2026-07-01';

// Thinking is always on with Claude Opus 5.5; effort is the only depth control.
const TASK_EFFORT = { handwriting: 'low', facts: 'high', draft: 'high' };

const visitError = (statusCode, message) => Object.assign(new Error(message), { statusCode });

export function anthropicVisitConfig(env = process.env) {
  return {
    provider: 'anthropic',
    apiKey: String(env.ANTHROPIC_API_KEY || '').trim(),
    model: env.ANTHROPIC_VISIT_MODEL || ANTHROPIC_VISIT_MODEL,
  };
}

// The structured-outputs grammar rejects numeric, length and array-size
// constraints. The server already validates those after parsing.
const UNSUPPORTED = new Set(['minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf',
  'minLength', 'maxLength', 'minItems', 'maxItems', 'uniqueItems']);
export function anthropicSchema(schema) {
  if (Array.isArray(schema)) return schema.map(anthropicSchema);
  if (!schema || typeof schema !== 'object') return schema;
  return Object.fromEntries(Object.entries(schema).filter(([key]) => !UNSUPPORTED.has(key))
    .map(([key, value]) => [key,
      key === 'enum' || key === 'required' ? value
        // Keys under `properties` are field names, never keywords to strip.
        : key === 'properties' ? Object.fromEntries(Object.entries(value).map(([name, child]) => [name, anthropicSchema(child)]))
          : anthropicSchema(value)]));
}

const DATA_URL = /^data:(image\/(?:png|jpeg|gif|webp));base64,([A-Za-z0-9+/=]+)$/;
function contentBlocks(content) {
  if (typeof content === 'string') return content;
  return content.map(part => {
    if (part.type === 'text') return { type: 'text', text: part.text };
    if (part.type === 'image_url') {
      const match = DATA_URL.exec(part.image_url?.url ?? '');
      if (!match) throw visitError(400, 'Image invalide pour le service IA.');
      return { type: 'image', source: { type: 'base64', media_type: match[1], data: match[2] } };
    }
    throw visitError(400, 'Contenu non pris en charge par le service IA.');
  });
}

/** Converts the chat-completions shaped messages used by the visit prompts. */
export function anthropicRequest(messages, { model, maxTokens, task, jsonSchema }) {
  const system = messages.filter(m => m.role === 'system').map(m => m.content).join('\n\n');
  return {
    model,
    // Thinking tokens count against max_tokens: leave room above the answer.
    max_tokens: Math.min(Math.max(maxTokens * 2, 16000), 64000),
    ...(system ? { system } : {}),
    messages: messages.filter(m => m.role !== 'system').map(m => ({ role: m.role, content: contentBlocks(m.content) })),
    output_config: {
      effort: TASK_EFFORT[task] ?? 'medium',
      ...(jsonSchema ? { format: { type: 'json_schema', schema: anthropicSchema(jsonSchema.schema) } } : {}),
    },
    betas: [FALLBACK_BETA],
    fallbacks: 'default',
  };
}

// Without a schema the prompts ask for JSON; tolerate a fenced answer.
const unfence = text => text.trim().replace(/^```(?:json)?\s*\n([\s\S]*?)\n```$/u, '$1');

export function createAnthropicComplete({ env = process.env, client, onUsage = async () => {}, usageContext = () => ({}) } = {}) {
  const config = anthropicVisitConfig(env);
  const anthropic = client ?? (config.apiKey ? new Anthropic({ apiKey: config.apiKey, maxRetries: 2 }) : null);
  return async (messages, { model = config.model, json = false, jsonSchema = null, task = 'text', maxTokens = 12000, timeoutMs = 150_000 } = {}) => {
    if (!anthropic || !model) throw visitError(503, 'Le service IA de visite n’est pas configuré.');
    const startedAt = Date.now();
    let message;
    try {
      // Streaming keeps long drafts clear of HTTP timeouts.
      message = await anthropic.beta.messages
        .stream(anthropicRequest(messages, { model, maxTokens, task, jsonSchema }), { timeout: timeoutMs * 2 })
        .finalMessage();
    } catch (error) {
      if (error instanceof Anthropic.APIError && error.type === 'billing_error') throw providerQuotaError();
      // Never propagate provider bodies: they can echo clinical content or keys.
      throw visitError(502, 'Le prestataire IA est indisponible. Réessayez ultérieurement.');
    }
    await Promise.resolve().then(() => onUsage({ ...usageContext(), task, model, provider: 'anthropic',
      generationId: message.id ?? null, servedModel: message.model ?? null, cost: null,
      promptTokens: message.usage?.input_tokens ?? null, completionTokens: message.usage?.output_tokens ?? null,
      cacheReadTokens: message.usage?.cache_read_input_tokens ?? null,
      finishReason: message.stop_reason ?? null, durationMs: Date.now() - startedAt, at: new Date().toISOString(),
    })).catch(() => {});
    if (message.stop_reason === 'refusal') throw visitError(502, 'Le service IA a refusé de traiter cette visite. Les sources sont conservées.');
    if (message.stop_reason === 'max_tokens') throw visitError(502, 'La réponse IA est vide ou incomplète.');
    const text = message.content.filter(block => block.type === 'text').map(block => block.text).join('');
    if (!text.trim()) throw visitError(502, 'La réponse IA est vide ou incomplète.');
    return json && !jsonSchema ? unfence(text) : text;
  };
}
