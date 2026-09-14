# Audit d'ecart documentaire - publication publique App'Ergo

**Date de l'audit :** 14 septembre 2026  
**Perimetre :** publication iOS/iPadOS publique et exploitation professionnelle multi-entreprises  
**Nature :** audit documentaire et statique du depot, sans acces aux comptes Apple, aux donnees reelles, aux secrets ni a l'infrastructure de production

## 1. Conclusion executive

**Verdict documentaire : ouverture publique non prete.** Le depot contient plusieurs briques techniques utiles (authentification propre, roles administrateur/ergotherapeute, controle d'acces serveur, stockage local chiffre, descriptions de permissions, privacy manifest et lien de confidentialite dans l'application), mais il ne prouve pas encore un dispositif commercial, Apple et RGPD complet pour un service multi-entreprises traitant potentiellement des donnees de sante.

Les principaux blocages sont : choix de distribution et de facturation non tranche, absence de preuve d'une politique de confidentialite effectivement publiee et complete, absence de parcours de suppression du compte, activation par lien temporaire non implementee dans le parcours inspecte, dossier App Review non constitue, qualification des roles RGPD et des bases articles 6/9 non realisee, AIPD non produite, sous-traitants et transferts non inventories contractuellement, et applicabilite HDS non tranchee avec preuve de certification de toute la chaine d'hebergement. Le minimum iOS `26.5` configure dans le projet doit aussi etre corrige ou justifie avant toute archive publique, car il restreindrait fortement les appareils compatibles.

Cet audit ne garantit ni l'acceptation par Apple ni la conformite juridique. Les conclusions RGPD, HDS, contractuelles et fiscales doivent etre validees par un professionnel juridique et/ou un DPO connaissant le service reel.

## 2. Hypotheses et methode

Le modele envisage est une application telechargeable publiquement, avec creation d'une entreprise, administrateur, quota d'ergotherapeutes, activation par lien temporaire, donnees de beneficiaires pouvant inclure des informations de sante et facturation encore indeterminee.

L'analyse repose sur :

- l'inspection statique des ecrans de connexion et de parametres, des services d'authentification, des routes d'acces administrateur et des configurations iOS ;
- l'inspection du `PrivacyInfo.xcprivacy`, du `Info.plist`, du `Podfile`, du `Podfile.lock`, du bundle identifier et de la version applicative ;
- les documents existants de preparation Apple et de commercialisation ;
- les sources officielles Apple, CNIL et ANS listees en section 9, consultees le 14 septembre 2026.

N'ont pas ete verifies : App Store Connect, contrats clients, registre RGPD, contrats de sous-traitance, certificats HDS, infrastructure effective, politique de confidentialite servie publiquement, donnees ou comptes reels. Une tentative de controle HTTP de `https://aid-habitat.fr/privacy-policy` n'a pas abouti dans l'environnement d'audit (resolution DNS indisponible) ; son accessibilite et son contenu restent donc a prouver, sans conclure que le site est indisponible publiquement.

## 3. Preuves actuelles du depot

- Connexion : selection d'un compte local preprovisionne et saisie d'un mot de passe dans `aid_habitat_app/lib/screens/login_screen.dart`. Aucun ecran d'inscription publique, d'invitation ou d'activation par lien temporaire n'a ete trouve.
- Compte : changement de mot de passe, photo, synchronisation et deconnexion sont visibles ; aucun parcours de suppression du propre compte n'a ete trouve dans `settings_screen.dart` ou `account_dialog.dart`.
- Acces : les routes `server/routes/auth.mjs` exposent la gestion des membres sous garde administrateur. Le commentaire de `data_service.dart` indique que l'interface administrateur n'est plus exposee dans l'application et que les membres sont administres depuis NocoDB.
- Confidentialite : l'ecran Parametres pointe vers `https://aid-habitat.fr/privacy-policy`, une adresse de support et le site Aid'Habitat. Le contenu de la politique n'est pas versionne dans le depot.
- Donnees declarees : le manifest iOS declare comme liees a l'utilisateur le nom, l'email, le telephone, l'adresse, la sante, les photos/videos, d'autres informations financieres, le contenu utilisateur et l'identifiant utilisateur ; il declare aussi des donnees de crash non liees et aucun tracking.
- Permissions : `Info.plist` contient des descriptions pour camera, phototheque, ajout de photos, microphone, reconnaissance vocale et dossier Documents. Leur declenchement au seul moment du besoin doit etre teste sur l'archive.
- SDK natifs : le lockfile inclut notamment `connectivity_plus`, `DKImagePickerController`, `DKPhotoGallery`, `SDWebImage`, `SQLCipher`, `flutter_inappwebview_ios`, `image_picker_ios` et `speech_to_text`. Des manifests de confidentialite sont presents dans plusieurs Pods, mais seule l'archive finale permet de verifier la chaine complete.
- Paiement : aucune dependance StoreKit/IAP ni interface d'abonnement n'a ete identifiee. Ce constat est coherent avec un produit encore sans modele de facturation defini, mais ne permet pas une vente individuelle de fonctionnalites numeriques sans analyse Apple complementaire.
- Distribution : bundle `com.aidhabitat.manager`, version `1.0.0+20`, cible iPhone/iPad. Le projet et le Podfile imposent `IPHONEOS_DEPLOYMENT_TARGET = 26.5`.
- Chiffrement : `ITSAppUsesNonExemptEncryption` vaut `false`, alors que l'application utilise HTTPS, Keychain et SQLCipher. La reponse export-control doit etre revalidee sur le binaire et les usages reels ; le simple flag n'est pas une preuve juridique.

## 4. Matrice d'ecarts

Legende : **O** = obligation ou condition de soumission ; **R** = recommandation forte ; **M** = depend du modele commercial/juridique. La colonne « validation attendue » identifie le proprietaire de la decision ou de la preuve.

| Exigence | Applicabilite | Preuve actuelle | Ecart | Action necessaire | Validation attendue |
|---|---|---|---|---|---|
| Application finale, backend disponible et fonctions completement testables par Apple (Guidelines 2.1 et « Before You Submit ») | O | Builds/TestFlight documentes ; API de production configuree | Aucun dossier de revue complet ni preuve d'un environnement stable pendant toute la revue | Geler une version, maintenir un backend de revue, verifier tous les parcours et documenter les fonctions non evidentes | Responsable release + App Store Connect |
| Compte de demonstration actif ou mode demo complet | O pour une app avec compte | Aucun compte de demonstration fictif versionne/documente | Un reviewer ne peut pas entrer sans compte existant | Creer un tenant de demonstration isole, exclusivement fictif, avec comptes admin/ergo et donnees couvrant PDF, photos, offline/sync sans envoi reel | App Review owner + DPO pour le jeu de donnees |
| Informations App Review : contact, identifiants, instructions et ressources | O | Documentation generale uniquement | Fiche de soumission non prouvee | Rediger des notes pas-a-pas, contraintes iPad/Pencil, comportement offline, generation PDF, permissions et coordonnees joignables | App Review owner |
| Metadonnees, captures et fonctions accessibles conformes au binaire (2.3) | O | Liste indicative dans les docs | Captures, description, support URL, categorie, age rating et fonctionnalites annoncees non verifies | Constituer la fiche avec captures iPad sur donnees fictives, description exacte et URL de support operationnelle | Marketing + App Review owner |
| Choix de distribution public, prive ou non repertorie | M, decision irreversible en grande partie | Intention « publique » ; historique TestFlight | Public telechargeable et B2B reserve aux organisations ne repondent pas au meme besoin | Arbitrer avant soumission : public visible, public non repertorie par lien, ou Custom App privee via Apple Business Manager. Noter qu'un passage prive/public exige normalement une nouvelle fiche | Dirigeant + commercial + Apple account holder |
| Connexion par le systeme propre de l'entreprise | O si compte requis | Login email/mot de passe propre, sans login social | Compatible en principe avec l'exception 4.8 ; le modele d'activation cible n'est pas celui du code | Decrire que les comptes sont fournis par l'organisation ; si un login social est ajoute, reevaluer immediatement l'obligation d'une option equivalente | Produit + App Review owner |
| Inscription/creation d'entreprise | M | Aucun ecran d'inscription publique trouve | Le modele envisage annonce une creation d'entreprise, mais le produit inspecte ne la fournit pas | Decider si creation hors app par contrat/admin ou dans l'app ; aligner produit, fiche Store et contrats, sans promettre une fonction absente | Dirigeant + produit |
| Activation par lien temporaire ; mot de passe non consultable | M et engagement de securite | Auth actuelle par comptes preprovisionnes et mot de passe ; aucun lien temporaire trouve | Ecart direct avec le modele envisage | Documenter le parcours cible, duree/usage unique du lien et recuperation ; ne pas l'annoncer tant qu'il n'est pas implemente et teste | Produit + securite + DPO |
| Suppression de compte initiee dans l'app (5.1.1) | O si l'app permet de creer un compte | Aucune action de suppression du propre compte trouvee | Blocage Apple probable si inscription/creation de compte est offerte | Ajouter avant publication le parcours d'initiation, expliquer delai et consequences, reauthentifier si necessaire, confirmer la fin ; distinguer compte utilisateur, donnees d'entreprise et dossiers soumis a conservation | Produit + juridique/DPO + App Review |
| Politique de confidentialite dans App Store Connect et facilement accessible dans l'app (5.1.1) | O | Lien dans Parametres vers une URL publique supposee | Contenu et disponibilite non verifies ; pas de version documentaire dans le depot | Publier une politique complete, datee et coherente avec les traitements ; renseigner la meme URL dans App Store Connect ; tester sans connexion | Juridique/DPO + App Review |
| Contenu minimal de la politique Apple : donnees, collecte, usages, tiers, conservation/suppression, retrait de consentement | O | Manifest technique seulement | Une liste de categories Apple ne remplace pas l'information juridique | Decrire finalites, destinataires, sous-traitants, retention, suppression, droits et contact ; distinguer utilisateurs professionnels et beneficiaires | Juridique/DPO |
| App Privacy labels exacts, y compris SDK tiers | O | Manifest riche et documentation ancienne | Aucune preuve de reconciliation avec traitements serveur, email, logs et archive finale ; `CrashData` peut etre surdeclare si aucun outil actif | Faire un inventaire de flux, generer le Privacy Report Xcode de l'archive, rapprocher manifest, labels App Store et politique ; corriger sur/sous-declarations avant envoi | Release + DPO |
| Privacy manifests et signatures des SDK listes par Apple | O pour les SDK concernes | Pods concernes identifies ; manifests trouves pour DKImagePicker/PhotoGallery et plusieurs transitifs | Presence dans le repertoire Pods ne prouve ni signature ni inclusion correcte dans l'archive | Mettre a jour vers versions conformes, archiver proprement, controler les avertissements Xcode et le rapport de confidentialite ; conserver la nomenclature/version des SDK | Responsable iOS |
| Required Reason APIs correctement declarees | O | UserDefaults, FileTimestamp, SystemBootTime, DiskSpace et raisons declares | Exactitude des raisons non recertifiee face au binaire final/transitifs | Verifier chaque raison contre l'usage reel et le rapport Xcode ; aucun usage de fingerprinting | Responsable iOS + DPO |
| Absence de tracking ou ATT si tracking futur | O conditionnelle | `NSPrivacyTracking=false`, aucun SDK publicitaire direct trouve | Pas de preuve sur tous les services serveur/SDK futurs | Confirmer contractuellement aucune combinaison inter-app/site a fins publicitaires ; si cela change, revoir ATT, manifest, labels et consentement avant integration | Produit + DPO |
| Permissions limitees et sollicitees dans leur contexte | O | Purpose strings presentes | Plusieurs permissions sensibles sont declarees ; comportement reel et necessite de chacune non testes ici | Tester installation neuve, refus et revocation pour camera, photos, micro et parole ; ne demander qu'au geste utilisateur et fournir un chemin degradable | QA iPad + DPO |
| Compatibilite des appareils | O de publication/qualite | Minimum iOS `26.5`, famille iPhone/iPad | Minimum anormalement eleve et potentiellement incompatible avec le parc et le public vise | Fixer une cible minimale supportee par Flutter/plugins et par les iPad terrain ; verifier archive et matrice d'appareils | Responsable iOS + produit |
| Declaration export-control/chiffrement exacte | O | `ITSAppUsesNonExemptEncryption=false` | Flag non justifie par une analyse actualisee de HTTPS, SQLCipher et bibliotheques embarquees | Repondre aux questions App Store Connect sur le binaire exact et conserver la justification ; faire valider si une documentation export est requise | Responsable iOS + conseil juridique si doute |
| Claims de sante/medical et statut dispositif medical | M | Outil d'evaluation ergonomique et rapports ; aucune preuve de statut DM | Risque si le marketing presente diagnostic, decision clinique ou recommandations medicales au-dela de l'usage reel | Faire valider les claims, la categorie et la declaration « regulated medical device » ; fournir sources/methodologie si Apple les demande | Dirigeant + professionnel sante/juridique |
| Achats integres pour abonnement individuel | O si vente individuelle de fonctions numeriques | Aucun IAP/StoreKit | Un abonnement individuel ou single-user vendu hors IAP ne peut pas etre presume exempt | Si offre individuelle : concevoir l'abonnement IAP, conditions et restauration, ou obtenir une analyse Apple formelle avant autre parcours | Dirigeant + finance + App Store specialist |
| Contrat entreprise pour salaries (3.1.3(c)) | M avec exception Apple encadree | Comptes professionnels preprovisionnes ; aucun paiement in-app | L'exception n'est applicable que si le service est vendu directement aux organisations/groupes pour leurs salaries/etudiants ; modele non contracte | Limiter clairement l'offre B2B aux organisations, acces acquis avant connexion, aucun achat individuel dans l'app ; documenter contrat et notes de revue | Juridique/commercial + App Review |
| Coexistence B2B et offre individuelle | M, risque eleve | Facturation a definir | Une offre mixte peut rendre l'exception entreprise insuffisante | Separer SKU, droits et parcours ; faire valider par Apple/juriste avant implementation et expliquer tous les achats dans les notes de revue | Dirigeant + App Store specialist |
| Qualification responsable de traitement/sous-traitant | O RGPD | Architecture multi-utilisateur et NocoDB ; aucun schema contractuel probant | Roles non formalises par finalite | Pour les dossiers beneficiaires, determiner si l'entreprise cliente est responsable et Aid'Habitat sous-traitant ; qualifier separement comptes, securite, support, facturation et prospection | DPO/juriste |
| Contrat de sous-traitance article 28 | O si Aid'Habitat traite pour ses clients | Aucun DPA verifie | Obligations, instructions, audits, sort des donnees et sous-traitants ulterieurs non prouves | Etablir DPA, mesures, assistance droits/AIPD/incidents, suppression/restitution et liste des sous-traitants autorises | Juriste/DPO |
| Bases legales article 6 et condition article 9 pour donnees de sante | O | Le manifest reconnait les donnees de sante | Aucune base article 6 ni exception article 9 documentee ; le consentement ne doit pas etre suppose par defaut | Cartographier chaque finalite et acteur ; determiner bases et exception sante applicables, avec preuve et information adaptee | DPO/juriste + clients responsables |
| Information des ergotherapeutes et beneficiaires (articles 13/14) | O | Politique generique non verifiee | Les beneficiaires peuvent ne jamais utiliser l'app mais leurs donnees y entrer | Prevoir notices distinctes et canal d'information, avec finalites, bases, destinataires, durees, droits, transferts et reclamation CNIL | DPO + clients |
| Donnees sensibles et personnes vulnerables | O, risque eleve | Champs de sante/handicap, photos du domicile, identite/adresse | Aucun cadre documentaire de minimisation et de gouvernance prouve | Definir champs necessaires, acces par role, interdictions d'usage secondaire, formation/confidentialite et revue periodique | DPO + responsable metier |
| AIPD avant mise a disposition publique | O si risque eleve ; fortement indique ici | Aucun livrable AIPD identifie | Au moins donnees sensibles et personnes vulnerables sont presentes ; echelle et autres criteres restent a qualifier | Realiser l'AIPD avec les clients/representants metier, documenter risques, mesures et risques residuels ; consulter la CNIL si requis | DPO + responsable de traitement |
| Registre des traitements | O selon roles et contexte | Aucun registre verifie | Finalites, categories, destinataires, transferts, durees et mesures non consolides | Creer les fiches de registre Aid'Habitat comme responsable et/ou sous-traitant | DPO |
| Durees de conservation et purge | O | Mecanismes techniques de suppression existent pour certaines entites ; pas de politique globale verifiee | Pas de durees par dossiers, photos, PDF, comptes, logs, sauvegardes et files offline | Definir base active/archivage/suppression par finalite et obligation professionnelle ; implementer et tester apres validation | Juridique/DPO + metier |
| Exercice des droits et portabilite/restitution | O | Support email dans l'app | Aucun processus, delai, verification d'identite, export ou repartition client/Aid'Habitat prouve | Etablir procedure et SLA, registre des demandes, formats d'export, transmission au responsable et exceptions documentees | DPO + support |
| Violation de donnees et notification | O | Audits securite separes, non repris ici | Processus organisationnel et chaine client/sous-traitants non prouves | Formaliser detection, qualification, notification au client, registre et aide aux notifications CNIL/personnes | DPO + securite + clients |
| Sous-traitants, localisation et transferts | O | NocoDB, API/hosting, email et stockage sont techniquement evoques | Liste juridique, societes, lieux, DPA, garanties et transferts hors EEE non prouves | Inventorier toute la chaine (hebergement, sauvegarde, email, support, logs, Apple), verifier contrats, pays, acces distant et mecanismes de transfert | DPO/juriste |
| Necessite de designer un DPO | M selon activites, echelle et suivi regulier | Aucun statut verifie | Decision non documentee | Evaluer les criteres de designation obligatoire et, a defaut, nommer un referent competent ; documenter l'analyse | Dirigeant + juriste |
| Qualification HDS des donnees et du contexte de recueil | M juridique, potentiellement O | Donnees de sante/handicap et activite d'ergotherapeute | Le contexte exact (prevention, diagnostic, soins, suivi social/medico-social) n'est pas tranche | Documenter qui recueille, dans quelle mission et pour le compte de qui ; obtenir un avis HDS specialise | Juriste sante/DPO |
| Certification HDS de la chaine d'hebergement | O si le champ HDS s'applique | Aucune preuve de certificat ni de perimetre pour Aid'Habitat et fournisseurs | EU/France ou chiffrement ne remplacent pas une certification HDS ; administration et sauvegarde peuvent entrer dans le perimetre | Obtenir certificats HDS v2 valides, activites couvertes, sites, sous-traitants et chaine contractuelle ; sinon changer d'architecture/fournisseur avant donnees reelles | Dirigeant + RSSI/DPO + conseil HDS |
| Contrats HDS et exigences de localisation/souverainete v2 | O si HDS | Aucun contrat verifie | Perimetre, reversibilite, localisation et acces hors EEE non prouves | Contractualiser selon le CSP et le referentiel v2, verifier la date et le champ de chaque certificat | Juriste HDS + RSSI |
| CGU/CGV, DPA, SLA, support et fin de contrat multi-entreprises | M commercial, souvent indispensable | Architecture commerciale technique seulement | Quotas, responsabilites admin, suspension, restitution, facturation et sortie non definis | Rediger corpus contractuel coherent avec distribution Apple, droits RGPD, HDS, disponibilite, assistance et reversibilite | Juriste + dirigeant + commercial |

## 5. Obligations, recommandations et decisions de modele

### Obligations avant soumission ou ouverture

- Fournir a Apple un binaire final, un backend disponible, un compte de demonstration actif et des donnees fictives permettant la revue complete.
- Renseigner une politique de confidentialite publique, accessible dans l'app et dans App Store Connect, coherente avec les labels et les SDK.
- Si l'app permet la creation de compte, permettre d'initier sa suppression depuis l'app et traiter le compte complet, sous reserve des conservations legalement justifiees.
- Declarer exactement les pratiques de donnees, les required reason APIs, les SDK tiers et l'usage du tracking ; tester les permissions au moment du besoin.
- Utiliser les achats integres pour une vente individuelle de fonctionnalites ou abonnements numeriques sauf base Apple clairement applicable ; ne pas etendre automatiquement l'exception entreprise.
- Identifier les roles RGPD, bases article 6, condition article 9, information, droits, conservation, contrats article 28 et sous-traitants.
- Qualifier HDS avant d'heberger des donnees reelles dans le contexte vise et, si applicable, utiliser une chaine certifiee dans le perimetre requis.

### Recommandations fortes

- Realiser une soumission TestFlight/external beta sur le meme parcours de demonstration avant la revue publique.
- Produire et archiver le Privacy Report Xcode du binaire exact avec la nomenclature des SDK.
- Realiser l'AIPD avant la commercialisation, meme si l'echelle initiale est faible, compte tenu des donnees sensibles, des photos de domicile et des personnes potentiellement vulnerables.
- Creer un dossier de preuves versionne : politiques, registre, DPA, sous-traitants, certificats HDS, tests de droits, tests de suppression, incidents et decisions Apple.
- Ne pas mettre de donnees reelles dans le compte de demonstration et neutraliser tout email, webhook ou partage externe involontaire.

### Questions dependant du modele commercial

- Une offre strictement vendue aux entreprises pour leurs salaries peut relever de la section 3.1.3(c), mais une offre individuelle, familiale ou single-user doit utiliser les achats integres pour l'acces numerique.
- Une app publique, une app non repertoriee et une Custom App privee n'ont pas la meme decouvrabilite ni les memes moyens de distribution. Le choix doit preceder la fiche finale, car le passage public/prive impose normalement une nouvelle app.
- Si seuls des comptes entreprise existants se connectent au systeme propre d'Aid'Habitat, l'exception de la section 4.8 est pertinente. Ajouter Google/Microsoft ou un autre login social obligerait a reevaluer l'option de connexion equivalente.
- La suppression d'un compte ergotherapeute ne signifie pas automatiquement l'effacement des dossiers de l'entreprise ; les responsabilites, bases de conservation et modalites de restitution doivent etre definies contractuellement et expliquees a l'utilisateur.

## 6. Preparation App Review recommandee

Le dossier de revue devrait contenir, avant soumission :

1. Un compte administrateur de demonstration et au moins un compte ergotherapeute, dans une entreprise fictive isolee.
2. Des beneficiaires fictifs, clairement marques comme tels, avec exemples de notes, photos generees/non identifiantes, plan et rapport PDF.
3. Un guide court couvrant connexion, mode hors ligne, synchronisation, creation/modification d'un dossier, permissions, export PDF et deconnexion.
4. L'explication qu'aucun achat n'est disponible dans l'app si le modele est strictement B2B, avec la nature du contrat entreprise et l'absence de vente single-user.
5. Les coordonnees d'une personne capable de repondre pendant la revue et un backend disponible durant toute la periode.
6. Les liens fonctionnels vers confidentialite, support et, le cas echeant, suppression de compte.
7. Des captures conformes au binaire et exclusivement composees de donnees fictives.
8. La justification du statut medical ou non medical des fonctionnalites et claims.

## 7. Qualification HDS

Le referentiel HDS v2 distingue quatre conditions : qualite de sous-traitant, donnees personnelles de sante, recueil lors d'activites de prevention/diagnostic/soins/suivi social ou medico-social, et realisation d'une ou plusieurs activites d'hebergement (infrastructure physique/virtuelle, plateforme, administration/exploitation, sauvegarde). Les informations de handicap sont des donnees de sante selon la CNIL.

Il n'est donc pas possible de conclure « HDS non applicable » parce que l'application est un outil d'adaptation du logement, ni « HDS conforme » parce que les donnees sont chiffrees ou hebergees en Europe. Il faut qualifier la mission concrete de l'ergotherapeute, l'origine du recueil, le donneur d'ordre, le role d'Aid'Habitat et toutes les prestations techniques. Si HDS s'applique, les certificats HDS v2 doivent couvrir les activites et la chaine reellement utilisees ; depuis le 16 mai 2026, la transition annoncee par l'ANS vers HDS v2 est achevee pour les hebergeurs deja certifies.

## 8. Blocages avant ouverture publique

1. **Modele de distribution et de paiement non decide** : public, non repertorie ou Custom App ; B2B strict ou offre individuelle ; IAP le cas echeant.
2. **Parcours de compte non aligne au modele annonce** : aucune inscription/creation d'entreprise ni activation par lien temporaire dans les ecrans inspectes ; aucune suppression de compte initiee dans l'app.
3. **Politique de confidentialite et fiche Apple non prouvees** : contenu, disponibilite, labels, support, metadonnees, age rating, export-control et claims restent a valider.
4. **App Review non preparée** : absence de tenant demo fictif, identifiants, instructions et preuve de backend de revue.
5. **Cadre RGPD incomplet** : roles, articles 6/9, notices, DPA, registre, retention, droits, sous-traitants, transferts, incidents et DPO non prouves.
6. **AIPD non realisee** malgre la presence de donnees sensibles et de personnes potentiellement vulnerables.
7. **HDS non qualifie** et absence de preuve de certification v2 de la chaine d'hebergement, d'administration et de sauvegarde.
8. **Cible iOS `26.5` a corriger ou justifier**, puis tester sur le parc iPad vise.
9. **Conformite SDK/archive non prouvee** : signatures, manifests transitifs, required reasons et Privacy Report doivent etre controles sur le binaire exact.

## 9. Questions indispensables au dirigeant

1. Qui achete le service : uniquement des personnes morales pour leurs salaries, ou aussi des independants et particuliers ?
2. La creation d'entreprise et le paiement auront-ils lieu dans l'app, sur le web, ou uniquement apres signature d'un contrat commercial ?
3. L'app doit-elle etre visible par tous, seulement accessible par lien, ou distribuee a des organisations identifiees via Apple Business Manager ?
4. Qui peut creer, suspendre et supprimer un compte ; que devient le quota et qui recupere les dossiers au depart d'un salarie ?
5. Quelle entite juridique contracte, facture, fournit le support et est affichee comme vendeur Apple ? Dans quels pays l'offre sera-t-elle disponible ?
6. Pour chaque client, qui determine les finalites et moyens des dossiers beneficiaires : le client, Aid'Habitat ou les deux ?
7. Quelle base article 6 et quelle condition article 9 sont retenues pour chaque finalite ? Le consentement est-il reellement libre et necessaire, ou une autre base est-elle applicable ?
8. Les evaluations sont-elles realisees dans une activite de prevention, diagnostic, soins ou suivi social/medico-social, et pour le compte de qui ?
9. Quels fournisseurs hebergent ou peuvent acceder aux bases, fichiers, sauvegardes, logs, emails et support ; dans quels pays et avec quels certificats HDS v2 ?
10. Quelles durees s'appliquent aux dossiers, photos, PDF, comptes, journaux, sauvegardes et appareils hors ligne apres fin de contrat ?
11. Qui recevra et executera les demandes d'acces, rectification, limitation, opposition, portabilite et effacement des utilisateurs et beneficiaires ?
12. Un DPO est-il designe et qui pilotera l'AIPD, le registre, les contrats article 28 et la gestion des violations ?
13. L'application est-elle presentee comme outil administratif/ergonomique ou formule-t-elle des claims de diagnostic, de soin ou de decision clinique ?
14. Quel minimum iPadOS correspond au parc client reel et aux appareils que l'entreprise s'engage a supporter ?
15. Quel compte de demonstration, quelles donnees fictives et quel environnement seront maintenus pendant la revue Apple ?

## 10. Sources officielles

Toutes les sources ci-dessous ont ete consultees le **14 septembre 2026**.

### Apple

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) : « Before You Submit », sections **2.1 App Completeness**, **2.3 Accurate Metadata**, **3.1.1 In-App Purchase**, **3.1.3(c) Enterprise Services**, **4.8 Login Services**, **5.1.1 Data Collection and Storage**.
- [Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/) : initiation dans l'app, suppression du compte complet, delais et cas reglementes.
- [User Privacy and Data Use](https://developer.apple.com/app-store/user-privacy-and-data-use/) : declaration App Store Connect, responsabilite sur le code tiers et tracking.
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/) : categories et finalites a declarer dans la fiche App Store.
- [Third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/) : manifests et signatures obligatoires pour les SDK listes, dont plusieurs presents dans le projet.
- [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) : raisons approuvees et refus des soumissions incompletes.
- [Set distribution methods](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/set-distribution-methods/) : distribution publique, privee via Apple Business Manager et changement de methode.
- [Unlisted app distribution](https://developer.apple.com/support/unlisted-app-distribution/) : acces par lien direct, non-decouvrabilite et maintien de l'authentification.
- [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information) : URL de politique de confidentialite requise pour iOS/macOS.

### CNIL

- [Qu'est-ce qu'une donnee de sante ?](https://www.cnil.fr/fr/quest-ce-ce-quune-donnee-de-sante) : definition large, handicap, donnees deduites ou utilisees a des fins medicales.
- [Responsable de traitement, sous-traitants : comment bien identifier son role ?](https://www.cnil.fr/fr/rgpd-comment-bien-identifier-son-role) : qualification par traitement et contrat ecrit obligatoire.
- [Travailler avec un sous-traitant](https://www.cnil.fr/fr/sous-traitant) et [chapitre IV du RGPD](https://www.cnil.fr/fr/reglement-europeen-protection-donnees/chapitre4) : article 28, garanties, autorisation des sous-traitants ulterieurs et contenu contractuel.
- [Information des personnes et transparence](https://www.cnil.fr/fr/conformite-rgpd-information-des-personnes-et-transparence) : finalites, bases, destinataires, durees, droits et reclamation.
- [Les six grands principes du RGPD](https://cnil.fr/fr/comprendre-le-rgpd/les-six-grands-principes-du-rgpd) : minimisation, droits et limitation de conservation.
- [Les durees de conservation des donnees](https://www.cnil.fr/fr/passer-laction/les-durees-de-conservation-des-donnees) : base active, archivage et determination par finalite.
- [Ce qu'il faut savoir sur l'AIPD](https://www.cnil.fr/fr/ce-quil-faut-savoir-sur-lanalyse-dimpact-relative-la-protection-des-donnees-aipd) : risque eleve et criteres, dont donnees sensibles et personnes vulnerables.
- [Referentiel cabinets medicaux et paramedicaux](https://www.cnil.fr/sites/cnil/files/atoms/files/referentiel_-_cabinet.pdf) : point de comparaison sectoriel a valider selon le role et l'activite reels ; il ne doit pas etre applique automatiquement a tout client.

### Agence du Numerique en Sante

- [HDS - Certification Hebergeur de Donnees de Sante](https://esante.gouv.fr/ens/offre/hds) : cadre, FAQ et transition vers le referentiel v2.
- [Referentiel de certification HDS v2](https://esante.gouv.fr/sites/default/files/media_entity/documents/referentiel_certification_hds---fr--v2.pdf) : exigences, activites d'hebergement et version publiee en avril 2024.
- [Referentiel d'accreditation HDS v2](https://esante.gouv.fr/sites/default/files/media_entity/documents/referentiel_accreditation_hds---fr---v2.pdf) : section **2.1 Champ d'application**, qualite de sous-traitant, nature des donnees, contexte du recueil et activites.
- [Publication au Journal officiel du referentiel HDS v2](https://esante.gouv.fr/espace-presse/publication-au-journal-officiel-du-referentiel-de-certification-hds-souverainete-des-donnees-et-ameliorations-du-referentiel) : calendrier de transition, echeance du 16 mai 2026 pour les hebergeurs deja certifies.

