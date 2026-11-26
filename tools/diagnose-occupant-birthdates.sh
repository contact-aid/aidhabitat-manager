#!/usr/bin/env bash
# Diagnostic en lecture seule : pour les bénéficiaires dont le nom contient
# NAME, compare les colonnes de dates de naissance avec les dates de la liste
# des occupants (occupants_json). N'affiche AUCUNE date réelle : seulement le
# format (chiffres remplacés par 9) et si les deux sources sont identiques.
#
# Depuis le Mac :
#   ssh root@157.180.20.97 "NAME=RENOUX bash -s" < tools/diagnose-occupant-birthdates.sh

set -euo pipefail
NAME="${NAME:?NAME requis}"
API="$(docker ps --format '{{.Names}}' | grep -i 'aidhabitat-api' | head -1)"
[ -n "$API" ] || { echo "Conteneur API introuvable." >&2; exit 1; }

docker exec -e NAME="$NAME" "$API" node --input-type=module -e '
const url = process.env.NOCODB_API_URL.replace(/\/+$/, "");
const headers = { "xc-token": process.env.NOCODB_API_TOKEN };
const get = async (path) => { const r = await fetch(url + path, { headers });
  if (!r.ok) throw new Error("HTTP " + r.status + " " + path); return r.json(); };
const tables = (await get("/api/v2/meta/bases/" + process.env.NOCODB_BASE_ID + "/tables")).list;
const table = tables.find((t) => /^b[eé]n[eé]ficiaires$/i.test(t.title));
if (!table) throw new Error("table Beneficiaires introuvable");
const where = encodeURIComponent("(nom,like,%" + process.env.NAME + "%)");
const rows = (await get("/api/v2/tables/" + table.id + "/records?where=" + where + "&limit=10")).list;
const shape = (v) => v == null ? "(vide)" : String(v).replace(/\d/g, "9");
console.log("Fiches trouvées :", rows.length);
for (const row of rows) {
  let occ = null;
  try { occ = row.occupants_json ? JSON.parse(row.occupants_json) : null; } catch { occ = "illisible"; }
  const o = Array.isArray(occ) ? occ : [];
  console.log("--- fiche Id", row.Id, "| révision présente :", Boolean(row.app_sync_revision));
  console.log("occupants_json :", occ === "illisible" ? "illisible" : (Array.isArray(occ) ? o.length + " occupant(s)" : "(vide)"));
  for (const [i, col] of [[0, "date_naissance_monsieur"], [1, "date_naissance_madame"]]) {
    const colValue = row[col];
    const occValue = o[i]?.birthDate;
    console.log(col, ": colonne", shape(colValue), "| occupant", i + 1, shape(occValue),
      "| identiques :", (colValue ?? "") === (occValue ?? ""));
  }
}
'
