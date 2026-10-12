export const COLLECTION_MUTATION_CONTRACT = 'collections-v2';
const fields = {
  patient: ['occupants', 'dependenceTxt'],
  housing: ['roomsBreakdown', 'basement', 'rdc', 'floor', 'secondFloor', 'thirdFloor'],
  sanitary: ['sdbInstances', 'wcInstances'],
};

// Call after authorization, before mapping or writing. A fresh timestamp cannot
// make a build64 single-choice editor capable of preserving a collection.
export function assertCollectionMutationAllowed({ kind, payload }) {
  if (!fields[kind]) throw new TypeError('Unknown collection entity');
  const updates = payload?.updates ?? payload ?? {};
  const changed = fields[kind].filter(key => Object.hasOwn(updates, key));
  if (!changed.length) return;
  if (payload?.concurrency?.collectionContract === COLLECTION_MUTATION_CONTRACT) return;
  const error = new Error('Cette saisie provient d’une ancienne version. Comparez les valeurs dans la nouvelle application pour la reprendre ; les données locales sont conservées.');
  Object.assign(error, {
    status: 409, statusCode: 409, code: 'COLLECTION_CLIENT_UPGRADE_REQUIRED',
    fields: changed,
  });
  throw error;
}
