# Actualisation des dossiers Airtable

Le bouton « Actualiser » importe `Etape` et `Date envoi dossier` depuis Airtable
vers `dossiers.airtable_stage` et `dossiers.airtable_report_sent_date` dans NocoDB.
Ces deux champs ainsi que `visit_date` suivent Airtable à chaque actualisation,
y compris un rendez-vous reporté ou une suppression de date. Les champs du relevé
et les statuts manuels restent conservés.

Le classement des dossiers actualisés utilise ces règles, dans cet ordre :

- Un dossier annulé reste exclu des trois sections.
- Une date d’envoi renseignée place le dossier dans « Rapport envoyé ».
- Un rendez-vous antérieur à aujourd’hui place le dossier sans envoi dans
  « Rapport à faire », quelle que soit son étape.
- Un rendez-vous aujourd’hui ou à venir apparaît dans « Visite à faire »
  pour les étapes `1a. Rendez-vous à Prendre` et `1b. Rendez-vous pris`.
- Une date de rendez-vous absente ou illisible exclut les deux sections à faire.

La comparaison des jours utilise Europe/Paris. Le basculement intervient dès le
lendemain de la visite. La liste et les panneaux du tableau de bord utilisent la
même fonction de classement. Les dossiers sans métadonnées Airtable gardent leur
classement par statut, avec une date passée obligatoire pour les rapports à faire.

Les nouveaux imports conservent le périmètre validé des rendez-vous depuis le
1er août 2026, non annulés. Les dossiers déjà importés sont actualisés même si leur
rendez-vous est plus ancien, supprimé, ou si le dossier a été annulé depuis.

Avant de déployer l’API, lancer `npm run nocodb:bootstrap-mobile-schema` avec la
configuration NocoDB de la cible pour ajouter les deux colonnes texte.
La migration locale SQLite 27 est automatique et conserve les dossiers existants.
Déployer ensuite l’API et le client Flutter, puis utiliser « Actualiser » pour
prévisualiser et appliquer les métadonnées des dossiers sélectionnés.
