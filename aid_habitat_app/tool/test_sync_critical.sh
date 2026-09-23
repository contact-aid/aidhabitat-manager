#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$script_dir/test_safely.sh" \
  test/services/media_auth_origin_test.dart \
  test/services/ai_rewrite_service_test.dart \
  test/screens/visit_report/wiki_picker_tags_test.dart \
  test/models/autonomy_item_names_test.dart \
  test/models/sanitary_rooms_validation_test.dart \
  test/screens/document_viewport_test.dart \
  test/services/offline_persistence_test.dart \
  test/services/sync_engine_remote_session_test.dart \
  test/services/dossier_remote_context_merge_test.dart \
  test/services/dossier_remote_child_merge_test.dart \
  test/services/sync_errors_test.dart \
  test/services/sync_acknowledgement_test.dart \
  test/services/versioned_ack_transport_test.dart \
  test/services/context_ack_transport_test.dart \
  test/services/context_version_storage_test.dart \
  test/services/agent1_context_sync_protocol_test.dart \
  test/services/sync_push_outcome_test.dart \
  test/services/sync_session_scope_test.dart \
  test/services/agent3_sync_operation_ownership_test.dart \
  test/services/sync_ownership_diagnostic_test.dart \
  test/services/agent4_ownership_migration_test.dart \
  test/services/web_vault_migration_test.dart \
  test/services/agent4_offline_identity_test.dart \
  test/services/agent4_sync_resistance_test.dart \
  test/services/agent5_wiki_commit_test.dart \
  test/services/agent5_wiki_transport_test.dart \
  test/services/agent2_visit_recommendations_wiki_remap_test.dart \
  test/services/sync_conflict_resolution_test.dart \
  test/services/sync_mutation_test.dart \
  test/services/dossier_mutation_baseline_test.dart \
  test/services/dossier_pending_pull_test.dart \
  test/services/dossier_secondary_conflict_preservation_test.dart \
  test/services/secondary_conflict_resolution_test.dart \
  test/services/child_version_transport_test.dart \
  test/services/child_version_storage_test.dart \
  test/services/local_database_open_failure_test.dart \
  test/services/document_revision_save_test.dart \
  test/services/document_remote_revision_test.dart \
  test/services/document_imported_upload_test.dart \
  test/services/document_page_save_test.dart \
  test/services/image_rotation_worker_test.dart \
  test/services/visit_date_time_test.dart \
  test/screens/database_unavailable_screen_test.dart \
  test/screens/agent3_sync_ownership_review_screen_test.dart \
  test/screens/dossier_note_read_only_test.dart \
  test/screens/visit_report/recommendations_gestures_test.dart \
  test/screens/document_preview_ink_test.dart \
  test/screens/document_preview_revision_test.dart \
  test/screens/secondary_conflict_review_test.dart \
  test/screens/visit_report/beneficiary_tab_save_test.dart
