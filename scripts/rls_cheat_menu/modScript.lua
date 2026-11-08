-- RLS Career Cheat Menu: load the backend extension once the mod is mounted.
-- Deferred a little so RLS Career Overhaul's own loader can run first; our
-- extension only looks RLS modules up lazily, so the order is not critical.
setExtensionUnloadMode("rlsCheatMenu", "manual")
core_jobsystem.create(function(job)
  job.sleep(0.5)
  extensions.load("rlsCheatMenu")
end)
