import { readFileSync } from 'node:fs';
import { OPENROUTER_TEXT_MODEL, TEXT_PROVIDER_POLICY } from './models.mjs';
export function textProviderConfig(env = process.env) {
  const openai = env.AI_PROVIDER === 'openai';
  return { provider: openai ? 'openai' : 'openrouter',
    apiKey: String(openai ? env.OPENAI_API_KEY || (env.OPENAI_API_KEY_FILE ? readFileSync(env.OPENAI_API_KEY_FILE,'utf8') : '') : env.OPENROUTER_API_KEY || '').trim(),
    model: openai ? env.OPENAI_TEXT_MODEL || 'gpt-6-luna' : OPENROUTER_TEXT_MODEL,
    url: openai ? 'https://api.openai.com/v1/chat/completions' : 'https://openrouter.ai/api/v1/chat/completions' };
}
export function completionBody(config, {messages, model = config.model, maxTokens = 12000, responseFormat}) {
  return {model, messages, stream:false,
    ...(config.provider === 'openai'
      ? {store:false, max_completion_tokens:maxTokens, reasoning_effort:'none'}
      : {temperature:0.1, max_tokens:maxTokens, reasoning:{enabled:false}, provider:TEXT_PROVIDER_POLICY}),
    ...(responseFormat ? {response_format:responseFormat} : {})};
}
