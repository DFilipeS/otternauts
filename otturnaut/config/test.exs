import Config

# Log level needs to allow info/error for capture_log tests
# Set to :info but tests won't print logs unless capture_log is used
config :logger, level: :info

# Suppress log output during tests (but allow capture_log to work)
config :logger, :console, level: :critical
