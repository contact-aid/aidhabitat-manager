# Reprise explicite des sauvegardes locales

## Incident et decision

Le build web 26 corrige la reutilisation des identifiants d'operations terminees,
mais laisse une revue reservee aux administrateurs pour les operations deja
ambigues. Une ergotherapeute ne peut donc pas lever ce blocage historique seule.
Confirmation explicite de l'utilisateur : les saisies concernees sont bien
celles de sa collegue dans son profil navigateur.

## Correctif

- Revue accessible a un utilisateur local actif, sans changement de role.
- Confirmation individuelle, jamais automatique au login ou au rechargement.
- Aucun contenu, nom de beneficiaire ou identifiant local expose dans la revue
  non-admin ; seuls le type et l'etat de l'operation sont presentes.
- Reprise non-admin uniquement si proprietaire et candidat sont absents ou
  correspondent au compte actif. Un autre compte connu reste protege.
- Transaction SQLite : comparaison exacte du contenu scelle, date, statut,
  proprietaire, candidat et etat d'attribution ; verification de la session
  et de son epoch ; attribution et conservation du snapshot dans l'historique.
- L'historique conserve le contenu scelle, l'ancien proprietaire et, dans
  `reason`, un evenement JSON avec compte confirmant, candidat et etat precedents.
- Aucun changement du contenu ou statut de la file, aucun effacement de saisie.
- La confirmation demande ensuite la synchronisation habituelle. Elle ne vaut
  pas confirmation NocoDB : droits serveur, conflits et erreurs restent actifs.
- Les operations deja en cours ne peuvent pas etre reprises.

## Verification

Donnees synthetiques exclusivement, aucune modification NocoDB de production.

- Tests cibles : 46 reussis (ecran de revue, diagnostic ownership et ownership).
- Analyse Flutter des quatre fichiers Dart modifies/ajoutes : aucune anomalie.
- Tests ajoutes : reprise non-admin sans exposition de valeurs, compte inchange,
  snapshot conserve, payload/candidat/proprietaire/statut/session/activation
  modifies avant confirmation, echec d'historique avec rollback, reprise de
  metadata absentes, rejeu sans double historique, isolation d'un autre compte.
- Suite services elargie et ecran de revue : 743 tests reussis.
- Les controles CI sont executes avant publication ; leurs resultats sont
  conserves dans les journaux de livraison.

## Limites et retour arriere

Pas de validation sur le navigateur de la collegue depuis ce poste. La fin de
son blocage depend de la confirmation locale puis de l'acceptation serveur.
Un contenu illisible ou un conflit metier n'est pas repare par l'attribution.
L'historique est local, pas un journal d'audit central signe. Ce correctif ne
constitue pas une autorisation serveur ni une verification externe d'identite.

Pas de migration de schema. Un retour a l'image web 26 reste possible ; les
attributions deja confirmees et l'historique utilisent le schema existant.
Le correctif doit etre integre sur main avant les prochaines livraisons pour
eviter une regression de l'interface de reprise. Aucun correctif media non
publie du build 25 n'est embarque dans cette branche de hotfix.
