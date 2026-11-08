-- Dynamic Tyres: start the game-engine manager when the mod is mounted.
-- The manager loads the per-vehicle "dynamicTyres" extension into every vehicle.
setExtensionUnloadMode("dynamicTyresManager", "manual")
extensions.load("dynamicTyresManager")
