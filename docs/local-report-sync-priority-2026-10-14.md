# Priorité aux modifications locales du rapport

## Diagnostic

La capture fournie montre `NOTE_PAGE_REVISION_CONFLICT` sur `Sanitaires-Notes`, page 0 : la révision attendue par l’appareil diffère de celle du serveur. La copie de secours est indépendante de la résolution du conflit. Sans les journaux du serveur et l’état de cet appareil, l’auteur de la modification concurrente ne peut pas être identifié.

Le moteur arbitrait ensuite entre les heures `updated_at` locale et `updatedAt` serveur. Une date absente ou identique laissait un conflit manuel ; une date serveur plus récente remplaçait la note locale. Une écriture ou migration côté serveur ne mesure pourtant pas la fraîcheur du travail de l’ergothérapeute.

## Correction

Les modifications locales en attente du rapport sont prioritaires après une nouvelle lecture vérifiée du serveur. Les notes, les champs du bénéficiaire/logement/dossier, les rubriques secondaires et les préconisations conservent leurs valeurs locales lors de la préparation de la prochaine écriture conditionnelle. Les brouillons de préconisations restent présents.

Les listes utilisant le contrat moderne `collections-v2` peuvent être reprises après comparaison vérifiée. Les listes anciennes sans ce contrat restent disponibles pour une résolution explicite ; elles ne reçoivent pas automatiquement une capacité absente à leur création.

Pour les notes, la reprise automatique concerne uniquement les conflits de révision. Elle vérifie le propriétaire courant, le dossier, le bénéficiaire, la page et les empreintes de la note et de l’opération. Elle utilise aussi l’adresse historique de la note quand elle est vérifiée. Une saisie pendant la lecture invalide la reprise et reste conservée. Un changement de compte, une adresse différente, une révision absente ou invalide ou un échec de lecture empêchent la reprise sans remplacer le contenu local.

Les conflits de notes déjà présents sont examinés au prochain cycle en ligne et remis en attente uniquement si ces vérifications réussissent. Aucun stockage local de bénéficiaire réel n’a été modifié pendant ce développement.

Les écritures restent conditionnelles : si le serveur change entre la lecture et l’envoi, il renvoie encore un conflit, puis le moteur prépare une nouvelle tentative locale pour un cycle suivant. Il n’y a pas d’écriture sans contrôle de révision ni de boucle de tentatives immédiates.

## Validation

Les tests couvrent les horloges serveur plus anciennes, plus récentes, identiques et absentes, l’adresse historique, les modifications pendant la lecture, le changement de session, le mauvais dossier, les révisions invalides, les échecs de lecture, la reprise d’un conflit existant et une nouvelle course côté serveur. Ils vérifient aussi les préconisations et leurs brouillons, la priorité d’une mutation moderne de collection et le maintien du blocage d’une mutation ancienne.

Les scénarios sont intégrés à `test_sync_critical.sh` pour les prochaines validations CI. La publication de la branche et de la PR ne déploie pas la nouvelle version sur les appareils.
