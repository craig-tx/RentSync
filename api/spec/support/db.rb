# frozen_string_literal: true

# Default: every example runs inside a transaction that is always rolled back.
# `:committed` examples skip the wrapper and truncate before and after instead, so
# other connections, threads and processes can see their rows.
module DbSupport
  module_function

  def truncate_all!
    db = Rentsync.db
    tables = db.tables - %i[schema_migrations schema_info]
    return if tables.empty?

    db.run("TRUNCATE #{tables.map { |t| db.literal(t) }.join(', ')} RESTART IDENTITY CASCADE")
  end
end

RSpec.configure do |config|
  config.before(:suite) { DbSupport.truncate_all! }

  config.around do |example|
    if example.metadata[:committed]
      DbSupport.truncate_all!
      begin
        example.run
      ensure
        DbSupport.truncate_all!
      end
    else
      Rentsync.db.transaction(rollback: :always, auto_savepoint: true) { example.run }
    end
  end
end
