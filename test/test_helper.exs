# Keep tests off the real progress file: load is empty, save is a no-op.
Application.put_env(:course, :progress_file, nil)

ExUnit.start()
