# frozen_string_literal: true

require "sequel"
require "uri"

module Rentsync
  MIGRATIONS_DIR = File.expand_path("../../db/migrations", __dir__)
  MIGRATION_LOCK_ID = 4_002_001 # differs from the mock's, though the databases differ too

  class << self
    attr_reader :db

    def connect_db!(url = Settings.database_url)
      return @db if @db

      Sequel.default_timezone = :utc
      Sequel.extension :pg_array_ops, :pg_json_ops
      @db = Sequel.connect(url, max_connections: Integer(ENV.fetch("DB_POOL", 5)))
      @db.extension :pg_array, :pg_json
      Sequel::Model.db = @db
      Sequel::Model.require_valid_table = false
      @db
    end

    # Creates the database named in `url` if it does not exist, by connecting to the
    # server's `postgres` database. Safe when several processes race: losing the race
    # to CREATE DATABASE is treated as success.
    def ensure_database!(url = Settings.database_url)
      uri = URI.parse(url)
      name = uri.path.delete_prefix("/")
      admin = uri.dup.tap { |u| u.path = "/postgres" }.to_s
      Sequel.connect(admin) do |server|
        next unless server[:pg_database].where(datname: name).empty?

        server.run("CREATE DATABASE #{server.literal(name.to_sym)}")
      rescue Sequel::DatabaseError => e
        raise unless e.message.include?("already exists")
      end
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
