# frozen_string_literal: true

module Subject
  module_function

  def alpha
    1 + 1
  end

  def beta
    2 + 2
  end

  def string_literal
    "literal-v1"
  end

  def dispatch
    helper_one
  end

  def helper_one
    "helper-one"
  end

  def helper_two
    "helper-two"
  end

  def nested_block
    [1, 2].map { |value| value * 2 }
  end

  def guarded(value)
    (value > 1) ? :large : :small
  end
end
