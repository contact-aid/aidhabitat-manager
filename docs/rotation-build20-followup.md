# Rotation : suivi du signalement build 20

Signalement : image reduite apres rotation puis retour a l'ancien contenu avec
pastille verte. Aucun acces au document reel de l'utilisateur.

Branche dediee depuis f813402, sans les changements de securite Apple.
Le correctif d'export source f358cdb est repris et adapte aux changements
b390bea : dimensions originales, sans capture des marges de l'interface.

Un defaut supplementaire est reproduit dans le depot : sans marqueur de
version issu d'un pull precedent, une reponse ancienne peut remplacer le
contenu apres un ACK d'upload et la cloture de son operation. Trois tests
echouaient avant correction : date absente, ancienne et plus recente.

Le stockage de l'ACK memorise maintenant les identites de contenu remplacees
dans la meme transaction. La fusion ignore ces identites obsoletes, meme
apres recreation du repository. Une nouvelle identite reste acceptee.
Cette protection repose sur les chemins de contenu immuables du serveur.
Une panne d'ecriture du marqueur annule aussi la nouvelle liaison distante ;
elle ne supprime pas l'operation de synchronisation.

Validation locale : 78 tests cibles passes (revisions, exports image, PDF,
relocation, upload et sauvegarde par page). Aucun build ou deploiement.

Limites : ce scenario reproduit un mecanisme compatible avec le signalement,
pas une preuve issue des journaux de l'iPad. Le build 20 installe est inchange.
Un nouvel essai TestFlight doit verifier dimensions, orientation apres plusieurs
cycles de synchronisation, reouverture et reprise offline sur document fictif.
