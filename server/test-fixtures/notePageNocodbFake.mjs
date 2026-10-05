const conditions = (where = '') => [...where.matchAll(/\(([^,()]+),eq,([^()]+)\)/g)]
  .map(([, key, value]) => [key, value.replace(/^"|"$/g, '')]);

const matches = (row, where) => conditions(where)
  .every(([key, value]) => String(row[key] ?? '') === value);

const asRecord = (row) => ({
  id: String(row.Id),
  fields: Object.fromEntries(Object.entries(row).filter(([key]) => key !== 'Id')),
});

export const createNotePageNocodbFake = () => {
  const state = {
    rows: [], chunkRows: [], chunkCreates: 0, nextId: 1, creates: 0, patches: 0, deletes: 0,
    beforeChunk: null, loseChunkResponse: false, beforePatch: null, losePatchResponse: false,
    loseCreateResponse: false, beforeCreate: null,
    insert(fields) {
      const row = { Id: this.nextId++, ...structuredClone(fields) };
      this.rows.push(row);
      return row;
    },
  };
  const io = {
    queryAll: async (_tableId, options = {}) => (_tableId === 'chunks' ? state.chunkRows : state.rows)
      .filter((row) => matches(row, options.where ?? ''))
      .map((row) => asRecord(structuredClone(row))),
    createRecord: async (_tableId, fields) => {
      if (_tableId === 'chunks') {
        await state.beforeChunk?.(state, fields);
        const row = { Id: state.nextId++, ...structuredClone(fields) };
        state.chunkRows.push(row); state.chunkCreates++;
        if (state.loseChunkResponse) {
          state.loseChunkResponse = false;
          throw new Error('Synthetic fragment ACK lost');
        }
        return asRecord(row);
      }
      await state.beforeCreate?.(state, fields);
      const row = state.insert(fields);
      state.creates += 1;
      if (state.loseCreateResponse) {
        state.loseCreateResponse = false;
        throw new Error('Synthetic response lost after commit');
      }
      return asRecord(row);
    },
    updateRecord: async (_tableId, id, fields) => {
      const row = state.rows.find((item) => String(item.Id) === String(id));
      if (row) Object.assign(row, structuredClone(fields));
    },
    deleteRecord: async (_tableId, id) => {
      state.deletes += 1;
      state.rows = state.rows.filter((row) => String(row.Id) !== String(id));
    },
    callNocoTool: async (name) => {
      if (name !== 'getTableSchema') throw new Error(`Unexpected tool: ${name}`);
      return { fields: [
        'uuid_source', 'beneficiaire_id', 'dossier_id', 'scope_type', 'scope_id',
        'tab_key', 'sub_tab_key', 'page_number', 'text_content', 'drawing_json',
        'layout_kind', 'app_sync_revision', 'updated_at', 'preview_url',
      ].map((title) => ({ title, type: 'SingleLineText' })) };
    },
    requestConditionalNocodbRest: async ({ path, body }) => {
      await state.beforePatch?.(state, body);
      const where = new URL(path, 'https://fake.test').searchParams.get('where') ?? '';
      const row = state.rows.find((item) => matches(item, where));
      if (row) Object.assign(row, structuredClone(body));
      state.patches += 1;
      if (state.losePatchResponse) {
        state.losePatchResponse = false;
        throw new Error('Synthetic note ACK lost');
      }
      return { count: row ? 1 : 0 };
    },
  };
  return { state, io };
};
