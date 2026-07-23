# frozen_string_literal: true

# Top-level executable code has no method identity. The ISeq provider must
# conservatively fingerprint the whole file instead of dropping the edge.
TOP_LEVEL_FALLBACK_VALUE = 10
