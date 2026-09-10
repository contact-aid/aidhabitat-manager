# Retour agent 3 - Compression d'images hors interface (F12)

## Statut

Implémentation terminée dans un worktree isolé, sans commit, push, merge,
déploiement, accès à des données réelles ni modification du dépôt source.

- Worktree : `/Users/aidhabitat/Downloads/aid-habitat-manager-agent-3`
- Branche : `codex/audit-image-compression`
- Base : `10df5d4c289ffe757af6027f0be0f670fa8f97b7`

## Constat vérifié

Le constat F12 est confirmé : `compressImageForUpload` était une fonction
`async`, mais `image.decodeImage`, `image.copyResize` et `image.encodeJpg`
s'exécutaient synchroniquement dans l'isolate appelant. Sur une cible native,
ce travail CPU pouvait donc bloquer l'isolate d'interface pendant toute la
transformation.

## Implémentation

Le décodage, le redimensionnement et l'encodage sont maintenant regroupés
dans un callback top-level exécuté avec `compute`. Sur iOS, macOS et les autres
cibles natives, Flutter exécute ce callback dans un isolate distinct. Les
préconditions, décisions de repli et métadonnées restent dans
`image_compressor.dart`.

Le contrat et la politique existants sont conservés :

- même signature publique et même type `CompressedImage` ;
- mêmes options, seuil de 200 Kio, largeur de 1600 px et qualité JPEG 80 ;
- même interpolation cubique ou linéaire selon `fastResize` ;
- mêmes détections de formats, noms, extensions et types MIME ;
- même repli sur les octets originaux en cas de format non pris en charge,
  d'échec de décodage, d'exception ou de résultat plus gros que l'original.

Le chemin web compile, mais `compute` ne garantit pas un traitement hors du
thread principal sur web : son callback s'exécute sur la même boucle
d'événements. Cette modification cible donc uniquement le blocage des cibles
natives.

## Fichiers modifiés ou ajoutés

- `aid_habitat_app/lib/services/image_compressor.dart` : appel du worker avec
  `compute`, contrat et replis inchangés.
- `aid_habitat_app/lib/services/image_compression_worker.dart` : nouveau
  worker CPU limité au décodage, redimensionnement et encodage.
- `aid_habitat_app/test/services/image_compressor_worker_test.dart` : tests
  synthétiques et oracle reproduisant l'ancienne implémentation.
- `docs/retour-agent-3.md` : présent rapport.

## Vérifications

### Analyse statique

Commande :

```text
flutter analyze lib/services/image_compressor.dart lib/services/image_compression_worker.dart test/services/image_compressor_worker_test.dart
```

Résultat : succès, aucun problème signalé.

Commande :

```text
git diff --check
```

Résultat : succès.

### Reproduction automatisée

Les tests utilisent exclusivement des images synthétiques, sans réseau ni
service distant. Chaque sortie du nouveau chemin est comparée octet par octet
à une copie de référence de l'algorithme antérieur, avec comparaison du MIME,
du nom et de `wasRecompressed`.

Cas couverts : fichier JPEG sous le seuil, grande image redimensionnée, PNG,
`fastResize` activé et désactivé, données invalides non décodables, résultat
JPEG plus gros que le PNG original et cohérence octets/MIME/extension.

Commande dédiée avec `TMPDIR` isolé :

```text
TMPDIR=$(mktemp -d /tmp/aid-agent3-image-tests.XXXXXX) tool/test_safely.sh test/services/image_compressor_worker_test.dart
```

Résultat final : 8 tests réussis sur 8.

Commande suite complète avec un second `TMPDIR` isolé :

```text
TMPDIR=$(mktemp -d /tmp/aid-agent3-full-tests.XXXXXX) tool/test_safely.sh
```

Résultat : 148 tests réussis sur 148.

Commande de compatibilité web :

```text
flutter build web --release
```

Résultat : build web réussi. Le dry-run Wasm affiche uniquement les
incompatibilités déjà présentes dans d'autres dépendances et services web.

### Mesures locales

Sur la même image JPEG synthétique 1800 x 1000, un passage dédié a mesuré
931 ms pour l'ancien chemin et 1030 ms pour le worker, avec 205 réveils d'un
timer de 5 ms dans l'isolate appelant. Pendant la suite complète, une seconde
mesure a donné 1078 ms contre 1037 ms, avec 204 réveils.

Ces nombres ne constituent pas un benchmark : ils montrent séparément que le
temps total peut inclure un coût d'isolate et que l'isolate appelant continue
à traiter sa boucle d'événements pendant le travail CPU.

### Validation sur appareil

Aucune validation sur iPad ou appareil physique n'a été réalisée. Les tests
VM natifs prouvent la parité fonctionnelle et l'activité de l'isolate appelant,
mais ne permettent pas de conclure à eux seuls à la fluidité de l'interface
sur iPad.

## Limites et intégration

- Le coordinateur doit intégrer uniquement les quatre fichiers listés, puis
  retester avec les changements F01 et vignettes absents de la base de cet
  agent.
- Un test terrain iPad avec plusieurs photos réelles volumineuses reste requis
  pour mesurer les temps, la mémoire et la fluidité pendant l'import.
- La rotation, les annotations, les previews, PDFKit et les repositories n'ont
  pas été modifiés.
- La conservation du format après rotation et toute évolution de la politique
  de compression restent des besoins séparés de F12.
- Aucun `pubspec.yaml` ni lockfile n'a été modifié.

## Relecture et integration du coordinateur - 9 septembre 2026

Les quatre fichiers ont ete relus et integres localement dans le repertoire
principal, sans remplacer les autres changements en cours. Aucun changement
supplementaire de l'algorithme de production. Deux tests ajoutes : PDF hors
formats supportes conserve tel quel, et retour aux octets originaux apres
une erreur effectivement levee par le worker (dimension invalide). Le timer
du test de reactivite est desormais nettoye dans un finally.

Validation combinee : 181 tests Flutter reussis, dont 10 pour ce compresseur,
avec TMPDIR unique ; flutter analyze --no-pub sans probleme ; format des
trois fichiers Dart valide. Mesure synthetique dans cette suite : 859 ms
ancien chemin, 869 ms worker, 173 ticks de timer. Pas un benchmark iPad.
Le build web mentionne plus haut est celui execute par l'agent ; il n'a pas
ete relance par le coordinateur. Aucun build natif ou deploiement effectue.

Limite importante constatee en suivant les appelants : les usages actuels de
compressImageForUpload dans Documents et Photos VAD sont les branches web ou
le drag-and-drop. file_drop_listener_io.dart est un no-op. Les captures et
imports photo natifs passent par image_picker puis la persistence native,
sans appeler ce compresseur. Le test VM prouve donc une capacite du service,
pas une amelioration d'un parcours iPad actuellement branche sur ce service.
Sur web, compute conserve le CPU sur la boucle principale : le freeze de
compression web n'est pas corrige. F12 reste PARTIEL, et ce changement ne
doit pas etre presente comme une correction des freezes de rotation/save.
Pas de nouvelle compression native ajoutee pour eviter de changer la qualite
ou de recompresser des fichiers deja traites par image_picker.
