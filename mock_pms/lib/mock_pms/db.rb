# frozen_string_literal: true

require "sequel"

module MockPms
  MIGRATIONS_DIR = File.expand_path("../../db/migrations", __dir__)

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
      Sequel::Model.plugin :timestamps, update_on_create: true
      @db
    end

    def migrate!
      Sequel.extension :migration
      Sequel::Migrator.run(db, MIGRATIONS_DIR)
    end
  end
end
