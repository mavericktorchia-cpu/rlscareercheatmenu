-- Dynamic Tyres - per-vehicle tyre simulation (runs in each vehicle's Lua VM).
--
-- Every wheel gets:
--   * temperature: three tread zones (inner / middle / outer) plus the carcass, heated by sliding,
--     rolling flex and brake heat, cooled by airflow, rain and water;
--   * wear: tread lost to rolling distance and sliding energy, faster when overheated or
--     at the wrong pressure;
--   * pressure: follows the carcass temperature (gas law) and is applied to the physics tyre;
--   * surface and wet grip: compound vs surface (slick, sport, road, all-terrain, mud, winter),
--     rain wetness, tread drainage and aquaplaning;
--   * extras: scrub-in of new tyres, heat cycling, flat spots from lock-ups, punctures and blowouts.
--
-- The result is one grip multiplier per wheel, applied through wheel:setFrictionThermalSensitivity.
-- If RLS Career Overhaul's tyre system ("overhaulTires") or Tyre Wear and Thermals
-- ("luukstyrethermalsandwear") runs on this vehicle, this extension backs off and leaves grip to it.
--
-- Settings, ambient temperature and weather come from the GE manager (dynamicTyresManager) via setContext.

local M = {}

local STREAM = "dynamicTyres"
local ATM = 101325          -- Pa
local PSI = 6894.757        -- Pa per psi
local KELVIN = 273.15
local GRAVITY = 9.81

local max, min, abs, sqrt, floor = math.max, math.min, math.abs, math.sqrt, math.floor

local function clamp(x, lo, hi) return max(lo, min(hi, x)) end
local function smoothstep(x)
  x = clamp(x, 0, 1)
  return x * x * (3 - 2 * x)
end

-- Context (from GE) ----------------------------------------------------------------------------------

local ctx = {
  enabled = true,
  ambient = 20,           -- deg C
  wetness = 0,            -- 0 dry .. 1 standing water
  temperature = true,
  wear = true,
  pressure = true,
  surface = true,
  extras = true,
  punctures = true,
  applyPressure = true,   -- push simulated pressure to the physics tyre
  aiVehicles = true,
  resetWearOnReset = true,
  gripStrength = 1,       -- 0 = cosmetic only, 1 = full, up to 1.5
  heatRate = 1,
  wearRate = 1,
}

-- Compound data --------------------------------------------------------------------------------------
-- opt: best tread temperature; plateau: +/- band with full grip; cold/hot: degrees past the plateau until
-- the full cold/hot loss applies. wetLoss: grip lost on fully wet tarmac with new tread.
-- drain: how well tread clears water (aquaplaning speed). wear: relative wear rate.
local COMPOUNDS = {
  slick      = {label = "Slick",       opt = 95, plateau = 10, cold = 45, hot = 40, coldLoss = 0.25, hotLoss = 0.25, wetLoss = 0.55, drain = 0.0, wear = 1.6, cycles = true},
  sport      = {label = "Sport",       opt = 80, plateau = 12, cold = 50, hot = 45, coldLoss = 0.16, hotLoss = 0.20, wetLoss = 0.34, drain = 0.8, wear = 1.3, cycles = true},
  road       = {label = "Road",        opt = 60, plateau = 15, cold = 60, hot = 50, coldLoss = 0.08, hotLoss = 0.15, wetLoss = 0.28, drain = 1.0, wear = 1.0},
  allTerrain = {label = "All-terrain", opt = 50, plateau = 15, cold = 60, hot = 50, coldLoss = 0.07, hotLoss = 0.15, wetLoss = 0.30, drain = 1.1, wear = 0.8},
  mud        = {label = "Mud-terrain", opt = 45, plateau = 15, cold = 60, hot = 45, coldLoss = 0.07, hotLoss = 0.16, wetLoss = 0.34, drain = 1.2, wear = 1.1},
  winter     = {label = "Winter",      opt = 15, plateau = 15, cold = 40, hot = 40, coldLoss = 0.04, hotLoss = 0.20, wetLoss = 0.25, drain = 1.2, wear = 1.3},
}

-- Relative grip of each compound per surface, on top of BeamNG's own ground model friction.
local SURFACE_GRIP = {
  --              paved  dirt   mud    sand   grass  snow   ice
  slick      = {1.04,  0.84,  0.70,  0.75,  0.80,  0.70,  0.70},
  sport      = {1.02,  0.92,  0.80,  0.85,  0.88,  0.80,  0.75},
  road       = {1.00,  1.00,  0.92,  0.95,  0.97,  0.90,  0.85},
  allTerrain = {0.97,  1.06,  1.05,  1.05,  1.04,  1.00,  0.90},
  mud        = {0.93,  1.08,  1.15,  1.08,  1.06,  0.98,  0.85},
  winter     = {0.96,  1.00,  0.95,  1.00,  1.00,  1.25,  1.35},
}
local SURFACES = {"paved", "dirt", "mud", "sand", "grass", "snow", "ice"}
local SURFACE_INDEX = {}
for i, name in ipairs(SURFACES) do SURFACE_INDEX[name] = i end
-- Loose and rough surfaces chew tread faster.
local SURFACE_WEAR = {paved = 1, dirt = 1.6, mud = 0.8, sand = 1.4, grass = 0.7, snow = 0.5, ice = 0.4}

-- Vehicle data helpers -------------------------------------------------------------------------------

local wheelCache = {}   -- static per-wheel data
local wheelState = {}   -- simulated per-wheel state
local vehicleMass = 1000
local yieldReason = nil -- non-nil while another tyre system owns grip
local yieldCheckTimer = 0
local gripApplied = false
local telemetryTimer = 0
local waterTimer = 0
local materialNames = nil

local function wheelConfig(index)
  return v and v.data and v.data.wheels and v.data.wheels[index] or {}
end

local function computeMass()
  local mass = 0
  for _, node in pairs(v and v.data and v.data.nodes or {}) do
    mass = mass + (tonumber(node.nodeWeight) or 0)
  end
  return max(mass, 50)
end

local function tirePartName(wheelName)
  local front = string.upper(string.sub(tostring(wheelName or ""), 1, 1)) == "F"
  local best, bestScore
  for path, part in pairs(v and v.data and v.data.activeParts or {}) do
    local lp, ln = string.lower(tostring(path)), string.lower(tostring(part))
    if string.find(ln, "tire", 1, true) or string.find(ln, "tyre", 1, true) then
      local score = 1
      local isFrontPart = string.find(ln, "tire_f", 1, true) or string.find(lp, "wheel_f", 1, true)
      local isRearPart = string.find(ln, "tire_r", 1, true) or string.find(lp, "wheel_r", 1, true)
      if (front and isFrontPart) or (not front and isRearPart) then score = score + 10 end
      if not bestScore or score > bestScore then best, bestScore = ln .. " " .. lp, score end
    end
  end
  return best or ""
end

local function has(text, words)
  for _, w in ipairs(words) do
    if string.find(text, w, 1, true) then return true end
  end
  return false
end

local function classifyCompound(name, cfg)
  if has(name, {"winter", "snow", "studded", "ice"}) then return "winter" end
  if has(name, {"slick"}) then return "slick" end
  if has(name, {"mud", "_mt", "crawl", "trophy", "bogger"}) then return "mud" end
  if has(name, {"offroad", "off_road", "allterrain", "all_terrain", "_at", "rally", "gravel", "dirt"}) then return "allTerrain" end
  if has(name, {"race", "semi", "sport", "perf", "drift", "drag", "track", "r_comp", "competition"}) then return "sport" end
  if (tonumber(cfg.frictionCoef) or 1) >= 1.2 then return "sport" end
  return "road"
end

local function surfaceOf(materialId)
  if not materialNames and particles and particles.getMaterialsParticlesTable then
    materialNames = particles.getMaterialsParticlesTable()
  end
  local row = materialNames and materialNames[materialId]
  local name = string.upper(tostring(row and row.name or ""))
  local wetSpot = string.find(name, "WET", 1, true) or string.find(name, "WATER", 1, true) or string.find(name, "PUDDLE", 1, true)
  local surface = "paved"
  if string.find(name, "ICE", 1, true) then surface = "ice"
  elseif string.find(name, "SNOW", 1, true) then surface = "snow"
  elseif string.find(name, "MUD", 1, true) then surface = "mud"
  elseif string.find(name, "SAND", 1, true) then surface = "sand"
  elseif string.find(name, "GRASS", 1, true) or string.find(name, "FOLIAGE", 1, true) then surface = "grass"
  elseif string.find(name, "DIRT", 1, true) or string.find(name, "GRAVEL", 1, true) or string.find(name, "ROCK", 1, true) then surface = "dirt"
  end
  return surface, wetSpot ~= nil, name
end

local function cacheWheel(index, rotator)
  local c = wheelCache[index]
  if c then return c end
  local cfg = wheelConfig(index)
  c = {}
  c.name = tostring(rotator.name or cfg.name or index)
  c.radius = tonumber(rotator.radius or cfg.radius) or 0.33
  c.width = tonumber(cfg.tireWidth or rotator.tireWidth) or 0.215
  c.compoundId = classifyCompound(tirePartName(c.name), cfg)
  c.compound = COMPOUNDS[c.compoundId]
  local size = clamp(c.width / 0.215, 0.6, 2.5) * clamp((c.radius / 0.33) ^ 2, 0.5, 6)
  c.zoneHeatCap = 2200 * size     -- J/K per tread zone
  c.coreHeatCap = 9000 * size     -- J/K carcass + air
  -- Design cold pressure from the JBeam (gauge, Pa). Without it, pressure stays a model-only value.
  local psi = tonumber(cfg.pressurePSI)
  c.designPressure = (psi and psi > 0 and psi or 30) * PSI
  c.hasRealPressure = psi ~= nil and psi > 0
  local groups = v and v.data and v.data.pressureGroups
  c.pressureGroupId = cfg.pressureGroup and groups and groups[cfg.pressureGroup] or nil
  -- Remember the wheel's stock thermal friction curve so grip can be handed back untouched.
  c.stock = {peak = 350, rise = 1e7, fall = 1e7, riseShape = 0, fallShape = 0, base = 1, peakCoef = 1}
  if cfg.enableThermalFriction == true then
    c.stock.peak = tonumber(cfg.thermalFrictionPeakTemp) or c.stock.peak
    c.stock.rise = tonumber(cfg.thermalFrictionRiseRange) or c.stock.rise
    c.stock.fall = tonumber(cfg.thermalFrictionFallRange) or c.stock.fall
    c.stock.riseShape = tonumber(cfg.thermalFrictionRiseShape) or 0
    c.stock.fallShape = tonumber(cfg.thermalFrictionFallShape) or 0
    c.stock.base = 0
    c.stock.peakCoef = 1
  end
  wheelCache[index] = c
  return c
end

local function freshState(c)
  local t = ctx.ambient
  return {
    zones = {t, t, t},          -- inner, middle, outer tread surface (deg C)
    core = t,                   -- carcass / air (deg C)
    tread = 1,                  -- 1 new .. 0 cords
    coldPressure = c.designPressure, -- gauge Pa at fitting temperature
    fitTemp = t,
    pressure = c.designPressure,
    appliedPressure = nil,
    distance = 0,               -- metres since fitted (scrub-in)
    heatCycles = 0,
    wasHot = false,
    flatSpot = 0,
    flat = false,
    grip = 1,
    factors = {},
  }
end

local function stateFor(index, c)
  local s = wheelState[index]
  if not s then
    s = freshState(c)
    wheelState[index] = s
  end
  return s
end

-- Grip output ----------------------------------------------------------------------------------------

local function setGrip(index, c, multiplier, force)
  if not force and c.appliedGrip and abs(c.appliedGrip - multiplier) < 1e-4 then return end
  local wheel = obj:getWheel(index)
  if not wheel then return end
  local useStock = multiplier == nil
  multiplier = multiplier or 1
  if useStock then
    local st = c.stock
    wheel:setFrictionThermalSensitivity(st.peak, st.rise, st.fall, st.riseShape, st.fallShape, st.base, st.peakCoef, 1)
  else
    -- A flat curve (huge ranges) makes friction independent of the engine's own tyre temperature;
    -- this model supplies the temperature effect instead.
    wheel:setFrictionThermalSensitivity(350, 1e7, 1e7, 0, 0, multiplier, multiplier, 1)
  end
  c.appliedGrip = not useStock and multiplier or nil
end

local function applyPressure(c, s, rotator)
  if not (ctx.applyPressure and ctx.pressure and c.hasRealPressure and c.pressureGroupId) then return end
  if s.flat or rotator.isTireDeflated or rotator.isBroken then return end
  if s.appliedPressure and abs(s.appliedPressure - s.pressure) < 1500 then return end
  local ok = pcall(obj.setGroupPressureRel, obj, c.pressureGroupId, max(0, s.pressure))
  if ok then s.appliedPressure = s.pressure else c.hasRealPressure = false end
end

local function restoreAll()
  for index, c in pairs(wheelCache) do
    setGrip(index, c, nil, true)
    local s = wheelState[index]
    if s and c.hasRealPressure and c.pressureGroupId and not s.flat and s.appliedPressure then
      pcall(obj.setGroupPressureRel, obj, c.pressureGroupId, c.designPressure)
      s.appliedPressure = nil
    end
  end
  gripApplied = false
end

-- Model ----------------------------------------------------------------------------------------------

local function temperatureGrip(comp, t)
  local lowEdge, highEdge = comp.opt - comp.plateau, comp.opt + comp.plateau
  if t < lowEdge then
    return 1 - comp.coldLoss * smoothstep((lowEdge - t) / comp.cold)
  elseif t > highEdge then
    -- Past the hot range grip keeps falling (blistering), down to twice the hot loss.
    local x = (t - highEdge) / comp.hot
    return 1 - comp.hotLoss * (smoothstep(x) + max(0, x - 1) * 0.5)
  end
  return 1
end

local function surfaceTemp(s)
  return s.zones[1] * 0.3 + s.zones[2] * 0.4 + s.zones[3] * 0.3
end

local function inWater(rotator)
  if rotator.lastTreadContactNode and obj:inWater(rotator.lastTreadContactNode) then return true end
  return (rotator.node1 and obj:inWater(rotator.node1)) or (rotator.node2 and obj:inWater(rotator.node2)) or false
end

local function puncture(index, s, reason)
  if s.flat then return end
  s.flat = true
  s.flatReason = reason
  if beamstate and beamstate.deflateTire then pcall(beamstate.deflateTire, index) end
  if ui_message then ui_message("Tyre " .. (wheelCache[index] and wheelCache[index].name or index) .. ": " .. reason, 5, "dynamicTyres") end
end

local function simulateWheel(index, rotator, dt, speed, refLoad, braking)
  local c = cacheWheel(index, rotator)
  local s = stateFor(index, c)
  local comp = c.compound

  local load = max(abs(tonumber(rotator.downForceRaw or rotator.downForce) or 0), 0)
  local contact = load > 1 and (tonumber(rotator.contactMaterialID1) or -1) >= 0
  local surface, wetSpot = "paved", false
  if contact then surface, wetSpot = surfaceOf(rotator.contactMaterialID1) end
  local paved = surface == "paved"
  local wetness = paved and ctx.wetness or 0
  -- Wet-material spots already have lower ground friction; only add a little for tread/aquaplaning.
  if wetSpot then wetness = max(wetness, 0.3) end

  -- lastSlip is the total contact slip speed (m/s); lastSideSlip is its lateral part.
  local sideSlip = abs(tonumber(rotator.lastSideSlip) or 0)
  local slip = contact and max(abs(tonumber(rotator.lastSlip) or 0), sideSlip) or 0
  local longSlip = sqrt(max(0, slip * slip - sideSlip * sideSlip))
  local wheelSpeed = abs((tonumber(rotator.angularVelocity) or 0) * c.radius)
  local rollSpeed = contact and min(wheelSpeed, speed + 1) or 0

  if s.flat == false and (rotator.isTireDeflated or rotator.isBroken) then
    s.flat = true
    s.flatReason = "deflated"
  end

  -- Pressure (gas law on the carcass/air temperature) --------------------------------------------
  local pressureRatio = 1
  if ctx.pressure then
    if s.flat then
      s.pressure = 0
    else
      local absCold = s.coldPressure + ATM
      s.pressure = absCold * (s.core + KELVIN) / (s.fitTemp + KELVIN) - ATM
      -- Exposed cords leak.
      if s.tread <= 0.02 then s.coldPressure = max(0, s.coldPressure - 1500 * dt) end
    end
    -- Best hot pressure is ~12% above the designer's cold pressure.
    pressureRatio = clamp(s.pressure / (c.designPressure * 1.12), 0.05, 3)
  else
    s.pressure = s.coldPressure
  end

  -- Temperature ----------------------------------------------------------------------------------
  if ctx.temperature then
    local heatRate = ctx.heatRate
    local slipPower = contact and load * slip * 0.7 or 0                       -- W into the tyre
    local flex = clamp(1 / max(pressureRatio, 0.3), 0.5, 3) ^ 1.5
    local rollPower = contact and 0.012 * load * rollSpeed * flex * 0.6 or 0    -- W into the carcass
    -- Heat split across zones: over-inflation loads the middle, under-inflation the shoulders,
    -- negative camber the inner edge, cornering the outer edge.
    local sideShare = slip > 0.01 and sideSlip / (longSlip + sideSlip) or 0
    local p = clamp(pressureRatio - 1, -0.5, 0.5)
    local w1 = 0.34 - p * 0.25 + 0.04 - sideShare * 0.10
    local w2 = 0.32 + p * 0.50 - sideShare * 0.05
    local w3 = 0.34 - p * 0.25 - 0.04 + sideShare * 0.15
    local wsum = w1 + w2 + w3
    local weights = {w1 / wsum, w2 / wsum, w3 / wsum}

    local water = c.inWater and 10 or 1
    local airCool = (1.5 + 0.5 * (speed ^ 0.8)) * (1 + 2 * wetness) * water -- W/K per zone
    local conduct = 12                                                       -- W/K zone <-> carcass
    local ambient = ctx.ambient
    local zoneCap = c.zoneHeatCap
    for z = 1, 3 do
      local tz = s.zones[z]
      local q = slipPower * weights[z] * heatRate
              - airCool * (tz - ambient)
              - conduct * (tz - s.core)
      s.zones[z] = clamp(tz + q / zoneCap * dt, ambient - 5, 400)
    end
    local brakeTemp = tonumber(rotator.brakeSurfaceTemperature) or ambient
    local coreQ = rollPower * heatRate
                + 12 * ((s.zones[1] + s.zones[2] + s.zones[3]) - 3 * s.core)
                + 1.5 * (brakeTemp - s.core)
                - (2 + 0.3 * speed) * water * (s.core - ambient)
    s.core = clamp(s.core + coreQ / c.coreHeatCap * dt, ambient - 5, 400)
  else
    s.zones[1], s.zones[2], s.zones[3], s.core = ctx.ambient, ctx.ambient, ctx.ambient, ctx.ambient
  end
  local tSurf = surfaceTemp(s)

  -- Wear -------------------------------------------------------------------------------------------
  local distance = rollSpeed * dt
  s.distance = s.distance + distance
  if ctx.wear and contact and s.tread > 0 then
    local loadRatio = load / max(refLoad, 1)
    local hotStart = comp.opt + comp.plateau + comp.hot * 0.5
    local tempWear = 1
    if tSurf > hotStart then tempWear = min(4, 1 + ((tSurf - hotStart) / 40) ^ 2 * 2)
    elseif tSurf < comp.opt - comp.plateau - comp.cold then tempWear = 1.3 end  -- cold graining
    local pressureWear = 1 + 1.5 * (pressureRatio - 1) ^ 2
    local abrasion = load * max(0, slip - 0.5) * dt                             -- J of real sliding
    local loss = (5e-7 * loadRatio * distance + 4e-8 * abrasion * tempWear)
               * comp.wear * (SURFACE_WEAR[surface] or 1) * pressureWear * ctx.wearRate
    s.tread = max(0, s.tread - loss)
  end

  -- Extras: scrub-in, heat cycles, flat spots ------------------------------------------------------
  if ctx.extras then
    if comp.cycles then
      if tSurf >= comp.opt - 10 then s.wasHot = true
      elseif s.wasHot and tSurf <= ctx.ambient + 10 then
        s.wasHot = false
        s.heatCycles = s.heatCycles + 1
      end
    end
    -- Locked wheel at speed scrubs one spot of the tread.
    if contact and braking and speed > 8 and wheelSpeed < speed * 0.15 then
      s.flatSpot = min(1, s.flatSpot + dt * speed / 30 * 0.04)
    end
  end

  -- Punctures and blowouts -------------------------------------------------------------------------
  if ctx.punctures and not s.flat and contact then
    if ctx.wear and s.tread <= 0 and math.random() < dt * 0.12 * (1 + slip) then
      puncture(index, s, "worn through, puncture")
    elseif ctx.temperature and s.core > 160 and math.random() < dt * 0.03 * (s.core - 160) / 20 then
      puncture(index, s, "overheated, blowout")
    end
  end

  -- Grip -------------------------------------------------------------------------------------------
  local f = s.factors
  f.temperature = ctx.temperature and temperatureGrip(comp, tSurf) or 1
  if ctx.wear then
    if s.tread < 0.1 then f.wear = 0.72 + 2.8 * s.tread           -- down to the cords
    else f.wear = 1 + 0.03 * (1 - s.tread) end                    -- worn tread squirms less
  else
    f.wear = 1
  end
  f.pressure = ctx.pressure and clamp(1 - 0.5 * (pressureRatio - 1) ^ 2, 0.85, 1) or 1
  local surfaceGrip, wetGrip, aquaplane = 1, 1, 0
  if ctx.surface then
    surfaceGrip = SURFACE_GRIP[c.compoundId][SURFACE_INDEX[surface]] or 1
    if wetness > 0 then
      local treadDepth = c.compoundId == "slick" and 0 or s.tread
      -- Tread clears water: new tread keeps most grip, bald tyres lose much more.
      wetGrip = 1 - wetness * comp.wetLoss * (1 + 0.9 * (1 - treadDepth))
      -- Aquaplaning above a speed set by pressure and how well the tread drains.
      if wetness > 0.4 then
        local psi = max(s.pressure, 0) / PSI
        -- ~120 km/h for new road tread at 32 psi, ~80 km/h when bald.
        local vAqua = 4.0 * sqrt(max(psi, 5)) * (1 + 0.45 * comp.drain * treadDepth)
        aquaplane = smoothstep((speed - vAqua) / (vAqua * 0.3)) * clamp((wetness - 0.4) / 0.6, 0, 1)
        wetGrip = wetGrip * (1 - 0.7 * aquaplane)
      end
    end
  end
  f.surface, f.wet = surfaceGrip, wetGrip
  local extraGrip = 1
  if ctx.extras then
    if s.distance < 1500 then extraGrip = extraGrip * (0.97 + 0.03 * s.distance / 1500) end
    if comp.cycles then extraGrip = extraGrip * (1 - min(0.06, s.heatCycles * 0.004)) end
    extraGrip = extraGrip * (1 - 0.04 * s.flatSpot)
  end
  f.extras = extraGrip

  local raw = f.temperature * f.wear * f.pressure * f.surface * f.wet * f.extras
  local grip = clamp(1 + (raw - 1) * ctx.gripStrength, 0.25, 1.2)
  s.grip, s.surface, s.wetness, s.aquaplane, s.surfaceTemp = grip, surface, wetness, aquaplane, tSurf

  setGrip(index, c, grip)
  applyPressure(c, s, rotator)
  return c, s
end

-- Telemetry ------------------------------------------------------------------------------------------

local function round(x, d)
  local m = 10 ^ (d or 0)
  return floor(x * m + 0.5) / m
end

local function sendTelemetry()
  local list = {}
  for index, s in pairs(wheelState) do
    local c = wheelCache[index]
    if c then
      list[#list + 1] = {
        name = c.name,
        compound = c.compound.label,
        optTemp = c.compound.opt,
        zones = {round(s.zones[1], 1), round(s.zones[2], 1), round(s.zones[3], 1)},
        core = round(s.core, 1),
        tread = round(s.tread, 4),
        pressure = round(s.pressure / 1000, 1),          -- kPa gauge
        coldPressure = round(s.coldPressure / 1000, 1),
        designPressure = round(c.designPressure / 1000, 1),
        realPressure = c.hasRealPressure and c.pressureGroupId ~= nil,
        grip = round(s.grip, 3),
        factors = {
          temperature = round(s.factors.temperature or 1, 3), wear = round(s.factors.wear or 1, 3),
          pressure = round(s.factors.pressure or 1, 3), surface = round(s.factors.surface or 1, 3),
          wet = round(s.factors.wet or 1, 3), extras = round(s.factors.extras or 1, 3),
        },
        surface = s.surface or "paved",
        aquaplane = round(s.aquaplane or 0, 2),
        flatSpot = round(s.flatSpot, 2),
        heatCycles = s.heatCycles,
        distance = round(s.distance / 1000, 2),
        flat = s.flat,
        flatReason = s.flatReason,
      }
    end
  end
  gui.send(STREAM, {
    wheels = list,
    enabled = ctx.enabled,
    yieldedTo = yieldReason,
    ambient = round(ctx.ambient, 1),
    wetness = round(ctx.wetness, 2),
    speed = round(obj:getVelocity():length(), 1),
  })
end

-- Ownership ------------------------------------------------------------------------------------------

local function detectOtherTyreSystem()
  if extensions.isExtensionLoaded and extensions.isExtensionLoaded("overhaulTires") then
    return "RLS Career Overhaul"
  end
  if extensions.isExtensionLoaded and extensions.isExtensionLoaded("luukstyrethermalsandwear") then
    return "Tyre Wear and Thermals"
  end
  return nil
end

local function isActive()
  if not ctx.enabled or yieldReason then return false end
  if not ctx.aiVehicles and not (playerInfo and playerInfo.anyPlayerSeated) then return false end
  return true
end

-- Public API -----------------------------------------------------------------------------------------

function M.setContext(newCtx)
  if type(newCtx) ~= "table" then return end
  local wasActive = isActive()
  for k, val in pairs(newCtx) do ctx[k] = val end
  ctx.gripStrength = clamp(tonumber(ctx.gripStrength) or 1, 0, 1.5)
  ctx.heatRate = clamp(tonumber(ctx.heatRate) or 1, 0.1, 5)
  ctx.wearRate = clamp(tonumber(ctx.wearRate) or 1, 0, 50)
  ctx.ambient = tonumber(ctx.ambient) or 20
  ctx.wetness = clamp(tonumber(ctx.wetness) or 0, 0, 1)
  -- First context after spawn: start tyres at the real ambient temperature instead of 20 C.
  if not M._gotContext then
    M._gotContext = true
    for _, s in pairs(wheelState) do
      s.zones = {ctx.ambient, ctx.ambient, ctx.ambient}
      s.core, s.fitTemp = ctx.ambient, ctx.ambient
    end
  end
  if wasActive and not isActive() then restoreAll() end
  if not ctx.pressure or not ctx.applyPressure then
    for index, c in pairs(wheelCache) do
      local s = wheelState[index]
      if s and s.appliedPressure and c.pressureGroupId and not s.flat then
        pcall(obj.setGroupPressureRel, obj, c.pressureGroupId, c.designPressure)
        s.appliedPressure = nil
      end
    end
  end
end

-- New tyres on every wheel (tread, temperature, pressure, flat spots, cycles). Flat tyres stay flat
-- until the vehicle is repaired or reset, because re-inflating a broken tyre needs a physics reset.
function M.fitNewTyres()
  for index, c in pairs(wheelCache) do
    local s = wheelState[index]
    local wasFlat = s and s.flat
    local cold = s and s.coldPressure or c.designPressure
    wheelState[index] = freshState(c)
    wheelState[index].coldPressure = cold
    wheelState[index].flat = wasFlat or false
  end
end

-- Tyre blankets: bring every tread zone and carcass to the compound's best temperature.
function M.warmTyres()
  for index, c in pairs(wheelCache) do
    local s = wheelState[index]
    if s then
      local t = c.compound.opt
      s.zones = {t, t, t}
      s.core = t - 10
    end
  end
end

-- Changes the cold (set) pressure. axle: "front", "rear" or "all"; delta in kPa (gauge).
function M.adjustColdPressure(axle, deltaKPa)
  deltaKPa = tonumber(deltaKPa) or 0
  for index, c in pairs(wheelCache) do
    local front = string.upper(string.sub(c.name, 1, 1)) == "F"
    if axle == "all" or (axle == "front" and front) or (axle == "rear" and not front) then
      local s = stateFor(index, c)
      -- Re-base so the new set pressure applies at the current temperature.
      s.coldPressure = clamp(s.coldPressure + deltaKPa * 1000, 50000, 600000)
      s.fitTemp = s.core
    end
  end
end

function M.resetColdPressure()
  for index, c in pairs(wheelCache) do
    local s = stateFor(index, c)
    s.coldPressure = c.designPressure
    s.fitTemp = s.core
  end
end

function M.getState()
  return {wheels = wheelState, yieldedTo = yieldReason, ctx = ctx}
end

-- Lifecycle ------------------------------------------------------------------------------------------

function M.updateGFX(dt)
  dt = clamp(tonumber(dt) or 0, 0, 0.1)
  if dt <= 0 then return end

  yieldCheckTimer = yieldCheckTimer + dt
  if yieldCheckTimer >= 1 then
    yieldCheckTimer = 0
    local other = detectOtherTyreSystem()
    if other ~= yieldReason then
      yieldReason = other
      if other then restoreAll() end
    end
  end

  local wantTelemetry = streams and streams.willSend and streams.willSend(STREAM)

  if not isActive() or not wheels or not wheels.wheelRotators then
    if gripApplied then restoreAll() end
    if wantTelemetry then
      telemetryTimer = telemetryTimer + dt
      if telemetryTimer >= 0.25 then
        telemetryTimer = 0
        sendTelemetry()
      end
    end
    return
  end

  local speed = obj:getVelocity():length()
  local wheelCount = 0
  for _ in pairs(wheels.wheelRotators) do wheelCount = wheelCount + 1 end
  local refLoad = vehicleMass * GRAVITY / max(wheelCount, 1)
  local braking = (electrics and electrics.values and (tonumber(electrics.values.brake) or 0) > 0.2) or false

  -- Water contact is costly to test per node, so check it a few times a second.
  waterTimer = waterTimer + dt
  local checkWater = waterTimer >= 0.25
  if checkWater then waterTimer = 0 end

  for index, rotator in pairs(wheels.wheelRotators) do
    local c = cacheWheel(index, rotator)
    if checkWater then c.inWater = inWater(rotator) end
    simulateWheel(index, rotator, dt, speed, refLoad, braking)
  end
  gripApplied = true

  if wantTelemetry then
    telemetryTimer = telemetryTimer + dt
    if telemetryTimer >= 0.2 then
      telemetryTimer = 0
      sendTelemetry()
    end
  end
end

-- BeamNG's reset repairs the vehicle, so by default it also fits new tyres.
function M.onReset()
  materialNames = nil
  for index, c in pairs(wheelCache) do
    c.appliedGrip = nil
    local s = wheelState[index]
    if s then
      s.flat = false
      s.flatReason = nil
      s.appliedPressure = nil
      s.zones = {ctx.ambient, ctx.ambient, ctx.ambient}
      s.core = ctx.ambient
      s.fitTemp = ctx.ambient
      if ctx.resetWearOnReset then
        local cold = s.coldPressure
        wheelState[index] = freshState(c)
        wheelState[index].coldPressure = cold
      end
    end
  end
  gripApplied = false
end

function M.onExtensionLoaded()
  vehicleMass = computeMass()
  wheelCache, wheelState = {}, {}
  yieldReason = detectOtherTyreSystem()
  obj:queueGameEngineLua("if dynamicTyresManager then dynamicTyresManager.sendContextTo(" .. obj:getID() .. ") end")
end

function M.onExtensionUnloaded()
  restoreAll()
end

return M
