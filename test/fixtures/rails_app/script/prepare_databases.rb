# frozen_string_literal: true

require "pg"

base = ENV.fetch("RAILS_ACCEPTANCE_DATABASE")
abort "unsafe acceptance database name" unless base.match?(/\Aminitest_testmon_acceptance_[a-z0-9_]+\z/)

host = ENV.fetch("RAILS_ACCEPTANCE_DB_HOST", "localhost")
user = ENV.fetch("RAILS_ACCEPTANCE_DB_USER", "postgres")
password = ENV["RAILS_ACCEPTANCE_DB_PASSWORD"]
workers = Integer(ENV.fetch("PARALLEL_WORKERS", "1"))
admin = PG.connect(host:, user:, password:, dbname: "postgres")

databases = [base, *workers.times.map { |number| "#{base}_#{number}" }].uniq

databases.each do |database|
  unless admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [database]).any?
    admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(database)}")
  end

  connection = PG.connect(host:, user:, password:, dbname: database)
  connection.exec("DROP TABLE IF EXISTS widgets")
  connection.exec(<<~SQL)
    CREATE TABLE widgets (
      id bigserial PRIMARY KEY,
      name varchar NOT NULL,
      created_at timestamp NOT NULL,
      updated_at timestamp NOT NULL
    )
  SQL
  connection.close
end

admin.close
