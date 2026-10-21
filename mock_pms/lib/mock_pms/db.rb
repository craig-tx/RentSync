# frozen_string_literal: true

require "sequel"

module MockPms
  MIGRATIONS_DIR = File.expand_path("../../db/migrations", __dir__)
  MIGRATION_LOCK_ID = 4_001_001

  class << self
    attr_reader :db

    def connect_db!(url = Settings.database_url)
      return @db if @db

      Sequel.default_timezone = :utc
      Sequel.extension :pg_array_ops, :pg_json_ops
      @db = Sequel.connect(url, max_connections: Integer(ENV.fetch("DB_POOL", 10)))
      @db.extension :pg_array, :pg_json
      Sequel::Model.db = @db
      Sequel::Model.require_valid_table = false
      @db
    end

    # Runs pending migrations. Every web and worker process calls this at boot, so a
    # Postgres advisory lock makes concurrent instances wait their turn instead of
    # racing: a single-runner job holding a lock in the shared store (Constitution X).
    def migrate!
      Sequel.extension :migration
      db.synchronize do
        db.get(Sequel.function(:pg_advisory_lock, MIGRATION_LOCK_ID))
        begin
          Sequel::Migrator.run(db, MIGRATIONS_DIR)
        ensure
          db.get(Sequel.function(:pg_advisory_unlock, MIGRATION_LOCK_ID))
        end
      end
    end
  end
end
