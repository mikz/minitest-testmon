# frozen_string_literal: true

class GreetingsController < ApplicationController
  def show
    render template: "greetings/runtime" if params[:runtime] == "1"
  end

  def dashboard
    @widget_count = Widget.count
  end
end
