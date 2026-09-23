// The fields used for read-after-write confirmation must include every
// optional value that upsertNotePage can write on the installed schema.
export const notePageReadFields = (availableFields) => {
  const fields = ['uuid_source', 'beneficiaire_id', 'dossier_id',
    'beneficiaire_prenom', 'beneficiaire_nom', 'beneficiaire_nom_complet',
    'dossier_libelle', 'scope_type', 'scope_id', 'tab_key', 'sub_tab_key',
    'page_number', 'text_content', 'drawing_json', 'layout_kind',
    'app_sync_revision', 'updated_at'];
  for (const optional of ['preview_data_url', 'preview_url', 'plan_phase']) {
    if (availableFields.has(optional)) fields.push(optional);
  }
  return fields;
};
