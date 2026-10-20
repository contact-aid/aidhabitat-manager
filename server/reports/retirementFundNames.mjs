// Flutter stores multi-selections with semicolons; older web forms use commas.
// Accept both without changing the eligibility rules for individual funds.
export function splitRetirementFundNames(input) {
  return (Array.isArray(input) ? input : [input])
    .flatMap(value => String(value || '').split(/[,;\r\n]+/u))
    .map(name => name.trim())
    .filter(Boolean);
}

// Keep the occupant index throughout resolution. The same eligible fund can
// belong to two people; only duplicates within one person's selection collapse.
export function retirementFundAidLabelsByOccupant(input, resolveEligibleName) {
  const groups = Array.isArray(input) ? input : [input];
  const labels = groups.map(selection => {
    const seen = new Set();
    return splitRetirementFundNames(selection).map(resolveEligibleName).filter(name => {
      if (!name) return false;
      const key = name.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    }).join(', ');
  });
  if (!labels.some(Boolean)) return '/';
  if (labels.length === 1) return `${labels[0]} sous conditions*`;
  return labels.map((label, index) =>
    `Occupant ${index + 1} : ${label || '/'}`,
  ).join('\n') + '\nsous conditions*';
}
