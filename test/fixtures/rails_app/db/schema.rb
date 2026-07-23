# frozen_string_literal: true

ActiveRecord::Schema[8.1].define(version: 1) do
  create_table :widgets, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end
end
