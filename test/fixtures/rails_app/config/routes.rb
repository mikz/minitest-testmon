# frozen_string_literal: true

Rails.application.routes.draw do
  get "/greeting", to: "greetings#show"
  get "/dashboard", to: "greetings#dashboard"
end
