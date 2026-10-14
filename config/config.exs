# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

import Config

# Ash's string-length counting ruling (the resolved ash requires it):
# codepoints — how SQL counts, so validation matches storage bounds.
config :ash, default_string_length_count: :codepoints

import_config("test.exs")
