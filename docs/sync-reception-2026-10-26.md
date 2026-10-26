# Reprise de la réception après coupure réseau

## Périmètre vérifié

Base GitHub : `13bcfac`, web public build 96. L’iPad signalé utilise TestFlight 1.0.0 build 72. Les cinq captures montrent trois comparaisons de logement bloquées sur `levels`, un conflit de pièces issu d’une ancienne version et un bandeau global de conflit. Les défauts ci-dessous sont reproduits avec des données fictives, sans recopier les identités ni les informations personnelles des captures.

Le moteur conserve les écritures dans SQLite, les pousse via l’API avec contrôles de révision, puis récupère les dossiers. La récupération est événementielle : démarrage, retour au premier plan, retour réseau ou demande manuelle. Le correctif garde ce fonctionnement et la protection des données locales par les repositories.

## Blocage confirmé par les captures

`mapHousing` renvoyait `levels: undefined` lorsque `nombre_niveaux` était vide. La sérialisation JSON supprimait cette clé ; le contrôle strict de comparaison Flutter bloquait alors tout le dossier avec « Valeur distante absente pour levels ». Le serveur renvoie désormais `levels: null`, sans modifier la donnée stockée. Le test HTTP couvre valeur absente, null, vide, zéro et valeurs numériques. Le test Flutter couvre la comparaison puis la conservation explicite d’un ancien logement avec toutes ses pièces et l’historique de la mutation.

Le build 72 ne possède pas le contrat moderne de listes : le correctif API rend la comparaison lisible, mais sa mise à jour reste nécessaire avant de reprendre ces anciennes listes. Aucune reprise forcée des collections anciennes n’est ajoutée.

## Défauts reproduits et corrections

- La préparation de session distante était ignorée lorsque la file locale était vide. La réception demandée attend désormais aussi la préparation de session.
- La demande de réception était consommée avant la lecture et perdue si cette lecture échouait. Elle reste maintenant demandée et repart avec le délai progressif du moteur.
- Une nouvelle demande pendant une lecture était consommée sans exécution. Elle est conservée et exécutée après la lecture en cours, après drainage des nouvelles écritures locales.
- Une lecture qui se termine après une déconnexion ne peut pas réactiver l’ancienne session.

Aucun changement de schéma, suppression de file ou réécriture des dossiers de production. Aucun changement du protocole de conflit ou de priorité des valeurs. Les opérations échouées ne sont pas abandonnées.

## Validation

Les trois premiers scénarios échouaient avant correction et passent après correction. Deux scénarios supplémentaires couvrent la déconnexion pendant la lecture et le démarrage hors ligne sans écriture locale. Les 876 tests de `test_sync_critical.sh` passent. Les contrôles de flux critiques et de contrats statiques passent.

## Livraison

Version candidate : `1.0.0+97`. La distribution web et la distribution native sont distinctes. Une archive iOS non signée ne constitue pas une livraison TestFlight. Le Mac utilisé ne possède pas Xcode configuré ni de profils de signature identifiés. La recette du dossier témoin iPad/web doit être effectuée avant diffusion native selon `protocole-version-stable.md`.

Conserver l’installation iPad et ses données locales. La sauvegarde serveur ne contient pas les écritures encore présentes uniquement sur l’iPad. La reprise des erreurs existantes devra être vérifiée sur cet appareil après mise à jour, en contrôlant les dossiers signalés.
