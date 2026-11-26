#!/usr/bin/env bash
# Vérification en lecture seule : les documents DOC_IDS (identifiants locaux
# des iPad, ex. doc_1792760666569820) sont-ils arrivés sur le serveur ?
# N'affiche ni titre ni contenu : présence, date de mise à jour, taille
# annoncée et nombre de morceaux de fichier reçus.
#
# Depuis le Mac :
#   ssh root@157.180.20.97 "DOC_IDS='doc_1792760666569820 doc_1791986649318776' bash -s" \
#     < tools/check-documents-on-server.sh

set -euo pipefail
DOC_IDS="${DOC_IDS:?DOC_IDS requis}"
API="$(docker ps --format '{{.Names}}' | grep -i 'aidhabitat-api' | head -1)"
[ -n "$API" ] || { echo "Conteneur API introuvable." >&2; exit 1; }

docker exec -e DOC_IDS="$DOC_IDS" "$API" node --input-type=module -e '
const url = process.env.NOCODB_API_URL.replace(/\/+$/, "");
const headers = { "xc-token": process.env.NOCODB_API_TOKEN };
const get = async (path) => { const r = await fetch(url + path, { headers });
  if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); };
const tables = (await get("/api/v2/meta/bases/" + process.env.NOCODB_BASE_ID + "/tables")).list;
const docs = tables.find((t) => /^mobile_documents$/i.test(t.title));
const chunks = tables.find((t) => /^mobile_document_chunks$/i.test(t.title));
for (const id of process.env.DOC_IDS.split(/\s+/).filter(Boolean)) {
  const safe = id.replace(/[^A-Za-z0-9_-]/g, "");
  const rows = (await get("/api/v2/tables/" + docs.id + "/records?where=" +
    encodeURIComponent("(uuid_source,eq," + safe + ")~or(client_document_id,eq," + safe + ")") +
    "&fields=Id,uuid_source,updated_at&limit=5")).list;
  if (!rows.length) { console.log(safe, ": ABSENT du serveur"); continue; }
  for (const row of rows) {
    const c = await get("/api/v2/tables/" + chunks.id + "/records/count?where=" +
      encodeURIComponent("(document_uuid_source,eq," + row.uuid_source + ")"));
    console.log(safe, ": présent | mis à jour", row.updated_at, "| morceaux de fichier :", c.count);
  }
}
'
