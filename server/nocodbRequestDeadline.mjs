export const DEFAULT_NOCODB_REST_TIMEOUT_MS = 120_000;
export const MIN_NOCODB_REST_TIMEOUT_MS = 1_000;
export const MAX_NOCODB_REST_TIMEOUT_MS = 900_000;

const timeoutConfigError = (rawValue) => {
  const error = new TypeError(
    'NOCODB_REST_TIMEOUT_MS doit etre un entier compris entre '
      + `${MIN_NOCODB_REST_TIMEOUT_MS} et ${MAX_NOCODB_REST_TIMEOUT_MS} ms`,
  );
  error.code = 'NOCODB_REST_TIMEOUT_CONFIG_INVALID';
  error.value = rawValue;
  return error;
};

export const parseNocodbRestTimeoutMs = (rawValue) => {
  if (rawValue == null || String(rawValue).trim() === '') {
    return DEFAULT_NOCODB_REST_TIMEOUT_MS;
  }

  const normalized = String(rawValue).trim();
  if (!/^\d+$/.test(normalized)) {
    throw timeoutConfigError(rawValue);
  }

  const timeoutMs = Number(normalized);
  if (
    !Number.isSafeInteger(timeoutMs)
    || timeoutMs < MIN_NOCODB_REST_TIMEOUT_MS
    || timeoutMs > MAX_NOCODB_REST_TIMEOUT_MS
  ) {
    throw timeoutConfigError(rawValue);
  }

  return timeoutMs;
};

export class NocodbRestTimeoutError extends Error {
  constructor({ method, path, timeoutMs }) {
    super(`NocoDB REST ${method} ${path} timed out after ${timeoutMs} ms`);
    this.name = 'NocodbRestTimeoutError';
    this.code = 'NOCODB_REST_TIMEOUT';
    this.method = method;
    this.path = path;
    this.timeoutMs = timeoutMs;
  }
}

export const fetchNocodbRestWithDeadline = async (
  url,
  options,
  {
    timeoutMs,
    method = options?.method || 'GET',
    path = new URL(url).pathname,
    fetchImpl = globalThis.fetch,
    setTimeoutImpl = globalThis.setTimeout,
    clearTimeoutImpl = globalThis.clearTimeout,
  },
) => {
  const validatedTimeoutMs = parseNocodbRestTimeoutMs(timeoutMs);
  const controller = new AbortController();
  let deadlineError;
  let timeoutId;

  const deadlinePromise = new Promise((_, reject) => {
    timeoutId = setTimeoutImpl(() => {
      deadlineError = new NocodbRestTimeoutError({
        method,
        path,
        timeoutMs: validatedTimeoutMs,
      });
      controller.abort(deadlineError);
      reject(deadlineError);
    }, validatedTimeoutMs);
  });

  const requestPromise = (async () => {
    const response = await fetchImpl(url, {
      ...options,
      signal: controller.signal,
    });
    const text = await response.text();
    return { response, text };
  })();

  try {
    return await Promise.race([requestPromise, deadlinePromise]);
  } catch (error) {
    if (deadlineError) {
      throw deadlineError;
    }
    throw error;
  } finally {
    if (timeoutId !== undefined) {
      clearTimeoutImpl(timeoutId);
    }
  }
};

const MUTATING_TOOLS = new Set([
  'createRecords',
  'updateRecords',
  'deleteRecords',
]);

export const isNocodbMutationTool = (name) => MUTATING_TOOLS.has(name);

export const shouldFallbackToRestAfterMcpError = ({
  name,
  mutationMayHaveBeenSent,
}) => !(isNocodbMutationTool(name) && mutationMayHaveBeenSent);
