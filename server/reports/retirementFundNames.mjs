// Flutter stores multi-selections with semicolons; older web forms use commas.
// Accept both without changing the eligibility rules for individual funds.
export function splitRetirementFundNames(input) {
  return (Array.isArray(input) ? input : [input])
    .flatMap(value => String(value || '').split(/[,;\r\n]+/u))
    .map(name => name.trim())
    .filter(Boolean);
}
