-- Cold Start - per-vehicle cold start simulation (runs in each vehicle's Lua VM).
--
-- What it adds on top of BeamNG's engine:
--   * time to fire: a cold engine has to be cranked for a while before it catches, and the colder it is the
--     longer that takes. Slow cranking, a flooded engine or cold diesel glow plugs make it worse;
--   * false starts: a very cold engine can catch, stumble and die again;
--   * battery: state of charge, cold cranking power and voltage. Every attempt drains it, a cold or
--     half-empty battery turns the engine slower, and the alternator charges it back while you drive;
--   * starter: labours (slower, lower pitched) when cold or short of volts, and cuts out when overheated;
--   * diesel glow plugs, gasoline flooding (hold full throttle while cranking to clear it), a block heater,
--     fast idle and a rough idle after a cold start, and wear from revving an engine on cold oil.
--
-- How it hooks in: BeamNG's starter kills the throttle until its "starterThrottleKillTimer" runs out, then
-- the engine fires. While the starter is engaged this extension holds that timer and decides when to let
-- go, so the game's own starter, sounds, ignition levels and stall handling keep working unchanged.
-- Cranking speed is changed through the starter's torque and no-load speed only; engine friction is left
-- alone. Temperatures are the game's own engine thermals, which follow the environment temperature.
--
-- Settings come from the GE manager (coldStartManager) via setContext.

local M = {}

local STREAM = "coldStart"
local KELVIN = 273.15
local NOMINAL_LOAD = 0.2        -- share of starter stall torque a warm engine needs to turn over

local max, min, abs, exp, floor, random = math.max, math.min, math.abs, math.exp, math.floor, math.random

local function clamp(x, lo, hi) return max(lo, min(hi, x)) end
local function round(x, d) local m = 10 ^ (d or 0); return floor(x * m + 0.5) / m end

-- Context (from GE) ----------------------------------------------------------------------------------

local ctx = {
  enabled = true,
  difficulty = 1,           -- 0.45 arcade, 1 realistic, 1.7 brutal
  preset = "realistic",
  wear = true,              -- revving on cold oil wears the engine
  batteryDrain = 1,
  chargeRate = 4,
  soakOnReset = true,       -- engine starts at outside temperature after spawn / reset
  engineOffOnReset = false, -- player vehicle spawns with the ignition off
  rechargeOnReset = true,
  aiVehicles = false,
  soakSerial = 0,           -- bumped by GE when the outside temperature is changed
}

-- State ----------------------------------------------------------------------------------------------

local engine        -- combustion engine device, or false when the vehicle has none
local thermals      -- engine.thermals
local orig          -- starter values to restore: {starterTorque, invStarterMaxAV}
local spec          -- {diesel, capAh, volts, iNom, r0, alt}
local st            -- simulation state, see newState
local vehInfo = {}   -- from GE: {year = model year or nil}
local wasPlayer = false
local gotContext = false
local telemetryTimer = 0
local messageTimers = {}

local function newState()
  return {
    phase = "off",          -- off | cranking | catching | running
    soc = 1,                -- battery state of charge 0..1
    flood = 0,              -- 0..1 unburnt fuel wetting the plugs (gasoline)
    glow = 0,               -- 0..1 glow plug heat (diesel)
    glowTimer = 0,
    starterHeat = 0,        -- 0..1, cuts out at 1
    battWarm = 0,           -- deg C the battery sits above outside temperature
    wearScale = 1,          -- friction added by cold wear
    wearPending = 0,
    crankTime = 0,
    crankSpeed = 0,         -- cranking speed vs a warm engine on a full battery
    attempts = 0,
    falseStarts = 0,
    stumble = 0, stumbleFor = 1, stumbleStrength = 0,
    flick = 0, flickVal = 1,
    heater = false,
    volts = 12.7,
    runTime = 0,
  }
end
st = newState()

local function message(key, text, ttl, every)
  if (messageTimers[key] or 0) > 0 then return end
  messageTimers[key] = every or 3
  if guihooks and guihooks.message then guihooks.message(text, ttl or 4, "coldStart." .. key) end
end

-- Engine lookup --------------------------------------------------------------------------------------

local function computeMass()
  local mass = 0
  for _, node in pairs(v and v.data and v.data.nodes or {}) do
    mass = mass + (tonumber(node.nodeWeight) or 0)
  end
  return max(mass, 300)
end

-- Engine profile ------------------------------------------------------------------------------------
-- Every engine gets its own starting character from what the vehicle is built from:
--   * fuel system, from the fitted parts (carburetor, throttle-body or port injection) or else the
--     model year; diesels are old mechanical-pump or modern common-rail by year;
--   * cylinder count, from the engine's sound setup;
--   * displacement, estimated from peak torque (the game does not store it);
--   * battery and starter current, sized for that displacement and the vehicle's weight.

local CARB_WORDS = {"carb", "bbl", "sixpack", "6pack", "sidedraft", "downdraft"}
local TBI_WORDS = {"tbi"}
local EFI_WORDS = {"efi", "injection", "_itb", "mpfi", "_di_"}

local function partNames()
  local names = {}
  local function add(x) if type(x) == "string" then names[#names + 1] = string.lower(x) end end
  for _, part in pairs(beamstate and type(beamstate.activeParts) == "table" and beamstate.activeParts or {}) do add(part) end
  for path, part in pairs(v and v.data and type(v.data.activeParts) == "table" and v.data.activeParts or {}) do add(path); add(part) end
  return names
end

local function anyPartHas(names, words)
  for _, name in ipairs(names) do
    for _, word in ipairs(words) do
      if string.find(name, word, 1, true) then return true end
    end
  end
  return false
end

local function detectFuelSystem(diesel, year)
  if diesel then
    return (year and year < 1998) and "mechanical" or "commonrail"
  end
  local names = partNames()
  if anyPartHas(names, TBI_WORDS) then return "tbi" end
  if anyPartHas(names, EFI_WORDS) then return "efi" end
  if anyPartHas(names, CARB_WORDS) then return "carb" end
  if year then
    if year < 1984 then return "carb" end
    if year < 1991 then return "tbi" end
  end
  return "efi"
end

local function cylinderCount()
  local cfg = engine.soundConfiguration
  local params = type(cfg) == "table" and cfg.engine and cfg.engine.params
  local coef = params and tonumber(params.fundamentalFrequencyRPMCoef)
  local n = coef and floor(coef * 120 + 0.5) or nil
  return (n and n >= 1 and n <= 16) and n or nil
end

local function hasBoost()
  local t, sc = engine.turbocharger, engine.supercharger
  return (type(t) == "table" and t.isExisting == true) or (type(sc) == "table" and sc.isExisting == true)
end

local function estimateLitres(diesel)
  local torque = type(engine.torqueData) == "table" and tonumber(engine.torqueData.maxTorque) or tonumber(engine.maxTorque)
  if not torque or torque <= 0 then return nil end
  local perLitre = diesel and (hasBoost() and 170 or 70) or (hasBoost() and 150 or 92)
  return clamp(torque / perLitre, 0.5, 18)
end

local FUEL_LABELS = {carb = "carburetor", tbi = "throttle-body injection", efi = "fuel injection", mechanical = "mechanical diesel", commonrail = "common-rail diesel"}

local function buildSpec()
  if not engine then return end
  local diesel = string.lower(tostring(engine.requiredEnergyType or "")) == "diesel"
  local mass = computeMass()
  local year = tonumber(vehInfo.year)
  local cylinders = cylinderCount()
  local litres = estimateLitres(diesel)
  local l = litres or clamp(mass / 700, 1, 6)
  local fuel = detectFuelSystem(diesel, year)

  local capAh = clamp(35 + 9 * l + mass * 0.006, 40, 120) * (diesel and 1.3 or 1)
  local volts = 12
  if diesel and mass > 7000 then capAh, volts = 180, 24 end

  spec = {
    diesel = diesel, year = year, cylinders = cylinders, litres = litres, fuel = fuel, fuelLabel = FUEL_LABELS[fuel],
    capAh = capAh,
    volts = volts,
    -- Cranking current warm, A (12 V equivalent); never more than the battery is built to give.
    iNom = min(clamp((90 + 36 * l) * (diesel and 1.5 or 1), 110, 900), capAh * 3.2),
    r0 = 0.0045 * 60 / capAh,        -- internal resistance warm and full, ohm
    alt = 70 + capAh * 0.5,          -- alternator output, A
    tauMul = 1,                      -- cranking time to fire
    floodMul = 1,                    -- how fast it floods
    sustainMul = 1,                  -- how likely a catch dies again
    stumbleMul = 1,                  -- how long it runs rough
    glowMul = 1,                     -- glow plug time
    pumpHelps = false,               -- a little throttle while cranking helps (accelerator pump)
  }
  if fuel == "carb" then
    -- Choke and a cold manifold: slow to fire, quick to flood, sulks for a long time.
    spec.tauMul, spec.floodMul, spec.sustainMul, spec.stumbleMul, spec.pumpHelps = 1.9, 2.2, 1.35, 1.7, true
  elseif fuel == "tbi" then
    spec.tauMul, spec.floodMul, spec.sustainMul, spec.stumbleMul = 1.3, 1.3, 1.15, 1.25
  elseif fuel == "efi" then
    if year and year >= 2005 then spec.tauMul, spec.floodMul, spec.stumbleMul = 0.85, 0.7, 0.8 end
  elseif fuel == "mechanical" then
    -- Indirect injection with slow glow plugs.
    spec.tauMul, spec.sustainMul, spec.stumbleMul, spec.glowMul = 1.6, 1.2, 1.5, 1.5
  end
  -- More cylinders: more chances per turn that one fires, and a smoother catch.
  if cylinders then
    spec.tauMul = spec.tauMul * clamp((4 / cylinders) ^ 0.3, 0.8, 1.25)
    spec.stumbleMul = spec.stumbleMul * clamp((4 / cylinders) ^ 0.3, 0.8, 1.3)
  end
  -- Big diesels have a lot of cold iron to heat.
  if diesel and l > 6 then spec.glowMul = spec.glowMul * 1.3 end
end

local function findEngine()
  engine, thermals, orig, spec = false, nil, nil, nil
  local list = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("engine") or {}
  for _, d in pairs(list) do
    if type(d) == "table" and d.starterEngagedCoef ~= nil and d.starterThrottleKillTimer ~= nil
      and tonumber(d.starterMaxAV) and tonumber(d.invStarterMaxAV) and tonumber(d.starterTorque) then
      engine = d
      break
    end
  end
  if not engine then return end
  thermals = type(engine.thermals) == "table" and engine.thermals or nil
  orig = {starterTorque = engine.starterTorque, invStarterMaxAV = engine.invStarterMaxAV}

  buildSpec()
end

-- Temperatures ---------------------------------------------------------------------------------------

local THERMAL_FIELDS = {"engineBlockTemperature", "cylinderWallTemperature", "oilTemperature", "coolantTemperature", "exhaustTemperature"}

local function envTemp()
  local k = obj and obj.getEnvTemperature and tonumber(obj:getEnvTemperature())
  return (k and k > 100) and (k - KELVIN) or 15
end

-- Engine (block) and oil temperature in deg C. Vehicles without engine thermals get a simple estimate.
local function engineTemps(env)
  if st.noThermals or not thermals then
    st.vTemp = st.vTemp or env
    return st.vTemp, st.vTemp
  end
  local block = tonumber(thermals.engineBlockTemperature) or env
  local oil = tonumber(thermals.oilTemperature) or block
  return block, oil
end

local function coldSoak()
  local env = envTemp()
  if thermals then
    for _, key in ipairs(THERMAL_FIELDS) do
      if type(thermals[key]) == "number" then thermals[key] = env end
    end
  end
  st.vTemp = env
  st.battWarm = 0
  st.glow = 0
end

local function updateHeater(dt, env, speed)
  if not st.heater then return end
  if speed > 2 then
    st.heater = false
    message("heater", "Block heater unplugged", 4, 1)
    return
  end
  -- A real block heater needs a couple of hours; this one is sped up to a couple of minutes.
  local target, oilTarget = min(env + 55, 65), min(env + 30, 45)
  local k = min(dt / 45, 1)
  if thermals then
    for _, key in ipairs({"engineBlockTemperature", "cylinderWallTemperature", "coolantTemperature"}) do
      local cur = thermals[key]
      if type(cur) == "number" and cur < target then thermals[key] = cur + (target - cur) * k end
    end
    local oil = thermals.oilTemperature
    if type(oil) == "number" and oil < oilTarget then thermals.oilTemperature = oil + (oilTarget - oil) * k end
  end
  if st.vTemp and st.vTemp < target then st.vTemp = st.vTemp + (target - st.vTemp) * k end
end

-- Battery and starter --------------------------------------------------------------------------------

-- 0 at 25 C and warmer, 1 at -35 C and colder.
local function coldness(t) return clamp((25 - t) / 60, 0, 1) end

local function batteryTemp(env) return env + st.battWarm end

-- Share of the rated capacity a cold battery can deliver.
local function capacityFactor(tb) return clamp(1 - max(0, 25 - tb) * 0.011, 0.35, 1) end

local function drain(amps, dt, tb, rateFactor)
  if amps <= 0 then return end
  local usable = spec.capAh * capacityFactor(tb) * rateFactor
  st.soc = max(0, st.soc - amps * dt / 3600 / usable * ctx.batteryDrain)
end

-- Open-circuit voltage and internal resistance (12 V equivalent).
local function batteryState(tb)
  local ocv = 11.75 + 0.95 * st.soc
  local r = spec.r0 * (1 + max(0, 25 - tb) * 0.028) * (1 + 1.6 * (1 - st.soc) ^ 2)
  return ocv, r
end

-- What the starter gets out of the battery: voltage under load, scale of its no-load speed and of its
-- torque, the current drawn, and whether it can turn the engine at all.
local function crankElectrics(engineT, tb)
  local ocv, r = batteryState(tb)
  local c = coldness(engineT) ^ 1.3
  local need = spec.iNom * (1 + 0.9 * c)          -- thick oil needs more current
  local amps = need
  local volts = ocv - amps * r
  if volts < 7.2 then
    amps = max(0, (ocv - 7.2) / r)
    volts = 7.2
  end
  local power = amps / need
  local speedScale = clamp((volts - 5.5) / 5.7, 0, 1) * power / (1 + 0.75 * c)
  local torqueScale = clamp(volts / 11.5, 0, 1) * power * (1 - 0.2 * c)
  local ok = st.soc > 0.02 and speedScale > 0.2
  return volts, speedScale, torqueScale, amps, ok
end

-- Cranking speed (vs warm engine, full battery) the starter would reach with these scales.
local function predictedCrankSpeed(speedScale, torqueScale)
  return speedScale * max(0, 1 - NOMINAL_LOAD / max(torqueScale, 0.05)) / (1 - NOMINAL_LOAD)
end

-- Start model ----------------------------------------------------------------------------------------
-- Returns: tau (mean cranking time to fire once primed, s), rate (0..1 multiplier on 1/tau from cranking
-- speed and flooding), chance that a catch keeps running, and how cold the combustion chamber is (0..1).
local function startModel(engineT, crankSpeed)
  local tau, speedF, chamberT
  if spec.diesel then
    -- Compression ignition needs heat: glow plugs are worth about 32 C.
    local td = engineT + 32 * st.glow
    tau = td < 18 and 0.3 * (exp((18 - td) / 9) - 1) or 0
    speedF = clamp((crankSpeed - 0.25) / 0.4, 0, 1) ^ 1.2
    chamberT = engineT + 12 * st.glow
  else
    tau = engineT < 15 and 0.2 * (exp((15 - engineT) / 16) - 1) or 0
    speedF = clamp((crankSpeed - 0.15) / 0.45, 0, 1) ^ 1.2
    chamberT = engineT
  end
  local coldG = clamp((5 - chamberT) / 45, 0, 1)
  local floodF = 1 - 0.85 * st.flood ^ 2
  local sustain = clamp(1 - 0.42 * coldG ^ 1.5 * ctx.difficulty * spec.sustainMul, 0.25, 1)
  return tau * ctx.difficulty * spec.tauMul, speedF * floodF, sustain, coldG
end

local function primeTime(engineT)
  return (tonumber(engine.starterThrottleKillTime) or 0.5) * (1 + 1.5 * coldness(engineT))
end

-- 0 easy .. 4 almost impossible, from the expected cranking time in the current state.
local RATINGS = {"easy", "normal", "hard", "very hard", "almost impossible"}
local function startRating(engineT, tb)
  local _, speedScale, torqueScale, _, ok = crankElectrics(engineT, tb)
  if not ok or st.starterCooling then return 4, math.huge end
  local tau, rate, sustain = startModel(engineT, predictedCrankSpeed(speedScale, torqueScale))
  local expected = math.huge
  if tau <= 0.01 then
    if rate > 0 then expected = primeTime(engineT) / sustain end
  elseif rate > 0.001 then
    expected = (primeTime(engineT) + tau / rate) / sustain
  end
  local level = expected < 1.2 and 0 or expected < 2.4 and 1 or expected < 5.5 and 2 or expected < 30 and 3 or 4
  return level, expected
end

-- Engine hooks ---------------------------------------------------------------------------------------

local pitchApplied = 1
local pitchBroken = false
local function writeStarterPitch(pitch)
  local snd = engine.engineMiscSounds
  local cfg = engine.soundConfiguration
  local eng = cfg and cfg.engine and cfg.engine.params
  if snd.starterSoundEngine then
    if eng and eng.main_gain then
      obj:setVolumePitchCT(snd.starterSoundEngine, snd.starterVolume or 1, pitch, eng.main_gain, 0)
    else
      obj:setVolumePitch(snd.starterSoundEngine, snd.starterVolume or 1, pitch)
    end
  end
  local exh = cfg and cfg.exhaust and cfg.exhaust.params
  if snd.starterSoundExhaust then
    if exh and exh.main_gain then
      obj:setVolumePitchCT(snd.starterSoundExhaust, snd.starterVolumeExhaust or 1, pitch, exh.main_gain, 0)
    else
      obj:setVolumePitch(snd.starterSoundExhaust, snd.starterVolumeExhaust or 1, pitch)
    end
  end
end

-- A labouring starter sounds lower.
local function setStarterPitch(pitch)
  if pitchBroken or not engine or type(engine.engineMiscSounds) ~= "table" then return end
  if abs(pitch - pitchApplied) < 0.01 then return end
  if pcall(writeStarterPitch, pitch) then pitchApplied = pitch else pitchBroken = true end
end

local function restoreStarter()
  if engine and orig then
    engine.starterTorque = orig.starterTorque
    engine.invStarterMaxAV = orig.invStarterMaxAV
  end
  if engine then setStarterPitch(1) end
end

local function setFastIdle(av)
  if not engine or engine.idleAVOverwrite == nil then return end
  -- Leave it alone when something else (e.g. a PTO high idle) is using it.
  if engine.idleAVOverwrite ~= 0 and engine.idleAVOverwrite ~= st.idleSet then return end
  engine.idleAVOverwrite = av
  st.idleSet = av > 0 and av or nil
end

local function unblockStarter()
  if st.blockedStarter then
    st.blockedStarter = nil
    if engine and not engine.isDisabled then engine.starterDisabled = false end
  end
end

-- Hands the engine back to the game exactly as it would be without this extension.
local function release()
  if not engine then return end
  restoreStarter()
  setFastIdle(0)
  unblockStarter()
  if st.phase == "cranking" or st.phase == "catching" then
    -- Let the game's own timer finish the start.
    if engine.starterEngagedCoef > 0 then engine.starterThrottleKillTimer = 0 else engine.starterThrottleKillCoef = 1 end
  elseif st.phase == "running" then
    engine.starterThrottleKillCoef = 1
  end
  st.phase = "off"
  st.stumble = 0
end

-- A start that did not happen: keep the throttle killed while the engine spins down. (The game re-opens
-- it if the starter is released a second time, which would let a still-turning engine fire by itself.)
local function failStart()
  restoreStarter()
  engine.starterThrottleKillCoef = 0
  st.phase = "off"
  st.spinDown = 3
end

local function blockStarter(key, text)
  if engine.deactivateStarter then engine:deactivateStarter() end
  -- Also stops arcade-gearbox auto start from hammering a starter that cannot turn.
  if not engine.isDisabled and not engine.starterDisabled then
    engine.starterDisabled = true
    st.blockedStarter = true
  end
  failStart()
  message(key, text, 4, 2.5)
end

-- Simulation -----------------------------------------------------------------------------------------

local function isActive()
  if not ctx.enabled or not engine then return false end
  if not (ctx.aiVehicles or wasPlayer) then return false end
  -- AI drivers cannot nurse a cold engine, so they always get a normal start.
  if ai and ai.mode and ai.mode ~= "disabled" then return false end
  return true
end

local function throttleInput()
  local e = electrics and electrics.values or {}
  return tonumber(e.throttle_input) or tonumber(e.throttle) or 0
end

local function updateGlow(dt, engineT, tb, ignitionOn, cranking)
  if not spec.diesel then return end
  local needed = clamp(2 + (5 - engineT) * 0.3, 2, 14) * spec.glowMul
  st.glowNeeded = needed
  if not ignitionOn then
    st.glowTimer = 0
    st.glow = max(0, st.glow - dt / 25)
    st.glowActive = false
    return
  end
  if st.phase == "running" then
    st.glowActive = false
    st.glow = max(0, st.glow - dt / 25)
    return
  end
  if not cranking then st.glowTimer = st.glowTimer + dt end
  -- The relay drops out some time after the lamp goes off: cycle the key to glow again.
  st.glowActive = cranking or st.glowTimer < needed + 12
  if st.glowActive then
    -- The air rushing through a cranking engine cools the plugs, so they heat far slower then.
    st.glow = min(1, st.glow + dt / needed * (cranking and 0.4 or 1))
    drain(70, dt, tb, 0.8)
  else
    st.glow = max(0, st.glow - dt / 25)
  end
end

local function beginCrank()
  st.phase = "cranking"
  st.crankTime = 0
  st.crankSpeed = 0
  st.attempts = st.attempts + 1
end

local function fire(engineT, sustain, coldG)
  st.phase = "catching"
  st.catchT = 0
  st.catchCold = coldG
  st.catchDur = coldG > 0 and (0.3 + 1.5 * coldG) * (0.8 + 0.4 * random()) or 0
  st.sustain = random() < sustain
  st.dieAt = st.catchDur * (0.35 + 0.5 * random())
  st.flick, st.flickVal = 0, 1
  -- How long and how badly it runs rough afterwards.
  st.stumbleFor = (4 + 22 * coldG) * spec.stumbleMul
  st.stumbleStrength = coldG > 0 and (0.35 + 0.65 * coldG) or 0
end

local function updateCranking(dt, engineT, tb, av, engaged)
  if not engaged then
    -- Key released before it fired: the engine just spins down.
    return failStart()
  end
  local volts, speedScale, torqueScale, amps, ok = crankElectrics(engineT, tb)
  if st.starterHeat >= 1 then
    st.starterCooling = true
    return blockStarter("starter", "Starter overheated - let it cool down")
  elseif st.starterCooling then
    return blockStarter("starter", "Starter is still too hot")
  elseif not ok then
    return blockStarter("battery", "Battery too weak to crank the engine")
  end

  st.volts = volts
  st.kW, st.kT = max(speedScale, 0.05), max(torqueScale, 0.05)
  engine.starterTorque = orig.starterTorque * st.kT
  engine.invStarterMaxAV = orig.invStarterMaxAV / st.kW
  -- Hold the game's start timer: no combustion until this extension lets go.
  engine.starterThrottleKillTimer = 1
  engine.starterThrottleKillCoef = 0

  drain(amps, dt, tb, 0.4)
  st.starterHeat = min(1, st.starterHeat + dt / 24)
  st.crankTime = st.crankTime + dt
  local speed = clamp(av / (engine.starterMaxAV * (1 - NOMINAL_LOAD)), 0, 1.3)
  st.crankSpeed = st.crankSpeed + (speed - st.crankSpeed) * min(dt * 6, 1)
  setStarterPitch(clamp(0.6 + 0.4 * st.crankSpeed, 0.6, 1.05))

  local pedal = throttleInput()
  local wideOpen = pedal > 0.9
  -- Carburetor: a little throttle works the accelerator pump, which helps a cold engine fire but
  -- floods it faster.
  local pumping = spec.pumpHelps and pedal > 0.12 and pedal < 0.7 and engineT < 15
  st.pumping = pumping
  if not spec.diesel then
    if wideOpen then
      -- Clear-flood: full throttle while cranking cuts the fuel and dries the plugs.
      st.flood = max(0, st.flood - dt * 0.35)
    elseif engineT < 10 then
      st.flood = min(1, st.flood + dt * 0.03 * coldness(engineT) * ctx.difficulty * spec.floodMul * (pumping and 1.8 or 1))
    end
  end

  if st.crankTime < primeTime(engineT) then return end
  local tau, rate, sustain, coldG = startModel(engineT, st.crankSpeed)
  if pumping then rate = rate * 1.7 end
  if rate <= 0 then return end
  if tau <= 0.01 or random() < 1 - exp(-dt * rate / tau) then
    fire(engineT, sustain, coldG)
  end
end

local function updateCatching(dt, av, engaged)
  local startAV = engine.starterMaxAV
  st.catchT = st.catchT + dt
  local x = st.catchDur > 0 and min(st.catchT / st.catchDur, 1) or 1

  if not st.sustain and st.catchT >= st.dieAt then
    -- False start: it fired on a few cylinders and died again.
    st.falseStarts = st.falseStarts + 1
    if not spec.diesel then st.flood = min(1, st.flood + 0.07) end
    engine.starterThrottleKillCoef = 0
    message("died", "It caught, then died again", 3, 1.5)
    if engaged then
      engine.starterThrottleKillTimer = 1
      st.phase = "cranking"
    else
      failStart()
    end
    return
  end

  if engaged then
    -- The starter picks up speed again as the engine starts helping.
    engine.starterTorque = orig.starterTorque * (st.kT + (1 - st.kT) * x)
    engine.invStarterMaxAV = orig.invStarterMaxAV / (st.kW + (1 - st.kW) * x)
    setStarterPitch(clamp(0.6 + 0.4 * (st.crankSpeed + (1 - st.crankSpeed) * x), 0.6, 1.05))
    st.starterHeat = min(1, st.starterHeat + dt / 24)
  elseif av < startAV * 0.25 then
    -- Key released too early and it could not pull itself up.
    return failStart()
  end

  if x >= 1 then
    engine.starterThrottleKillCoef = 1
    if engaged then
      engine.starterThrottleKillTimer = 0     -- the game disengages the starter once it is up to speed
    elseif av > startAV * 0.8 then
      restoreStarter()
      st.phase = "running"
      st.runTime = 0
      st.stumble = st.stumbleStrength > 0 and st.stumbleFor or 0
      st.flick, st.flickVal = 0.3, 1
    end
    return
  end

  -- Sputter: misfires thin out as it picks up.
  st.flick = st.flick - dt
  if st.flick <= 0 then
    st.flick = 0.05 + 0.08 * random()
    st.flickVal = random() < (0.1 + 0.5 * (1 - x) * st.catchCold) and 0 or 1
  end
  engine.starterThrottleKillCoef = st.flickVal * (0.45 + 0.55 * x)
  if engaged then engine.starterThrottleKillTimer = 1 end
end

local function updateRunning(dt, env, engineT, oilT, tb, av, ignitionOn, engaged)
  if not ignitionOn or av < engine.starterMaxAV * 0.5 then
    -- Switched off or stalled.
    engine.starterThrottleKillCoef = 1
    setFastIdle(0)
    st.phase = "off"
    st.stumble = 0
    return
  end
  if engaged then return end
  st.runTime = st.runTime + dt

  -- Rough running for a while after a cold start.
  if st.stumble > 0 then
    st.stumble = st.stumble - dt
    local strength = st.stumbleStrength * clamp(st.stumble / st.stumbleFor, 0, 1)
    st.flick = st.flick - dt
    if st.flick <= 0 then
      if st.flickVal < 1 then
        st.flickVal = 1
        st.flick = 0.15 + random() * (1.3 - strength)
      else
        st.flickVal = max(0, 1 - (0.6 + 0.6 * random()) * strength)
        st.flick = 0.08 + 0.2 * random() * strength
      end
    end
    engine.starterThrottleKillCoef = st.stumble > 0 and st.flickVal or 1
  end

  -- Fast idle until there is some heat in it.
  local idleBoost = (spec.diesel and 0.25 or 0.45) * clamp((40 - engineT) / 50, 0, 1)
  setFastIdle(idleBoost > 0.02 and (tonumber(engine.idleAV) or 0) * (1 + idleBoost) or 0)

  -- Alternator.
  local idleAV = max(tonumber(engine.idleAV) or 80, 1)
  local available = spec.alt * clamp(av / (idleAV * 2.2), 0.4, 1) - 12
  local accept = spec.capAh * (0.15 + 2 * (1 - st.soc)) * clamp(1 + min(tb, 0) * 0.012, 0.5, 1)
  local amps = max(0, min(available, accept))
  st.soc = min(1, st.soc + amps * dt / 3600 / spec.capAh * ctx.chargeRate)
  st.volts = 14.3 - 0.7 * (1 - st.soc)
  st.flood = max(0, st.flood - dt * 0.3)
  st.battWarm = min(18, st.battWarm + dt / 40)

  -- Revving hard on cold, thick oil wears the engine.
  st.abuse = 0
  if oilT < 10 then
    local rpmShare = av / max(tonumber(engine.maxAV) or (idleAV * 8), 1)
    local load = clamp(tonumber(engine.engineLoad) or 0, 0, 1)
    local abuse = clamp((rpmShare - 0.5) / 0.4, 0, 1) * (0.4 + 0.6 * load) * clamp((10 - oilT) / 40, 0, 1)
    st.abuse = abuse
    if abuse > 0.05 and ctx.wear then
      message("wear", "Engine oil is still cold - keep the revs down", 4, 12)
      st.wearPending = st.wearPending + abuse * dt * 0.004 * ctx.difficulty
      if st.wearPending >= 0.01 and st.wearScale < 1.3 and engine.scaleFriction then
        st.wearPending = st.wearPending - 0.01
        st.wearScale = st.wearScale * 1.01
        engine:scaleFriction(1.01)
      end
    end
  end

  -- Vehicles without engine thermals (the exhaust never gets warm): fall back to a simple estimate.
  if not st.noThermals and thermals and st.runTime > 30 and st.runTime < 31
    and abs((tonumber(thermals.exhaustTemperature) or env) - env) < 2 then
    st.noThermals = true
    st.vTemp = st.vTemp or engineT
  end
end

local function simulate(dt)
  local env = envTemp()
  local engineT, oilT = engineTemps(env)
  local tb = batteryTemp(env)
  local av = tonumber(engine.outputAV1) or 0
  local ignitionOn = (tonumber(engine.ignitionCoef) or 0) > 0
  local engaged = (tonumber(engine.starterEngagedCoef) or 0) > 0
  local speed = obj:getVelocity():length()

  updateHeater(dt, env, speed)

  -- The estimate used when the vehicle has no engine thermals.
  if st.vTemp then
    if st.phase == "running" then st.vTemp = st.vTemp + (90 - st.vTemp) * min(dt / 150, 1)
    else st.vTemp = st.vTemp + (env - st.vTemp) * min(dt / 1500, 1) end
  end

  -- Starter cools down; a cut-out starter is released again at 60 %.
  if st.phase ~= "cranking" and st.phase ~= "catching" then
    st.starterHeat = max(0, st.starterHeat - dt / 120)
  end
  if st.starterCooling and st.starterHeat < 0.6 then st.starterCooling = nil end
  if st.blockedStarter and not st.starterCooling then
    local _, _, _, _, ok = crankElectrics(engineT, tb)
    if ok then unblockStarter() end
  end

  if st.spinDown then
    st.spinDown = st.spinDown - dt
    if engaged or st.spinDown <= 0 or av < engine.starterMaxAV * 0.05 then
      st.spinDown = nil
    elseif st.phase == "off" then
      engine.starterThrottleKillCoef = 0
    end
  end

  if st.phase == "off" then
    if engaged then
      beginCrank()
    elseif ignitionOn and av > engine.starterMaxAV * 0.8 and (tonumber(engine.starterThrottleKillCoef) or 1) > 0 then
      -- Already running: spawned that way, bump started, or the simulation was just switched on.
      st.phase = "running"
      st.runTime = 0
      st.stumble = 0
    end
  end

  updateGlow(dt, engineT, tb, ignitionOn, engaged)

  if st.phase == "cranking" then
    updateCranking(dt, engineT, tb, av, engaged)
  elseif st.phase == "catching" then
    updateCatching(dt, av, engaged)
  elseif st.phase == "running" then
    if engaged and av < engine.starterMaxAV * 0.8 then
      engine.starterThrottleKillCoef = 0
      setFastIdle(0)
      beginCrank()
    else
      updateRunning(dt, env, engineT, oilT, tb, av, ignitionOn, engaged)
    end
  end

  if st.phase ~= "running" then
    -- Parked: flooding evaporates slowly, the battery cools off and carries the ignition-on loads.
    if st.phase == "off" then st.flood = max(0, st.flood - dt / 150) end
    st.battWarm = max(0, st.battWarm - dt / 120)
    if st.phase == "off" then
      local ocv = batteryState(tb)
      local load = 0
      if ignitionOn then
        local lights = electrics and electrics.values and tonumber(electrics.values.lights_state) or 0
        load = 6 + (lights >= 1 and 9 or 0) + (lights >= 2 and 6 or 0)
        drain(load, dt, tb, 1)
      end
      st.volts = ocv - load * 0.01 - (st.glowActive and 0.9 or 0)
    end
  end

  return env, engineT, oilT, tb
end

-- Telemetry ------------------------------------------------------------------------------------------

local function hintFor(engineT, level)
  if st.heater then return "Block heater plugged in", "info" end
  if st.starterCooling then return "Starter overheated - let it cool", "bad" end
  if st.phase == "cranking" then
    if st.flood > 0.45 then return "Flooded - hold full throttle while cranking", "warn" end
    if st.crankSpeed < 0.45 and st.crankTime > 0.6 then return "Cranking slowly", "warn" end
    if spec.pumpHelps and engineT < 10 and not st.pumping and st.crankTime > 2 then return "Carburetor: try a little throttle", "info" end
    return "Cranking...", "info"
  elseif st.phase == "catching" then
    return "It's catching...", "info"
  elseif st.phase == "running" then
    if (st.abuse or 0) > 0.05 then return ctx.wear and "Cold oil - revving now wears the engine" or "Cold oil - keep the revs down", "warn" end
    if st.stumble > 0 then return "Running rough until it warms up", "info" end
    if engineT < 40 then return "Warming up", "info" end
    return "", "info"
  end
  if st.blockedStarter or st.soc <= 0.02 then return "Battery too weak to crank", "bad" end
  if st.flood > 0.45 then return "Flooded - crank with full throttle to clear", "warn" end
  if spec.diesel and (tonumber(engine.ignitionCoef) or 0) > 0 then
    if st.glowActive and st.glow < 0.98 then return "Glow plugs heating - wait", "warn" end
    if st.glow >= 0.98 and st.glowActive then return "Glow plugs ready - start now", "good" end
    if not st.glowActive and st.glow < 0.6 and engineT < 10 then return "Glow plugs timed out - cycle the key", "warn" end
  elseif spec.diesel and engineT < 10 then
    return "Diesel: switch the ignition on and wait for the glow plugs", "info"
  end
  if level >= 4 then return "Too cold for this battery - try the block heater", "bad" end
  if level >= 3 then return "Every attempt drains the battery", "warn" end
  return "", "info"
end

local function sendTelemetry(active, env, engineT, oilT, tb)
  local data = {
    active = active,
    enabled = ctx.enabled,
    preset = ctx.preset,
    wearOn = ctx.wear,
    hasEngine = engine and true or false,
    outside = round(env or envTemp(), 1),
  }
  if engine and spec then
    env = env or envTemp()
    if not engineT then engineT, oilT = engineTemps(env) end
    tb = tb or batteryTemp(env)
    local level, expected = startRating(engineT, tb)
    local hint, tone = "", "info"
    if active then hint, tone = hintFor(engineT, level) end
    data.engineTemp = round(engineT, 1)
    data.oilTemp = round(oilT, 1)
    data.diesel = spec.diesel
    data.fuel = spec.fuel
    data.fuelLabel = spec.fuelLabel
    data.cylinders = spec.cylinders
    data.litres = spec.litres and round(spec.litres, 1) or nil
    data.year = spec.year
    data.capAh = round(spec.capAh, 0)
    data.battery = round(st.soc, 3)
    data.volts = round(st.volts * spec.volts / 12, 1)
    data.phase = st.phase
    data.rating = level
    data.ratingLabel = expected < 1000 and RATINGS[level + 1] or "won't start"
    data.expected = expected < 1000 and round(expected, 1) or nil
    data.flood = round(st.flood, 2)
    data.glow = round(st.glow, 2)
    data.glowActive = st.glowActive or false
    data.starterHeat = round(st.starterHeat, 2)
    data.crankSpeed = round(st.crankSpeed, 2)
    data.crankTime = round(st.crankTime, 1)
    data.attempts = st.attempts
    data.falseStarts = st.falseStarts
    data.heater = st.heater
    data.wear = round((st.wearScale - 1) * 100, 1)
    data.rpm = round((tonumber(engine.outputAV1) or 0) * 9.5493, 0)
    data.hint = hint
    data.hintTone = tone
  end
  gui.send(STREAM, data)
end

-- Public API -----------------------------------------------------------------------------------------

function M.setContext(newCtx)
  if type(newCtx) ~= "table" then return end
  local oldSerial = ctx.soakSerial
  for k, val in pairs(newCtx) do ctx[k] = val end
  ctx.difficulty = clamp(tonumber(ctx.difficulty) or 1, 0.2, 3)
  ctx.batteryDrain = clamp(tonumber(ctx.batteryDrain) or 1, 0, 5)
  ctx.chargeRate = clamp(tonumber(ctx.chargeRate) or 4, 0, 50)
  if not gotContext then
    gotContext = true
    -- Fresh spawn: start from a cold-soaked engine if asked to.
    if ctx.soakOnReset then st.pendingSoak = 0.2 end
    if ctx.engineOffOnReset then st.pendingOff = 3 end
  elseif ctx.soakSerial ~= oldSerial and st.phase ~= "running" then
    -- The outside temperature was changed: a parked car has been sitting in it.
    st.pendingSoak = 0.4
  end
end

-- Model year and the like, which only the game engine side knows.
function M.setVehicleInfo(info)
  if type(info) ~= "table" then return end
  vehInfo = info
  if engine then buildSpec() end
end

function M.coldSoak()
  st.pendingSoak = 0
end

function M.chargeBattery()
  st.soc = 1
end

function M.setBattery(percent)
  st.soc = clamp((tonumber(percent) or 100) / 100, 0, 1)
end

function M.setHeater(on)
  if on == nil then on = not st.heater end
  st.heater = on and true or false
  if st.heater and obj:getVelocity():length() > 2 then st.heater = false end
end

function M.getState()
  return {state = st, spec = spec, ctx = ctx, hasEngine = engine and true or false}
end

-- Lifecycle ------------------------------------------------------------------------------------------

function M.updateGFX(dt)
  dt = clamp(tonumber(dt) or 0, 0, 0.1)
  if dt <= 0 then return end
  if engine == nil then findEngine() end
  for key, t in pairs(messageTimers) do messageTimers[key] = t - dt end
  if playerInfo and playerInfo.anyPlayerSeated then wasPlayer = true end

  local active = isActive()
  local env, engineT, oilT, tb
  if engine then
    if st.pendingSoak then
      st.pendingSoak = st.pendingSoak - dt
      if st.pendingSoak <= 0 then
        st.pendingSoak = nil
        coldSoak()
      end
    end
    if st.pendingOff then
      st.pendingOff = st.pendingOff - dt
      if playerInfo and playerInfo.firstPlayerSeated then
        st.pendingOff = nil
        if electrics and electrics.setIgnitionLevel then
          electrics.setIgnitionLevel(0)
        elseif controller and controller.mainController and controller.mainController.setEngineIgnition then
          controller.mainController.setEngineIgnition(false)
        end
      elseif st.pendingOff <= 0 then
        st.pendingOff = nil
      end
    end
    if active then
      env, engineT, oilT, tb = simulate(dt)
      st.wasActive = true
    elseif st.wasActive then
      st.wasActive = false
      release()
    end
  end

  if streams and streams.willSend and streams.willSend(STREAM) then
    telemetryTimer = telemetryTimer + dt
    if telemetryTimer >= 0.15 then
      telemetryTimer = 0
      sendTelemetry(active, env, engineT, oilT, tb)
    end
  end
end

-- BeamNG's reset repairs the vehicle and restarts the engine.
function M.onReset()
  restoreStarter()
  setFastIdle(0)
  unblockStarter()
  local soc = st.soc
  st = newState()
  if not ctx.rechargeOnReset then st.soc = soc end
  pitchApplied = 1
  engine = nil            -- look the engine up again on the next frame
  if ctx.soakOnReset then st.pendingSoak = 0.2 end
  if ctx.engineOffOnReset then st.pendingOff = 3 end
end

function M.onExtensionLoaded()
  st = newState()
  engine = nil
  gotContext = false
  obj:queueGameEngineLua("if coldStartManager then coldStartManager.sendContextTo(" .. obj:getID() .. ") end")
end

function M.onExtensionUnloaded()
  release()
end

return M
