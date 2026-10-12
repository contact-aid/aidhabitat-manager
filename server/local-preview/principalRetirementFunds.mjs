// Local preview only. The production reference still needs a real CARSAT row
// when publication is authorized. Never use these synthetic IDs for sync.
export const LOCAL_PRINCIPAL_RETIREMENT_FUNDS = [
  { id: 'local-preview-carsat', name: 'CARSAT', phone: '', logoUrl: '' },
];

export function withLocalPrincipalRetirementFunds(payload) {
  if (payload?.success !== true || !Array.isArray(payload?.data?.funds)) {
    return payload;
  }
  const funds = [...payload.data.funds];
  const names = new Set(funds.map((fund) => String(fund.name ?? '').trim().toLowerCase()));
  for (const fund of LOCAL_PRINCIPAL_RETIREMENT_FUNDS) {
    if (!names.has(fund.name.toLowerCase())) funds.push({ ...fund });
  }
  funds.sort((a, b) => a.name.localeCompare(b.name, 'fr'));
  return { ...payload, data: { ...payload.data, funds } };
}
