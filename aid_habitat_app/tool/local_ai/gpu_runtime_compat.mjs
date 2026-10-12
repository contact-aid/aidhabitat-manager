// WebLLM 0.2.85 requests ten storage bindings for every model. Qwen's initial
// ragged prefill and decode kernels work with nine; paged prefill needs ten.
// The worker uses fresh, bounded prompts on nine-buffer devices, while WebGPU
// continues to validate every pipeline against the actual device limit.
export function adaptGpuRuntime(source) {
  const target = 'const requiredMaxStorageBuffersPerShaderStage = 10;';
  if (source.split(target).length !== 2) throw new Error('Pinned WebLLM GPU contract changed');
  return source.replace(target, 'const requiredMaxStorageBuffersPerShaderStage = adapter.limits.maxStorageBuffersPerShaderStage === 9 ? 9 : 10;');
}
