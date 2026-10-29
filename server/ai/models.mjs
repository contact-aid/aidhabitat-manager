// One text model for every OpenRouter text task. Audio/vision require their
// own compatible model; do not silently substitute a text-only model there.
export const OPENROUTER_TEXT_MODEL = 'deepseek/deepseek-v4-flash';
export const TEXT_PROVIDER_POLICY = Object.freeze({
  sort: 'price', zdr: true, data_collection: 'deny',
  allow_fallbacks: false, require_parameters: true,
});
