# Ensure the application is started for tests that depend on it
{:ok, _} = Application.ensure_all_started(:otturnaut)

# Set up Mimic for mocking
Mimic.copy(Otturnaut.Command.PortWrapper)
Mimic.copy(Otturnaut.Command)
Mimic.copy(Otturnaut.Source.Git)
Mimic.copy(Otturnaut.Runtime.Docker)
Mimic.copy(File)
Mimic.copy(Req)

ExUnit.start()
