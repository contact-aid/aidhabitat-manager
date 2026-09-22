/** Serializes mutations for one business key without blocking unrelated keys. */
export function createKeyedSerialExecutor() {
  const tails = new Map();
  return async function run(key, action) {
    const normalized = String(key);
    const previous = tails.get(normalized) ?? Promise.resolve();
    let release;
    const current = new Promise((resolve) => { release = resolve; });
    tails.set(normalized, current);
    await previous.catch(() => {});
    try {
      return await action();
    } finally {
      release();
      if (tails.get(normalized) === current) tails.delete(normalized);
    }
  };
}
