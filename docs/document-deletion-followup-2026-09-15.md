# Suppression documentaire - suivi du build 23

Signalement : document supprime sur iPad build 23 puis reapparu dans l'espace documentaire. Le parcours exact sur appareil n'a pas ete reproduit et les donnees de production n'ont pas ete modifiees.

## Defauts corriges

- Une liaison distante exige un DELETE meme si le document est pendingSync ou en erreur apres une modification. Le statut synced n'est plus utilise comme preuve exclusive d'existence distante.
- La lecture de la liaison, le masquage local et la mise en file de suppression sont transactionnels.
- Les identites supprimees restent memorisees par patient apres purge de la ligne locale ; un ancien resultat de liste ne peut plus la recreer. Un nouveau document portant le meme titre reste autorise.
- Un upload en cours reste suivi. La suppression attend sa fin et cible son identifiant client stable, plutot que l'ancien UUID de contenu. Une reprise d'upload ne renvoie pas les fichiers marques pending_delete.
- Un HTTP 2xx de suppression doit contenir success=true et data.deleted=true. Sinon la suppression n'est pas acquittee. Le 404 conserve le comportement idempotent existant.

## Verification

14 nouveaux tests couvrent notamment les etats synced/pendingSync/error, les listes anciennes apres purge, le nouvel identifiant avec meme titre, le cloisonnement par patient, les uploads en cours et les acquittements negatifs/incomplets.

Tests executes dans /private/tmp/appergo-document-deletion-fix pour eviter le probleme de generation Flutter lorsque le chemin du projet contient une apostrophe.

Validation finale : 822/822 tests Flutter reussis, analyse Flutter sans anomalie et git diff --check reussi.

## Limites

Correctif client local, sans deploiement, nouveau build ou modification NocoDB/Airtable. Une nouvelle livraison iPad est necessaire pour l'activer sur l'appareil. La suppression effective du document signale sur le serveur n'a pas ete verifiee. Les courses multi-appareils et une requete HTTP traitee tres tardivement par le serveur apres timeout restent a verifier sur un environnement dedie.
