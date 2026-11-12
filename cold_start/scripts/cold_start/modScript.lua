-- Cold Start: start the game-engine manager when the mod is mounted.
-- The manager loads the per-vehicle "coldStart" extension into every vehicle.
setExtensionUnloadMode("coldStartManager", "manual")
extensions.load("coldStartManager")
