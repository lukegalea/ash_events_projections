# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

import Config

# Required by ash >= 3.33 (RequireStringLengthCountConfig transformer).
# `:codepoints` is the recommended mode for SQL data layers: it matches how
# the database counts string length, so `min_length`/`max_length` validation
# is consistent with stored-value bounds everywhere.
config :ash, default_string_length_count: :codepoints

if Mix.env() == :test do
  import_config "test.exs"
end
