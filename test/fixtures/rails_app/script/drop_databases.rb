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
  admin.exec_params(
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
    [database]
  )
  admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(database)}")
end

admin.close
