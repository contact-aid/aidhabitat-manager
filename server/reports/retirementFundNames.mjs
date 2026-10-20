// Flutter stores multi-selections with semicolons; older web forms use commas.
// Accept both representations when collecting the selected complementary funds.
export function splitRetirementFundNames(input) {
  return (Array.isArray(input) ? input : [input])
    .flatMap(value => String(value || '').split(/[,;\r\n]+/u))
    .map(name => name.trim())
    .filter(Boolean);
}

// The report lists every selected complementary fund, once for the household.
// Reference eligibility flags do not remove a selected fund from this summary.
export function retirementFundLabelsForReport(input) {
  const seen = new Set();
  const names = splitRetirementFundNames(input).filter(name => {
    const key = name.replace(/\s+/g, ' ').toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  return names.length ? `${names.join(', ')} sous conditions*` : '/';
}
