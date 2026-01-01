# Ensure the application is started for tests that depend on it
{:ok, _} = Application.ensure_all_started(:otturnaut)

# Set up Mimic for mocking
Mimic.copy(Otturnaut.Command.PortWrapper)
Mimic.copy(Req)

ExUnit.start()
