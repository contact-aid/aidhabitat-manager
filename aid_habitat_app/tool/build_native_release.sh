#!/usr/bin/env bash
# Native release builds (iOS / macOS / Android) avec obfuscation Dart
# pour l'App Store / TestFlight / Play Store.
#
# L'obfuscation `--obfuscate --split-debug-info=...` :
#   - rend le bytecode Dart illisible (les noms de classes/méthodes
#     deviennent des hash) → protège la logique métier dans l'IPA/AAB
#   - sépare les symbols dans un dossier annexe → on peut désobfusquer
#     les stack traces de production via `flutter symbolize -i ...`
#
# Sans obfuscation, l'App Store accepte le binaire mais n'importe qui
# peut décompiler l'IPA et lire le code Dart. Apple recommande
# explicitement l'obfuscation pour les apps métier.
#
# Usage :
#   ./tool/build_native_release.sh ios       # produit build/ios/archive/
#   ./tool/build_native_release.sh macos     # produit build/macos/Build/Products/Release/
#   ./tool/build_native_release.sh android   # produit build/app/outputs/bundle/release/
#   ./tool/build_native_release.sh ios --allow-dirty
#
# Variables d'env :
#   AIDHABITAT_API_BASE_URL : URL du backend Aid'Habitat (obligatoire)
#   AIDHABITAT_BOOTSTRAP_PASSWORD : mot de passe bootstrap local temporaire
#                             (optionnel ; laisser vide pour forcer une
#                             première connexion en ligne)
#   AIDHABITAT_DEBUG_INFO   : nouveau dossier où stocker les symboles
#   AIDHABITAT_RELEASE_ROOT : racine des manifests et symboles par build
#                             (défaut : build/native-releases)
#   AIDHABITAT_BUILD_ID     : identifiant local facultatif (doit être inédit)
#   AIDHABITAT_ALLOW_DIRTY_RELEASE=1 : équivalent de --allow-dirty
#
# IMPORTANT :
#   - Conserver les fichiers de `native-releases/` ! Sans les symboles,
#     impossible
#     de déchiffrer les crash reports remontés par TestFlight ou Apple.
#   - Les ajouter à un système de stockage durable (S3, Drive, etc.),
#     PAS au repo Git (trop volumineux).
#   - Ce script protège les distributions release. Les builds locaux de
#     développement (`flutter run`, `flutter build ... --debug`) restent libres.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
RELEASE_TOOL="$REPO_DIR/tools/release-artifact-check.mjs"
cd "$APP_DIR"

PLATFORM="${1:-}"
if [ -z "$PLATFORM" ]; then
  echo "Usage: $0 {ios|macos|android} [--allow-dirty]" >&2
  exit 1
fi
shift

ALLOW_DIRTY="${AIDHABITAT_ALLOW_DIRTY_RELEASE:-0}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-dirty)
      ALLOW_DIRTY=1
      ;;
    *)
      echo "[build_native] Option inconnue : $1" >&2
      echo "Usage: $0 {ios|macos|android} [--allow-dirty]" >&2
      exit 1
      ;;
  esac
  shift
done

case "$PLATFORM" in
  ios|macos|android) ;;
  *)
    echo "[build_native] Plateforme inconnue : $PLATFORM" >&2
    echo "Usage: $0 {ios|macos|android} [--allow-dirty]" >&2
    exit 1
    ;;
esac

if [ "$ALLOW_DIRTY" != "0" ] && [ "$ALLOW_DIRTY" != "1" ]; then
  echo "[build_native] AIDHABITAT_ALLOW_DIRTY_RELEASE doit valoir 0 ou 1." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "[build_native] node not found on PATH" >&2
  exit 1
fi
if [ ! -f "$RELEASE_TOOL" ]; then
  echo "[build_native] Outil de traçabilité introuvable : $RELEASE_TOOL" >&2
  exit 1
fi

FLUTTER="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER" >/dev/null 2>&1; then
  echo "[build_native] flutter not found on PATH" >&2
  exit 1
fi

API_BASE_URL="${AIDHABITAT_API_BASE_URL:-}"
if [ -z "$API_BASE_URL" ]; then
  echo "[build_native] ERROR: AIDHABITAT_API_BASE_URL est obligatoire pour un build natif release." >&2
  echo "[build_native] Exemple: AIDHABITAT_API_BASE_URL=https://api.aid-habitat.fr $0 $PLATFORM" >&2
  exit 1
fi
if [[ ! "$API_BASE_URL" =~ ^https://[^[:space:]]+$ ]]; then
  echo "[build_native] ERROR: AIDHABITAT_API_BASE_URL doit être une URL HTTPS en release native." >&2
  exit 1
fi
API_BASE_URL="${API_BASE_URL%/}"

GIT_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
if [ -z "$GIT_SHA" ]; then
  echo "[build_native] Impossible de déterminer le SHA Git courant." >&2
  exit 1
fi
GIT_DIRTY=false
DIRTY_ACCEPTED=false
GIT_STATUS="$(git status --porcelain --untracked-files=normal)"
if [ -n "$GIT_STATUS" ]; then
  GIT_DIRTY=true
  if [ "$ALLOW_DIRTY" != "1" ]; then
    echo "[build_native] Arbre Git modifié : distribution refusée par défaut." >&2
    echo "[build_native] Vérifiez les changements ou relancez explicitement avec --allow-dirty." >&2
    echo "[build_native] Les builds locaux de développement ne sont pas concernés." >&2
    exit 1
  fi
  DIRTY_ACCEPTED=true
  echo "[build_native] ATTENTION : distribution depuis un arbre sale explicitement acceptée."
fi

APP_VERSION_WITH_BUILD="$(sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*/\1/p' pubspec.yaml | head -n 1)"
if [[ "$APP_VERSION_WITH_BUILD" != *+* ]]; then
  echo "[build_native] Version ou numéro de build introuvable dans pubspec.yaml." >&2
  exit 1
fi
APP_VERSION="${APP_VERSION_WITH_BUILD%%+*}"
BUILD_NUMBER="${APP_VERSION_WITH_BUILD#*+}"

DART_DEFINES=(
  --dart-define=AIDHABITAT_API_BASE_URL="$API_BASE_URL"
)
if [ -n "${AIDHABITAT_BOOTSTRAP_PASSWORD:-}" ]; then
  DART_DEFINES+=(
    --dart-define=AIDHABITAT_BOOTSTRAP_PASSWORD="$AIDHABITAT_BOOTSTRAP_PASSWORD"
  )
fi

if [ "$PLATFORM" = "android" ]; then
  if [ ! -f "android/key.properties" ]; then
    echo "[build_native] ERROR: android/key.properties manquant — signature Android release non configurée." >&2
    echo "[build_native] Créez ce fichier avec storeFile, storePassword, keyAlias et keyPassword." >&2
    exit 1
  fi
  HOMEBREW_JDK21="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
  if [ -d "$HOMEBREW_JDK21" ]; then
    export JAVA_HOME="$HOMEBREW_JDK21"
    export PATH="$JAVA_HOME/bin:$PATH"
  fi
  HOMEBREW_ANDROID_SDK="/opt/homebrew/share/android-commandlinetools"
  if [ -d "$HOMEBREW_ANDROID_SDK" ]; then
    export ANDROID_HOME="${ANDROID_HOME:-$HOMEBREW_ANDROID_SDK}"
    export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
  fi
  JAVA_VERSION_RAW="$(java -version 2>&1 | awk -F\" '/version/ {print $2; exit}')"
  JAVA_MAJOR="${JAVA_VERSION_RAW%%.*}"
  if [ "$JAVA_MAJOR" = "1" ]; then
    JAVA_MAJOR="$(echo "$JAVA_VERSION_RAW" | cut -d. -f2)"
  fi
  if [ -n "$JAVA_MAJOR" ] && [ "$JAVA_MAJOR" -ge 25 ]; then
    echo "[build_native] ERROR: Java $JAVA_VERSION_RAW détecté, incompatible avec la toolchain Android/Kotlin actuelle." >&2
    echo "[build_native] Utilisez un JDK LTS supporté, idéalement Java 17 ou 21, puis relancez." >&2
    exit 1
  fi
fi

FLUTTER_VERSION_JSON="$("$FLUTTER" --version --machine)"
FLUTTER_SDK="$(FLUTTER_VERSION_JSON="$FLUTTER_VERSION_JSON" node -e \
  'const v=JSON.parse(process.env.FLUTTER_VERSION_JSON); process.stdout.write(v.frameworkVersion || "unknown")')"
DART_SDK="$(FLUTTER_VERSION_JSON="$FLUTTER_VERSION_JSON" node -e \
  'const v=JSON.parse(process.env.FLUTTER_VERSION_JSON); process.stdout.write(v.dartSdkVersion || "unknown")')"

case "$PLATFORM" in
  ios)
    PLATFORM_SDK="$(xcodebuild -version | paste -sd ';' -)"
    PLATFORM_API="iOS $(sed -nE "s/^platform :ios, '([^']+)'.*/\1/p" ios/Podfile | head -n 1)"
    ;;
  macos)
    PLATFORM_SDK="$(xcodebuild -version | paste -sd ';' -)"
    PLATFORM_API="macOS $(sed -nE "s/^platform :osx, '([^']+)'.*/\1/p" macos/Podfile | head -n 1)"
    ;;
  android)
    PLATFORM_SDK="$(java -version 2>&1 | head -n 1)"
    PLATFORM_API="Android compileSdk/targetSdk gérés par Flutter $FLUTTER_SDK"
    ;;
esac

CREATED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
BUILD_ID="${AIDHABITAT_BUILD_ID:-}"
if [ -z "$BUILD_ID" ]; then
  BUILD_ID="$(node "$RELEASE_TOOL" native-build-id \
    "$APP_VERSION" "$BUILD_NUMBER" "$GIT_SHA" "$GIT_DIRTY")"
elif [[ ! "$BUILD_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]{0,159}$ ]]; then
  echo "[build_native] AIDHABITAT_BUILD_ID invalide : $BUILD_ID" >&2
  exit 1
fi

RELEASE_ROOT="${AIDHABITAT_RELEASE_ROOT:-build/native-releases}"
BUILD_DIR="$RELEASE_ROOT/$PLATFORM/$BUILD_ID"
node "$RELEASE_TOOL" reserve-directory "$BUILD_DIR" >/dev/null

if [ -n "${AIDHABITAT_DEBUG_INFO:-}" ]; then
  DEBUG_INFO_DIR="$AIDHABITAT_DEBUG_INFO"
else
  DEBUG_INFO_DIR="$BUILD_DIR/symbols"
fi
node "$RELEASE_TOOL" reserve-directory "$DEBUG_INFO_DIR" >/dev/null

MANIFEST_PATH="$BUILD_DIR/manifest.json"
RELEASE_BUILD_ID="$BUILD_ID" \
RELEASE_CREATED_AT="$CREATED_AT" \
RELEASE_GIT_SHA="$GIT_SHA" \
RELEASE_GIT_DIRTY="$GIT_DIRTY" \
RELEASE_DIRTY_ACCEPTED="$DIRTY_ACCEPTED" \
RELEASE_APP_VERSION="$APP_VERSION" \
RELEASE_BUILD_NUMBER="$BUILD_NUMBER" \
RELEASE_FLUTTER_SDK="$FLUTTER_SDK" \
RELEASE_DART_SDK="$DART_SDK" \
RELEASE_PLATFORM_SDK="$PLATFORM_SDK" \
RELEASE_PLATFORM="$PLATFORM" \
RELEASE_PLATFORM_API="$PLATFORM_API" \
RELEASE_BACKEND_API="$API_BASE_URL" \
RELEASE_SYMBOLS_DIRECTORY="$DEBUG_INFO_DIR" \
  node "$RELEASE_TOOL" write-native-manifest "$MANIFEST_PATH"

mark_failed_manifest() {
  exit_code=$?
  trap - EXIT
  if [ "$exit_code" -ne 0 ] && [ -f "$MANIFEST_PATH" ]; then
    node "$RELEASE_TOOL" update-native-status "$MANIFEST_PATH" failed >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap mark_failed_manifest EXIT

echo "[build_native] Flutter $FLUTTER_SDK · Dart $DART_SDK"
echo "[build_native] Build local : $BUILD_ID"
echo "[build_native] Manifest : $MANIFEST_PATH"
echo "[build_native] Contrôle local uniquement : vérifiez encore le numéro $BUILD_NUMBER sur le service de distribution avant upload."

"$FLUTTER" pub get

case "$PLATFORM" in
  ios)
    echo "[build_native] iOS release archive (signing géré par Xcode)..."
    "$FLUTTER" build ipa --release \
      --obfuscate \
      --split-debug-info="$DEBUG_INFO_DIR" \
      "${DART_DEFINES[@]}"
    echo "[build_native] IPA produit dans build/ios/ipa/"
    echo "[build_native] Symbols dans $DEBUG_INFO_DIR — À CONSERVER"
    echo "[build_native] Étape suivante : ouvrir Xcode > Window > Organizer > Distribute App"
    ;;
  macos)
    echo "[build_native] macOS release..."
    "$FLUTTER" build macos --release \
      --obfuscate \
      --split-debug-info="$DEBUG_INFO_DIR" \
      "${DART_DEFINES[@]}"
    echo "[build_native] .app produit dans build/macos/Build/Products/Release/"
    echo "[build_native] Symbols dans $DEBUG_INFO_DIR — À CONSERVER"
    ;;
  android)
    echo "[build_native] Android App Bundle (Play Store) release..."
    "$FLUTTER" build appbundle --release \
      --obfuscate \
      --split-debug-info="$DEBUG_INFO_DIR" \
      "${DART_DEFINES[@]}"
    echo "[build_native] AAB produit dans build/app/outputs/bundle/release/"
    echo "[build_native] Symbols dans $DEBUG_INFO_DIR — À CONSERVER"
    ;;
esac

node "$RELEASE_TOOL" update-native-status "$MANIFEST_PATH" completed >/dev/null
trap - EXIT

echo "[build_native] OK — déchiffrer les crashs avec :"
echo "  $FLUTTER symbolize -i <stacktrace.txt> -d $DEBUG_INFO_DIR/<symbols-file>"
