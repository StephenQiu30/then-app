import GRDB

nonisolated enum DatabaseMigrations {
  static let initialLocalLedgerIdentifier = "v1_create_local_ledger"
  static let calendarCacheIdentifier = "v2_create_calendar_cache"
  static let tripPlanningIdentifier = "v3_create_trip_planning"
  static let journeyRecordingIdentifier = "v4_create_journey_recording"
  static let lifeLinksIdentifier = "v5_create_life_links"
  static let manualLocationCompatibilityIdentifier = "v6_relax_manual_location_coordinates"
  static let journeyExpenseReviewIdentifier = "v7_add_journey_expense_review_state"
  static let tripPlanRevisionReviewIdentifier = "v8_add_trip_plan_revision_review"

  static func migrate(_ pool: DatabasePool) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(initialLocalLedgerIdentifier) { database in
      try database.execute(sql: initialLocalLedgerSQL)
    }
    migrator.registerMigration(calendarCacheIdentifier) { database in
      try database.execute(sql: calendarCacheSQL)
    }
    migrator.registerMigration(tripPlanningIdentifier) { database in
      try database.execute(sql: tripPlanningSQL)
    }
    migrator.registerMigration(journeyRecordingIdentifier) { database in
      try database.execute(sql: journeyRecordingSQL)
    }
    migrator.registerMigration(lifeLinksIdentifier) { database in
      try database.execute(sql: lifeLinksSQL)
    }
    migrator.registerMigration(manualLocationCompatibilityIdentifier) { database in
      let latitudeIsRequired =
        try Int.fetchOne(
          database,
          sql: """
            SELECT \"notnull\"
            FROM pragma_table_info('location_snapshots')
            WHERE name = 'latitude'
            """
        ) ?? 0
      guard latitudeIsRequired == 1 else { return }

      try database.execute(sql: "PRAGMA legacy_alter_table = ON")
      defer { try? database.execute(sql: "PRAGMA legacy_alter_table = OFF") }
      try database.execute(sql: manualLocationCompatibilitySQL)
      try database.checkForeignKeys()
    }
    migrator.registerMigration(journeyExpenseReviewIdentifier) { database in
      try database.execute(sql: journeyExpenseReviewSQL)
    }
    migrator.registerMigration(tripPlanRevisionReviewIdentifier) { database in
      try database.execute(sql: tripPlanRevisionReviewSQL)
      try database.checkForeignKeys()
    }
    try migrator.migrate(pool)
  }

  private static let initialLocalLedgerSQL = """
    CREATE TABLE local_profiles (
      id TEXT PRIMARY KEY NOT NULL,
      singleton_key INTEGER NOT NULL DEFAULT 1 UNIQUE CHECK (singleton_key = 1),
      base_currency_code TEXT NOT NULL
        CHECK (length(base_currency_code) = 3 AND base_currency_code = upper(base_currency_code)),
      base_currency_state TEXT NOT NULL
        CHECK (base_currency_state IN ('suggested', 'confirmed')),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at)
    ) STRICT;

    CREATE TABLE ledger_accounts (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      parent_id TEXT,
      kind TEXT NOT NULL
        CHECK (kind IN ('asset', 'liability', 'income', 'expense', 'equity')),
      subtype TEXT NOT NULL
        CHECK (
          subtype IN (
            'opening_balance',
            'uncategorized',
            'cash',
            'bank',
            'electronic_wallet',
            'credit_card',
            'food',
            'transport',
            'shopping',
            'housing',
            'other_expense',
            'salary',
            'other_income',
            'custom'
          )
        ),
      name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 40),
      native_currency_code TEXT NOT NULL
        CHECK (
          length(native_currency_code) = 3
          AND native_currency_code = upper(native_currency_code)
        ),
      configuration_state TEXT NOT NULL
        CHECK (configuration_state IN ('pending_currency_confirmation', 'ready')),
      system_key TEXT,
      status TEXT NOT NULL CHECK (status IN ('active', 'archived')),
      display_order INTEGER NOT NULL DEFAULT 0 CHECK (display_order >= 0),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      UNIQUE (owner_id, system_key),
      CHECK (parent_id IS NULL OR parent_id <> id),
      FOREIGN KEY (owner_id) REFERENCES local_profiles(id) ON DELETE RESTRICT,
      FOREIGN KEY (parent_id, owner_id)
        REFERENCES ledger_accounts(id, owner_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
    ) STRICT;

    CREATE TABLE ledger_transactions (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('draft', 'posted', 'discarded')),
      kind TEXT NOT NULL
        CHECK (kind IN ('expense', 'income', 'transfer', 'refund', 'reversal', 'opening', 'adjustment')),
      canonical_root_id TEXT NOT NULL,
      local_root_revision INTEGER NOT NULL DEFAULT 0 CHECK (local_root_revision >= 0),
      occurred_at REAL NOT NULL,
      original_timezone_id TEXT NOT NULL CHECK (length(trim(original_timezone_id)) > 0),
      local_date TEXT NOT NULL
        CHECK (
          length(local_date) = 10
          AND local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
        ),
      payee TEXT,
      note TEXT,
      source_type TEXT NOT NULL
        CHECK (source_type IN ('manual', 'ocr', 'system_suggestion')),
      posted_at REAL,
      refund_of_id TEXT,
      reversal_of_id TEXT UNIQUE,
      replacement_for_id TEXT,
      correction_group_id TEXT,
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      CHECK (
        (status = 'posted' AND posted_at IS NOT NULL)
        OR (status IN ('draft', 'discarded') AND posted_at IS NULL)
      ),
      CHECK (
        (kind = 'refund' AND refund_of_id IS NOT NULL)
        OR (kind <> 'refund' AND refund_of_id IS NULL)
      ),
      CHECK (
        (kind = 'reversal' AND reversal_of_id IS NOT NULL)
        OR (kind <> 'reversal' AND reversal_of_id IS NULL)
      ),
      CHECK (
        replacement_for_id IS NULL
        OR (
          kind IN ('expense', 'income', 'transfer')
          AND correction_group_id IS NOT NULL
        )
      ),
      CHECK (
        correction_group_id IS NULL
        OR kind = 'reversal'
        OR replacement_for_id IS NOT NULL
      ),
      CHECK (refund_of_id IS NULL OR refund_of_id <> id),
      CHECK (reversal_of_id IS NULL OR reversal_of_id <> id),
      CHECK (replacement_for_id IS NULL OR replacement_for_id <> id),
      FOREIGN KEY (owner_id) REFERENCES local_profiles(id) ON DELETE RESTRICT,
      FOREIGN KEY (canonical_root_id, owner_id)
        REFERENCES ledger_transactions(id, owner_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY (refund_of_id, owner_id)
        REFERENCES ledger_transactions(id, owner_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY (reversal_of_id, owner_id)
        REFERENCES ledger_transactions(id, owner_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
      FOREIGN KEY (replacement_for_id, owner_id)
        REFERENCES ledger_transactions(id, owner_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
    ) STRICT;

    CREATE TABLE postings (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      transaction_id TEXT NOT NULL,
      ledger_account_id TEXT NOT NULL,
      side TEXT NOT NULL CHECK (side IN ('debit', 'credit')),
      amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
      currency_code TEXT NOT NULL
        CHECK (length(currency_code) = 3 AND currency_code = upper(currency_code)),
      memo TEXT,
      sequence INTEGER NOT NULL CHECK (sequence >= 0),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      UNIQUE (transaction_id, sequence),
      FOREIGN KEY (transaction_id, owner_id)
        REFERENCES ledger_transactions(id, owner_id) ON DELETE RESTRICT,
      FOREIGN KEY (ledger_account_id, owner_id)
        REFERENCES ledger_accounts(id, owner_id) ON DELETE RESTRICT
    ) STRICT;

    CREATE INDEX ledger_accounts_owner_status_order_idx
      ON ledger_accounts(owner_id, status, display_order, id);
    CREATE INDEX ledger_accounts_owner_kind_idx
      ON ledger_accounts(owner_id, kind, status);
    CREATE INDEX ledger_transactions_owner_status_time_idx
      ON ledger_transactions(owner_id, status, occurred_at DESC, id);
    CREATE INDEX ledger_transactions_owner_local_date_idx
      ON ledger_transactions(owner_id, local_date, id);
    CREATE INDEX ledger_transactions_owner_root_idx
      ON ledger_transactions(owner_id, canonical_root_id, created_at, id);
    CREATE INDEX ledger_transactions_owner_refund_idx
      ON ledger_transactions(owner_id, refund_of_id, id);
    CREATE INDEX ledger_transactions_owner_correction_idx
      ON ledger_transactions(owner_id, correction_group_id, id);
    CREATE INDEX postings_account_idx
      ON postings(owner_id, ledger_account_id, transaction_id);
    """

  private static let calendarCacheSQL = """
    CREATE TABLE calendar_sources (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      external_id_hmac BLOB NOT NULL,
      title TEXT NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 200),
      source_kind TEXT NOT NULL
        CHECK (
          source_kind IN (
            'local',
            'exchange',
            'caldav',
            'mobileme',
            'subscribed',
            'birthdays',
            'unknown'
          )
        ),
      access_state TEXT NOT NULL
        CHECK (access_state IN ('selected', 'unselected', 'unavailable')),
      desired_selected INTEGER NOT NULL DEFAULT 0 CHECK (desired_selected IN (0, 1)),
      is_subscribed INTEGER NOT NULL DEFAULT 0 CHECK (is_subscribed IN (0, 1)),
      allows_modifications INTEGER NOT NULL DEFAULT 0 CHECK (allows_modifications IN (0, 1)),
      last_successful_scan_at REAL,
      last_display_window_start REAL,
      last_display_window_end REAL,
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      UNIQUE (owner_id, external_id_hmac),
      CHECK (access_state <> 'selected' OR desired_selected = 1),
      CHECK (access_state <> 'unselected' OR desired_selected = 0),
      FOREIGN KEY (owner_id) REFERENCES local_profiles(id) ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE calendar_scans (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed')),
      display_window_start REAL NOT NULL,
      display_window_end REAL NOT NULL CHECK (display_window_end > display_window_start),
      matching_window_start REAL NOT NULL,
      matching_window_end REAL NOT NULL CHECK (matching_window_end > matching_window_start),
      started_at REAL NOT NULL CHECK (started_at >= 0),
      finished_at REAL,
      safe_error_code TEXT,
      CHECK (
        (status = 'running' AND finished_at IS NULL AND safe_error_code IS NULL)
        OR (status = 'completed' AND finished_at IS NOT NULL AND safe_error_code IS NULL)
        OR (status = 'failed' AND finished_at IS NOT NULL AND safe_error_code IS NOT NULL)
      ),
      UNIQUE (id, owner_id),
      FOREIGN KEY (owner_id) REFERENCES local_profiles(id) ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE calendar_series (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      calendar_source_id TEXT NOT NULL,
      external_id_hmac BLOB NOT NULL,
      has_recurrence INTEGER NOT NULL CHECK (has_recurrence IN (0, 1)),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      UNIQUE (owner_id, calendar_source_id, external_id_hmac),
      FOREIGN KEY (calendar_source_id, owner_id)
        REFERENCES calendar_sources(id, owner_id) ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE calendar_occurrences (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      calendar_source_id TEXT NOT NULL,
      calendar_series_id TEXT NOT NULL,
      external_id_hmac BLOB NOT NULL,
      match_key_hmac BLOB NOT NULL,
      source_fingerprint BLOB NOT NULL,
      source_version INTEGER NOT NULL DEFAULT 1 CHECK (source_version >= 1),
      source_state TEXT NOT NULL
        CHECK (
          source_state IN (
            'active',
            'missing',
            'source_deleted',
            'out_of_window',
            'cancelled',
            'ambiguous'
          )
        ),
      is_all_day INTEGER NOT NULL CHECK (is_all_day IN (0, 1)),
      starts_at REAL NOT NULL,
      ends_at REAL NOT NULL CHECK (ends_at > starts_at),
      local_start_date TEXT NOT NULL
        CHECK (
          length(local_start_date) = 10
          AND local_start_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
        ),
      local_end_date_exclusive TEXT NOT NULL
        CHECK (
          length(local_end_date_exclusive) = 10
          AND local_end_date_exclusive GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
        ),
      timezone_id TEXT NOT NULL CHECK (length(trim(timezone_id)) > 0),
      title TEXT,
      location_text TEXT,
      last_seen_scan_id TEXT,
      missing_scan_count INTEGER NOT NULL DEFAULT 0 CHECK (missing_scan_count >= 0),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      UNIQUE (owner_id, external_id_hmac),
      FOREIGN KEY (calendar_source_id, owner_id)
        REFERENCES calendar_sources(id, owner_id) ON DELETE CASCADE,
      FOREIGN KEY (calendar_series_id, owner_id)
        REFERENCES calendar_series(id, owner_id) ON DELETE CASCADE,
      FOREIGN KEY (last_seen_scan_id, owner_id)
        REFERENCES calendar_scans(id, owner_id) ON DELETE RESTRICT
    ) STRICT;

    CREATE TABLE calendar_occurrence_revisions (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      calendar_occurrence_id TEXT NOT NULL,
      from_version INTEGER NOT NULL CHECK (from_version >= 1),
      to_version INTEGER NOT NULL CHECK (to_version = from_version + 1),
      old_starts_at REAL NOT NULL,
      new_starts_at REAL NOT NULL,
      old_ends_at REAL NOT NULL,
      new_ends_at REAL NOT NULL,
      old_timezone_id TEXT NOT NULL,
      new_timezone_id TEXT NOT NULL,
      old_title TEXT,
      new_title TEXT,
      old_location_text TEXT,
      new_location_text TEXT,
      detected_at REAL NOT NULL CHECK (detected_at >= 0),
      resolution_state TEXT NOT NULL DEFAULT 'pending'
        CHECK (resolution_state IN ('pending', 'accepted', 'ignored')),
      UNIQUE (calendar_occurrence_id, to_version),
      FOREIGN KEY (calendar_occurrence_id, owner_id)
        REFERENCES calendar_occurrences(id, owner_id) ON DELETE CASCADE
    ) STRICT;

    CREATE INDEX calendar_sources_owner_access_idx
      ON calendar_sources(owner_id, access_state, title, id);
    CREATE INDEX calendar_scans_owner_started_idx
      ON calendar_scans(owner_id, started_at DESC, id);
    CREATE INDEX calendar_series_owner_source_idx
      ON calendar_series(owner_id, calendar_source_id, id);
    CREATE INDEX calendar_occurrences_owner_window_idx
      ON calendar_occurrences(owner_id, source_state, starts_at, id);
    CREATE INDEX calendar_occurrences_owner_source_scan_idx
      ON calendar_occurrences(owner_id, calendar_source_id, last_seen_scan_id, starts_at);
    CREATE INDEX calendar_occurrence_revisions_owner_pending_idx
      ON calendar_occurrence_revisions(owner_id, resolution_state, detected_at, id);
    """

  private static let tripPlanningSQL = """
    CREATE TABLE location_snapshots (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 200),
      address TEXT CHECK (address IS NULL OR length(trim(address)) BETWEEN 1 AND 500),
      latitude REAL CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
      longitude REAL CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
      coordinate_system TEXT CHECK (coordinate_system IS NULL OR coordinate_system = 'wgs84'),
      source TEXT NOT NULL CHECK (source IN ('manual', 'mapkit')),
      horizontal_accuracy REAL CHECK (horizontal_accuracy IS NULL OR horizontal_accuracy >= 0),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      UNIQUE (id, owner_id),
      CHECK (
        (latitude IS NULL AND longitude IS NULL AND coordinate_system IS NULL)
        OR (latitude IS NOT NULL AND longitude IS NOT NULL AND coordinate_system = 'wgs84')
      ),
      FOREIGN KEY (owner_id) REFERENCES local_profiles(id) ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE trip_plans (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      display_name TEXT
        CHECK (display_name IS NULL OR length(trim(display_name)) BETWEEN 1 AND 200),
      origin_snapshot_id TEXT,
      destination_snapshot_id TEXT NOT NULL,
      transport_mode TEXT NOT NULL CHECK (transport_mode IN ('walking', 'driving', 'transit')),
      target_arrival_at REAL NOT NULL,
      planned_departure_at REAL,
      timezone_id TEXT NOT NULL CHECK (length(trim(timezone_id)) > 0),
      preparation_buffer_seconds INTEGER NOT NULL DEFAULT 0
        CHECK (preparation_buffer_seconds BETWEEN 0 AND 86400),
      selected_route_estimate_id TEXT,
      source_occurrence_version INTEGER
        CHECK (source_occurrence_version IS NULL OR source_occurrence_version >= 1),
      destination_value_source TEXT NOT NULL CHECK (destination_value_source IN ('event', 'user')),
      target_arrival_value_source TEXT NOT NULL CHECK (target_arrival_value_source IN ('event', 'user')),
      transport_value_source TEXT NOT NULL CHECK (transport_value_source = 'user'),
      departure_value_source TEXT NOT NULL CHECK (departure_value_source IN ('derived', 'user')),
      destination_user_overridden_at REAL,
      target_arrival_user_overridden_at REAL,
      transport_user_overridden_at REAL,
      departure_user_overridden_at REAL,
      status TEXT NOT NULL CHECK (status IN ('draft', 'planned', 'completed', 'cancelled')),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      CHECK (planned_departure_at IS NULL OR planned_departure_at < target_arrival_at),
      CHECK (status NOT IN ('planned', 'completed') OR planned_departure_at IS NOT NULL),
      FOREIGN KEY (owner_id) REFERENCES local_profiles(id) ON DELETE CASCADE,
      FOREIGN KEY (origin_snapshot_id, owner_id)
        REFERENCES location_snapshots(id, owner_id) ON DELETE RESTRICT,
      FOREIGN KEY (destination_snapshot_id, owner_id)
        REFERENCES location_snapshots(id, owner_id) ON DELETE RESTRICT,
      FOREIGN KEY (selected_route_estimate_id, owner_id, id)
        REFERENCES route_estimates(id, owner_id, trip_plan_id)
        ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
    ) STRICT;

    CREATE TABLE route_estimates (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      trip_plan_id TEXT NOT NULL,
      origin_snapshot_id TEXT NOT NULL,
      destination_snapshot_id TEXT NOT NULL,
      transport_mode TEXT NOT NULL CHECK (transport_mode IN ('walking', 'driving', 'transit')),
      provider TEXT NOT NULL CHECK (provider = 'mapkit'),
      coordinate_system TEXT NOT NULL CHECK (coordinate_system = 'wgs84'),
      distance_meters REAL NOT NULL CHECK (distance_meters >= 0),
      expected_travel_seconds REAL NOT NULL CHECK (expected_travel_seconds > 0),
      calculated_at REAL NOT NULL CHECK (calculated_at >= 0),
      expires_at REAL NOT NULL CHECK (expires_at > calculated_at),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      UNIQUE (id, owner_id),
      UNIQUE (id, owner_id, trip_plan_id),
      FOREIGN KEY (trip_plan_id, owner_id)
        REFERENCES trip_plans(id, owner_id) ON DELETE CASCADE,
      FOREIGN KEY (origin_snapshot_id, owner_id)
        REFERENCES location_snapshots(id, owner_id) ON DELETE RESTRICT,
      FOREIGN KEY (destination_snapshot_id, owner_id)
        REFERENCES location_snapshots(id, owner_id) ON DELETE RESTRICT
    ) STRICT;

    CREATE TABLE departure_reminders (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      trip_plan_id TEXT NOT NULL,
      notification_request_id TEXT NOT NULL,
      is_enabled INTEGER NOT NULL CHECK (is_enabled IN (0, 1)),
      fire_at REAL,
      follows_source INTEGER NOT NULL DEFAULT 0 CHECK (follows_source IN (0, 1)),
      schedule_version INTEGER NOT NULL DEFAULT 1 CHECK (schedule_version >= 1),
      status TEXT NOT NULL
        CHECK (
          status IN (
            'disabled',
            'not_requested',
            'authorization_denied',
            'scheduled',
            'failed',
            'cancelled'
          )
        ),
      last_error_code TEXT CHECK (last_error_code IS NULL OR length(last_error_code) <= 80),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      UNIQUE (owner_id, trip_plan_id),
      UNIQUE (owner_id, notification_request_id),
      CHECK (is_enabled = 1 OR status IN ('disabled', 'cancelled')),
      CHECK (status <> 'scheduled' OR (is_enabled = 1 AND fire_at IS NOT NULL AND last_error_code IS NULL)),
      FOREIGN KEY (trip_plan_id, owner_id)
        REFERENCES trip_plans(id, owner_id) ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE navigation_handoffs (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      trip_plan_id TEXT NOT NULL,
      target_app TEXT NOT NULL CHECK (target_app = 'apple_maps'),
      result TEXT NOT NULL CHECK (result IN ('requested', 'succeeded', 'failed')),
      requested_at REAL NOT NULL CHECK (requested_at >= 0),
      completed_at REAL,
      safe_error_code TEXT CHECK (safe_error_code IS NULL OR length(safe_error_code) <= 80),
      UNIQUE (id, owner_id),
      CHECK (
        (result = 'requested' AND completed_at IS NULL AND safe_error_code IS NULL)
        OR (result = 'succeeded' AND completed_at IS NOT NULL AND safe_error_code IS NULL)
        OR (result = 'failed' AND completed_at IS NOT NULL AND safe_error_code IS NOT NULL)
      ),
      FOREIGN KEY (trip_plan_id, owner_id)
        REFERENCES trip_plans(id, owner_id) ON DELETE CASCADE
    ) STRICT;

    CREATE TABLE event_trip_links (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      calendar_occurrence_id TEXT NOT NULL,
      trip_plan_id TEXT NOT NULL,
      source_occurrence_version INTEGER NOT NULL CHECK (source_occurrence_version >= 1),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      UNIQUE (id, owner_id),
      UNIQUE (owner_id, trip_plan_id),
      UNIQUE (owner_id, calendar_occurrence_id, trip_plan_id),
      FOREIGN KEY (calendar_occurrence_id, owner_id)
        REFERENCES calendar_occurrences(id, owner_id) ON DELETE RESTRICT,
      FOREIGN KEY (trip_plan_id, owner_id)
        REFERENCES trip_plans(id, owner_id) ON DELETE CASCADE
    ) STRICT;

    CREATE INDEX location_snapshots_owner_created_idx
      ON location_snapshots(owner_id, created_at DESC, id);
    CREATE INDEX trip_plans_owner_status_departure_idx
      ON trip_plans(owner_id, status, planned_departure_at, id);
    CREATE INDEX route_estimates_plan_calculated_idx
      ON route_estimates(owner_id, trip_plan_id, calculated_at DESC, id);
    CREATE INDEX departure_reminders_owner_fire_idx
      ON departure_reminders(owner_id, status, fire_at, id);
    CREATE INDEX navigation_handoffs_plan_requested_idx
      ON navigation_handoffs(owner_id, trip_plan_id, requested_at DESC, id);
    CREATE INDEX event_trip_links_occurrence_idx
      ON event_trip_links(owner_id, calendar_occurrence_id, id);
    """

  private static let journeyRecordingSQL = """
    CREATE TABLE journeys (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      trip_plan_id TEXT,
      recording_device_id TEXT NOT NULL CHECK (length(recording_device_id) BETWEEN 1 AND 80),
      status TEXT NOT NULL
        CHECK (status IN ('recording', 'paused', 'finalizing', 'reviewing', 'completed', 'discarded')),
      transport_mode TEXT NOT NULL CHECK (transport_mode IN ('walking', 'driving', 'transit')),
      started_at REAL NOT NULL CHECK (started_at >= 0),
      ended_at REAL,
      actual_origin_snapshot_id TEXT,
      actual_destination_snapshot_id TEXT,
      distance_meters REAL CHECK (distance_meters IS NULL OR distance_meters >= 0),
      duration_seconds REAL CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
      capture_completeness TEXT NOT NULL DEFAULT 'none'
        CHECK (capture_completeness IN ('none', 'partial', 'complete')),
      raw_track_state TEXT NOT NULL DEFAULT 'collecting'
        CHECK (raw_track_state IN ('collecting', 'awaiting_summary_confirmation', 'purged')),
      final_sequence INTEGER CHECK (final_sequence IS NULL OR final_sequence >= 0),
      point_count INTEGER CHECK (point_count IS NULL OR point_count >= 0),
      manifest_hash BLOB CHECK (manifest_hash IS NULL OR length(manifest_hash) = 32),
      termination_reason TEXT
        CHECK (
          termination_reason IS NULL
          OR termination_reason IN (
            'user_ended',
            'permission_denied',
            'location_unavailable',
            'storage_failure',
            'system_interruption',
            'discarded'
          )
        ),
      pause_reason TEXT CHECK (pause_reason IS NULL OR length(pause_reason) <= 80),
      tracking_consent_version INTEGER NOT NULL CHECK (tracking_consent_version >= 1),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      CHECK (ended_at IS NULL OR ended_at >= started_at),
      CHECK (
        (status IN ('recording', 'paused') AND ended_at IS NULL AND raw_track_state = 'collecting')
        OR (status = 'finalizing' AND ended_at IS NOT NULL AND raw_track_state = 'collecting')
        OR (
          status = 'reviewing'
          AND ended_at IS NOT NULL
          AND raw_track_state = 'awaiting_summary_confirmation'
          AND distance_meters IS NOT NULL
          AND duration_seconds IS NOT NULL
          AND final_sequence IS NOT NULL
          AND point_count IS NOT NULL
          AND manifest_hash IS NOT NULL
        )
        OR (
          status = 'completed'
          AND ended_at IS NOT NULL
          AND raw_track_state = 'purged'
          AND distance_meters IS NOT NULL
          AND duration_seconds IS NOT NULL
          AND final_sequence IS NOT NULL
          AND point_count IS NOT NULL
          AND manifest_hash IS NOT NULL
        )
        OR (status = 'discarded' AND ended_at IS NOT NULL AND raw_track_state = 'purged')
      ),
      FOREIGN KEY (owner_id) REFERENCES local_profiles(id) ON DELETE CASCADE,
      FOREIGN KEY (trip_plan_id, owner_id)
        REFERENCES trip_plans(id, owner_id) ON DELETE RESTRICT,
      FOREIGN KEY (actual_origin_snapshot_id, owner_id)
        REFERENCES location_snapshots(id, owner_id) ON DELETE RESTRICT,
      FOREIGN KEY (actual_destination_snapshot_id, owner_id)
        REFERENCES location_snapshots(id, owner_id) ON DELETE RESTRICT
    ) STRICT;

    CREATE UNIQUE INDEX journeys_owner_device_open_idx
      ON journeys(owner_id, recording_device_id)
      WHERE status IN ('recording', 'paused', 'finalizing', 'reviewing');

    CREATE TABLE track_segments (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      journey_id TEXT NOT NULL,
      sequence INTEGER NOT NULL CHECK (sequence >= 1),
      started_at REAL NOT NULL CHECK (started_at >= 0),
      ended_at REAL,
      end_reason TEXT
        CHECK (
          end_reason IS NULL
          OR end_reason IN ('paused', 'finalizing', 'interrupted', 'discarded')
        ),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      UNIQUE (id, owner_id, journey_id),
      UNIQUE (owner_id, journey_id, sequence),
      CHECK (
        (ended_at IS NULL AND end_reason IS NULL)
        OR (ended_at IS NOT NULL AND ended_at >= started_at AND end_reason IS NOT NULL)
      ),
      FOREIGN KEY (journey_id, owner_id)
        REFERENCES journeys(id, owner_id) ON DELETE CASCADE
    ) STRICT;

    CREATE UNIQUE INDEX track_segments_one_open_idx
      ON track_segments(owner_id, journey_id)
      WHERE ended_at IS NULL;

    CREATE TABLE track_points (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      journey_id TEXT NOT NULL,
      segment_id TEXT NOT NULL,
      sequence INTEGER NOT NULL CHECK (sequence >= 1),
      recorded_at REAL NOT NULL CHECK (recorded_at >= 0),
      latitude REAL NOT NULL CHECK (latitude BETWEEN -90 AND 90),
      longitude REAL NOT NULL CHECK (longitude BETWEEN -180 AND 180),
      coordinate_system TEXT NOT NULL CHECK (coordinate_system = 'wgs84'),
      horizontal_accuracy REAL NOT NULL CHECK (horizontal_accuracy >= 0),
      vertical_accuracy REAL CHECK (vertical_accuracy IS NULL OR vertical_accuracy >= 0),
      altitude_meters REAL,
      speed_meters_per_second REAL CHECK (speed_meters_per_second IS NULL OR speed_meters_per_second >= 0),
      course_degrees REAL CHECK (course_degrees IS NULL OR course_degrees BETWEEN 0 AND 360),
      quality_flag TEXT NOT NULL
        CHECK (quality_flag IN ('unreviewed', 'accepted', 'low_accuracy', 'implausible_jump')),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      UNIQUE (owner_id, journey_id, sequence),
      FOREIGN KEY (journey_id, owner_id)
        REFERENCES journeys(id, owner_id) ON DELETE CASCADE,
      FOREIGN KEY (segment_id, owner_id, journey_id)
        REFERENCES track_segments(id, owner_id, journey_id) ON DELETE CASCADE
    ) STRICT;

    CREATE INDEX journeys_owner_status_started_idx
      ON journeys(owner_id, status, started_at DESC, id);
    CREATE INDEX journeys_plan_started_idx
      ON journeys(owner_id, trip_plan_id, started_at DESC, id);
    CREATE INDEX track_segments_journey_sequence_idx
      ON track_segments(owner_id, journey_id, sequence, id);
    CREATE INDEX track_points_journey_sequence_idx
      ON track_points(owner_id, journey_id, sequence, id);
    CREATE INDEX track_points_journey_quality_idx
      ON track_points(owner_id, journey_id, quality_flag, sequence);
    """

  private static let lifeLinksSQL = """
    CREATE TABLE transaction_journey_links (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      transaction_root_id TEXT NOT NULL,
      journey_id TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('transport', 'parking', 'toll', 'meal', 'other')),
      created_by TEXT NOT NULL CHECK (created_by = 'user'),
      confirmed_at REAL NOT NULL CHECK (confirmed_at >= 0),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      updated_at REAL NOT NULL CHECK (updated_at >= created_at),
      UNIQUE (id, owner_id),
      UNIQUE (owner_id, transaction_root_id, journey_id),
      FOREIGN KEY (transaction_root_id, owner_id)
        REFERENCES ledger_transactions(id, owner_id) ON DELETE RESTRICT,
      FOREIGN KEY (journey_id, owner_id)
        REFERENCES journeys(id, owner_id) ON DELETE CASCADE
    ) STRICT;

    CREATE INDEX transaction_journey_links_journey_idx
      ON transaction_journey_links(owner_id, journey_id, confirmed_at, id);
    CREATE INDEX transaction_journey_links_root_idx
      ON transaction_journey_links(owner_id, transaction_root_id, id);
    """

  private static let manualLocationCompatibilitySQL = """
    ALTER TABLE location_snapshots RENAME TO location_snapshots_v5;
    DROP INDEX location_snapshots_owner_created_idx;

    CREATE TABLE location_snapshots (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 200),
      address TEXT CHECK (address IS NULL OR length(trim(address)) BETWEEN 1 AND 500),
      latitude REAL CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
      longitude REAL CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
      coordinate_system TEXT CHECK (coordinate_system IS NULL OR coordinate_system = 'wgs84'),
      source TEXT NOT NULL CHECK (source IN ('manual', 'mapkit')),
      horizontal_accuracy REAL CHECK (horizontal_accuracy IS NULL OR horizontal_accuracy >= 0),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      UNIQUE (id, owner_id),
      CHECK (
        (latitude IS NULL AND longitude IS NULL AND coordinate_system IS NULL)
        OR (latitude IS NOT NULL AND longitude IS NOT NULL AND coordinate_system = 'wgs84')
      ),
      FOREIGN KEY (owner_id) REFERENCES local_profiles(id) ON DELETE CASCADE
    ) STRICT;

    INSERT INTO location_snapshots (
      id, owner_id, name, address, latitude, longitude,
      coordinate_system, source, horizontal_accuracy, created_at
    )
    SELECT
      id, owner_id, name, address, latitude, longitude,
      coordinate_system, source, horizontal_accuracy, created_at
    FROM location_snapshots_v5;

    DROP TABLE location_snapshots_v5;

    CREATE INDEX location_snapshots_owner_created_idx
      ON location_snapshots(owner_id, created_at DESC, id);
    """

  private static let journeyExpenseReviewSQL = """
    ALTER TABLE journeys
      ADD COLUMN expense_review_state TEXT NOT NULL DEFAULT 'pending'
        CHECK (expense_review_state IN ('pending', 'no_expense', 'has_expense'));

    UPDATE journeys
    SET expense_review_state = 'has_expense'
    WHERE EXISTS (
      SELECT 1
      FROM transaction_journey_links AS link
      WHERE link.owner_id = journeys.owner_id
        AND link.journey_id = journeys.id
    );
    """

  private static let tripPlanRevisionReviewSQL = """
    ALTER TABLE trip_plans
      ADD COLUMN plan_version INTEGER NOT NULL DEFAULT 1
        CHECK (plan_version >= 1);

    ALTER TABLE trip_plans
      ADD COLUMN display_name_value_source TEXT NOT NULL DEFAULT 'user'
        CHECK (display_name_value_source IN ('event', 'user'));

    ALTER TABLE trip_plans
      ADD COLUMN display_name_user_overridden_at REAL
        CHECK (
          display_name_user_overridden_at IS NULL
          OR display_name_user_overridden_at >= 0
        );

    DROP INDEX calendar_occurrence_revisions_owner_pending_idx;
    ALTER TABLE calendar_occurrence_revisions
      RENAME TO calendar_occurrence_revisions_v7;

    CREATE TABLE calendar_occurrence_revisions (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      calendar_occurrence_id TEXT NOT NULL,
      from_version INTEGER NOT NULL CHECK (from_version >= 1),
      to_version INTEGER NOT NULL CHECK (to_version = from_version + 1),
      old_starts_at REAL NOT NULL,
      new_starts_at REAL NOT NULL,
      old_ends_at REAL NOT NULL,
      new_ends_at REAL NOT NULL,
      old_timezone_id TEXT NOT NULL,
      new_timezone_id TEXT NOT NULL,
      old_title TEXT,
      new_title TEXT,
      old_location_text TEXT,
      new_location_text TEXT,
      detected_at REAL NOT NULL CHECK (detected_at >= 0),
      resolution_state TEXT NOT NULL DEFAULT 'pending'
        CHECK (resolution_state IN ('pending', 'accepted', 'ignored')),
      resolved_at REAL,
      UNIQUE (calendar_occurrence_id, to_version),
      CHECK (
        (resolution_state = 'pending' AND resolved_at IS NULL)
        OR (
          resolution_state IN ('accepted', 'ignored')
          AND resolved_at IS NOT NULL
          AND resolved_at >= detected_at
        )
      ),
      FOREIGN KEY (calendar_occurrence_id, owner_id)
        REFERENCES calendar_occurrences(id, owner_id) ON DELETE CASCADE
    ) STRICT;

    INSERT INTO calendar_occurrence_revisions (
      id, owner_id, calendar_occurrence_id, from_version, to_version,
      old_starts_at, new_starts_at, old_ends_at, new_ends_at,
      old_timezone_id, new_timezone_id, old_title, new_title,
      old_location_text, new_location_text, detected_at,
      resolution_state, resolved_at
    )
    SELECT
      id, owner_id, calendar_occurrence_id, from_version, to_version,
      old_starts_at, new_starts_at, old_ends_at, new_ends_at,
      old_timezone_id, new_timezone_id, old_title, new_title,
      old_location_text, new_location_text, detected_at,
      resolution_state,
      CASE WHEN resolution_state = 'pending' THEN NULL ELSE detected_at END
    FROM calendar_occurrence_revisions_v7;

    DROP TABLE calendar_occurrence_revisions_v7;

    CREATE INDEX calendar_occurrence_revisions_owner_pending_idx
      ON calendar_occurrence_revisions(owner_id, resolution_state, detected_at, id);
    """
}
