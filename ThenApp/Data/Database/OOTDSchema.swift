import GRDB

nonisolated enum OOTDSchema {
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("ootd_v1_wardrobe") { db in
      try db.execute(sql: """
        CREATE TABLE wardrobe_items (
          id TEXT PRIMARY KEY NOT NULL,
          name TEXT NOT NULL CHECK (length(name) >= 1),
          category TEXT NOT NULL CHECK (category IN ('top','bottom','onePiece','outerwear','shoes','bag','accessory')),
          availability TEXT NOT NULL CHECK (availability IN ('wearable','laundry','lentOut','packed')),
          source TEXT NOT NULL CHECK (source IN ('wardrobe','quickAdd')),
          revision INTEGER NOT NULL CHECK (revision >= 1),
          createdAt REAL NOT NULL,
          updatedAt REAL NOT NULL CHECK (updatedAt >= createdAt)
        );
        CREATE INDEX wardrobe_order ON wardrobe_items(createdAt DESC, id ASC);
        """)
    }
    migrator.registerMigration("ootd_v2_wardrobe_photos") { db in
      try db.execute(sql: """
        CREATE TABLE wardrobe_photos (
          id TEXT PRIMARY KEY NOT NULL,
          itemID TEXT REFERENCES wardrobe_items(id) ON DELETE SET NULL,
          thumbnailID TEXT UNIQUE NOT NULL CHECK (thumbnailID != id),
          state TEXT NOT NULL CHECK (state IN ('importing','ready','deleting')),
          version INTEGER NOT NULL CHECK (version = 1),
          quality TEXT NOT NULL CHECK (quality = 'catalog_ready'),
          normalizedFormat TEXT NOT NULL CHECK (normalizedFormat IN ('jpeg','png')),
          normalizedWidth INTEGER NOT NULL CHECK (normalizedWidth > 0),
          normalizedHeight INTEGER NOT NULL CHECK (normalizedHeight > 0),
          normalizedByteCount INTEGER NOT NULL CHECK (normalizedByteCount > 0),
          normalizedHash TEXT NOT NULL CHECK (length(normalizedHash) = 64),
          normalizedPath TEXT NOT NULL,
          thumbnailFormat TEXT NOT NULL CHECK (thumbnailFormat IN ('jpeg','png')),
          thumbnailWidth INTEGER NOT NULL CHECK (thumbnailWidth > 0 AND thumbnailWidth <= normalizedWidth),
          thumbnailHeight INTEGER NOT NULL CHECK (thumbnailHeight > 0 AND thumbnailHeight <= normalizedHeight),
          thumbnailByteCount INTEGER NOT NULL CHECK (thumbnailByteCount > 0),
          thumbnailHash TEXT NOT NULL CHECK (length(thumbnailHash) = 64),
          thumbnailPath TEXT NOT NULL,
          createdAt REAL NOT NULL,
          CHECK (itemID IS NOT NULL OR state = 'deleting')
        );
        CREATE UNIQUE INDEX wardrobe_one_ready_photo ON wardrobe_photos(itemID) WHERE state = 'ready';
        CREATE INDEX wardrobe_photo_cleanup ON wardrobe_photos(state);
        """)
    }
    migrator.registerMigration("ootd_v3_unattached_photo_imports") { db in
      try db.execute(sql: """
        CREATE TABLE wardrobe_photos_new (
          id TEXT PRIMARY KEY NOT NULL,
          itemID TEXT REFERENCES wardrobe_items(id) ON DELETE SET NULL,
          thumbnailID TEXT UNIQUE NOT NULL CHECK (thumbnailID != id),
          state TEXT NOT NULL CHECK (state IN ('importing','ready','deleting')),
          version INTEGER NOT NULL CHECK (version = 1),
          quality TEXT NOT NULL CHECK (quality = 'catalog_ready'),
          normalizedFormat TEXT NOT NULL CHECK (normalizedFormat IN ('jpeg','png')),
          normalizedWidth INTEGER NOT NULL CHECK (normalizedWidth > 0),
          normalizedHeight INTEGER NOT NULL CHECK (normalizedHeight > 0),
          normalizedByteCount INTEGER NOT NULL CHECK (normalizedByteCount > 0),
          normalizedHash TEXT NOT NULL CHECK (length(normalizedHash) = 64),
          normalizedPath TEXT NOT NULL,
          thumbnailFormat TEXT NOT NULL CHECK (thumbnailFormat IN ('jpeg','png')),
          thumbnailWidth INTEGER NOT NULL CHECK (thumbnailWidth > 0 AND thumbnailWidth <= normalizedWidth),
          thumbnailHeight INTEGER NOT NULL CHECK (thumbnailHeight > 0 AND thumbnailHeight <= normalizedHeight),
          thumbnailByteCount INTEGER NOT NULL CHECK (thumbnailByteCount > 0),
          thumbnailHash TEXT NOT NULL CHECK (length(thumbnailHash) = 64),
          thumbnailPath TEXT NOT NULL,
          createdAt REAL NOT NULL,
          CHECK (itemID IS NOT NULL OR state != 'ready')
        );
        INSERT INTO wardrobe_photos_new SELECT * FROM wardrobe_photos;
        DROP TABLE wardrobe_photos;
        ALTER TABLE wardrobe_photos_new RENAME TO wardrobe_photos;
        CREATE UNIQUE INDEX wardrobe_one_ready_photo ON wardrobe_photos(itemID) WHERE state = 'ready';
        CREATE INDEX wardrobe_photo_cleanup ON wardrobe_photos(state);
        """)
    }
    migrator.registerMigration("ootd_v4_outfit_plans") { db in
      try db.execute(sql: """
        CREATE TABLE outfit_plans (
          id TEXT PRIMARY KEY NOT NULL,
          localDate TEXT, timeZone TEXT, contextSummary TEXT, sourceKind TEXT,
          status TEXT NOT NULL CHECK (status IN ('active','cancelled','deleted')),
          revision INTEGER, createdAt REAL, updatedAt REAL,
          CHECK ((status = 'deleted' AND localDate IS NULL AND timeZone IS NULL AND contextSummary IS NULL
            AND sourceKind IS NULL AND revision IS NULL AND createdAt IS NULL AND updatedAt IS NULL)
          OR (status != 'deleted' AND localDate IS NOT NULL AND length(localDate) = 10 AND timeZone IS NOT NULL
            AND sourceKind IS NOT NULL AND sourceKind = 'manual' AND revision IS NOT NULL AND revision >= 1
            AND createdAt IS NOT NULL AND updatedAt IS NOT NULL AND updatedAt >= createdAt))
        );
        CREATE INDEX outfit_plan_date_order ON outfit_plans(localDate DESC, createdAt DESC, id ASC) WHERE status != 'deleted';
        CREATE TABLE outfit_plan_items (
          planID TEXT NOT NULL REFERENCES outfit_plans(id) ON DELETE CASCADE,
          ordinal INTEGER NOT NULL CHECK (ordinal >= 0 AND ordinal < 20),
          wardrobeItemID TEXT REFERENCES wardrobe_items(id) ON DELETE RESTRICT,
          itemRevision INTEGER, name TEXT, category TEXT, availability TEXT,
          photoAssetID TEXT REFERENCES wardrobe_photos(id) ON DELETE SET NULL,
          redacted INTEGER NOT NULL CHECK (redacted IN (0,1)),
          PRIMARY KEY (planID, ordinal),
          CHECK ((redacted = 1 AND wardrobeItemID IS NULL AND itemRevision IS NULL AND name IS NULL
            AND category IS NULL AND availability IS NULL AND photoAssetID IS NULL)
          OR (redacted = 0 AND wardrobeItemID IS NOT NULL AND itemRevision IS NOT NULL AND itemRevision >= 1
            AND name IS NOT NULL AND length(name) >= 1 AND category IS NOT NULL
            AND category IN ('top','bottom','onePiece','outerwear','shoes','bag','accessory')
            AND availability IS NOT NULL AND availability IN ('wearable','laundry','lentOut','packed')))
        );
        CREATE UNIQUE INDEX outfit_plan_unique_item ON outfit_plan_items(planID, wardrobeItemID) WHERE wardrobeItemID IS NOT NULL;
        CREATE INDEX outfit_plan_wardrobe_references ON outfit_plan_items(wardrobeItemID);
        CREATE TABLE outfit_plan_mutations (
          id TEXT PRIMARY KEY NOT NULL,
          planID TEXT NOT NULL REFERENCES outfit_plans(id) ON DELETE RESTRICT,
          operation TEXT NOT NULL CHECK (operation IN ('save','cancel','delete')),
          fingerprint TEXT CHECK (fingerprint IS NULL OR length(fingerprint) = 64)
        );
        CREATE INDEX outfit_plan_mutation_owner ON outfit_plan_mutations(planID);
        """)
    }
    return migrator
  }
}
