// Distinguishes an exhausted OpenAI balance from other provider failures.
// Only the error type/code is read: provider bodies are never propagated,
// since they can echo clinical content.
export const PROVIDER_QUOTA_MESSAGE =
  'Crédits du service IA épuisés : traitement suspendu. Les sources sont conservées. Prévenir l’administrateur, puis appuyer sur Reprendre.';

const QUOTA_CODES = new Set(['insufficient_quota', 'credit_balance_exhausted']);

export async function isProviderQuotaExhausted(response) {
  if (response?.status !== 429) return false;
  try {
    const { error } = await response.clone().json();
    return QUOTA_CODES.has(error?.type) || QUOTA_CODES.has(error?.code);
  } catch {
    return false;
  }
}

export const providerQuotaError = () =>
  Object.assign(new Error(PROVIDER_QUOTA_MESSAGE), { statusCode: 402, providerQuota: true });

/** Throws the quota error when applicable, otherwise the given fallback. */
export async function throwProviderFailure(response, fallback) {
  if (await isProviderQuotaExhausted(response)) throw providerQuotaError();
  throw fallback();
}
