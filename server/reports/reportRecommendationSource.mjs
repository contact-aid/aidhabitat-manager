/** Use the same published snapshot as the dossier UI. Legacy rows only serve dossiers without one. */
export async function readReportRecommendations({ readSnapshot, readLegacy }) {
  const snapshot = await readSnapshot();
  if (snapshot !== null) return snapshot.items;
  return readLegacy();
}
