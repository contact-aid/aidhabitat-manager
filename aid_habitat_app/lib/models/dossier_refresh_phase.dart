enum DossierRefreshPhase { loading, ready, failed }

bool needsDossierLoadingStatus({
  required bool hasDossiers,
  required DossierRefreshPhase phase,
}) => !hasDossiers && phase != DossierRefreshPhase.ready;
