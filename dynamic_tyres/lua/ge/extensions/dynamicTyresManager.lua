-- Dynamic Tyres - game-engine side.
--
-- * loads the "dynamicTyres" vehicle extension into every vehicle,
-- * stores the settings (settings/dynamicTyres.json in the user folder),
-- * runs the road weather: ambient temperature, rain wetness, snow cover and ice
--   (snow settles below ~2 C, wet roads freeze below 0 C, everything melts above it),
-- * can make it snow (spawns a snow precipitation effect when the level has one),
-- * remembers tyre types chosen per vehicle, and runs the UI app's commands.

local M = {}

local SETTINGS_FILE = "settings/dynamicTyres.json"
local VEHICLE_EXTENSION = "dynamicTyres"
local SNOW_OBJECT = "dynamicTyresSnowfall"

local defaults = {
  enabled = true,
  temperature = true,
  wear = true,
  pressure = true,
  surface = true,
  extras = true,
  punctures = true,
  applyPressure = true,
  aiVehicles = true,
  resetWearOnReset = true,
  gripStrength = 1,
  heatRate = 1,
  wearRate = 1,
  wetMode = "auto",       -- road: auto | dry | damp | wet | soaked | snow | ice | blackIce
  snowfall = "off",       -- off | light | heavy
  ambientOverride = nil,  -- deg C, nil = from the level
}

-- Fixed road conditions: wetness, snow cover, ice cover.
local ROAD_MODES = {
  dry      = {0,    0,   0},
  damp     = {0.3,  0,   0},
  wet      = {0.65, 0,   0},
  soaked   = {1,    0,   0},
  snow     = {0,    1,   0},
  ice      = {0,    0,   1},
  blackIce = {0.1,  0,   0.65},
}
local SNOWFALL = {off = {drops = 0, intensity = 0}, light = {drops = 900, intensity = 0.4}, heavy = {drops = 2600, intensity = 1}}
local NON_NUMERIC = {ambientOverride = true}
local AXLES = {front = true, rear = true, all = true}
local COMPOUNDS = {auto = true, slick = true, sport = true, road = true, allTerrain = true, mud = true, winter = true}

local settings = {}
local wetness, snow, ice = 0, 0, 0
local rainIntensity, snowIntensity = 0, 0
local ambient = 20
local timer = 0
local fullSyncTimer = 0
local lastSent = nil
local snowDatablock = nil       -- name of a snow PrecipitationData in this level, or false if none
local compoundOverrides = {}    -- [vehId] = {front = id, rear = id}

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function round(x, d) local m = 10 ^ (d or 0); return math.floor(x * m + 0.5) / m end

local function loadSettings()
  settings = deepcopy(defaults)
  local saved = jsonReadFile(SETTINGS_FILE)
  if type(saved) == "table" then
    for k, val in pairs(saved) do
      if defaults[k] ~= nil or NON_NUMERIC[k] then settings[k] = val end
    end
  end
  if settings.wetMode ~= "auto" and not ROAD_MODES[settings.wetMode] then settings.wetMode = "auto" end
  if not SNOWFALL[settings.snowfall] then settings.snowfall = "off" end
end

local function saveSettings()
  jsonWriteFile(SETTINGS_FILE, settings, true)
end

-- Snowfall effect ------------------------------------------------------------------------------------

local function findSnowDatablock()
  if snowDatablock ~= nil then return snowDatablock end
  snowDatablock = false
  local names = scenetree and scenetree.findClassObjects and scenetree.findClassObjects("PrecipitationData") or {}
  for _, name in ipairs(names) do
    if string.find(string.lower(tostring(name)), "snow", 1, true) then
      snowDatablock = name
      break
    end
  end
  return snowDatablock
end

local function removeSnowfall()
  local o = scenetree and scenetree.findObject and scenetree.findObject(SNOW_OBJECT)
  if o then o:delete() end
end

local snowWarned = false
local function applySnowfall()
  local drops = SNOWFALL[settings.snowfall].drops
  if drops <= 0 then
    removeSnowfall()
    return
  end
  local datablock = findSnowDatablock()
  if not datablock then
    if not snowWarned then
      snowWarned = true
      ui_message("This level has no snow effect, so no snowflakes, but snow still settles on the roads.", 6, "dynamicTyres")
    end
    return
  end
  local o = scenetree.findObject(SNOW_OBJECT)
  if o then
    o:setField("numDrops", 0, tostring(drops))
    o:postApply()
    return
  end
  if not scenetree.MissionGroup then return end
  o = createObject("Precipitation")
  if not o then return end
  o:setField("dataBlock", 0, datablock)
  o:setField("numDrops", 0, tostring(drops))
  o:setField("doCollision", 0, "false")
  o:setField("useLighting", 0, "false")
  o.canSave = false
  o:registerObject(SNOW_OBJECT)
  scenetree.MissionGroup:addObject(o)
end

-- Environment ----------------------------------------------------------------------------------------

local function readAmbient()
  if type(settings.ambientOverride) == "number" then return settings.ambientOverride end
  local t = 20
  if core_environment and core_environment.getTemperatureK then
    local ok, k = pcall(core_environment.getTemperatureK)
    if ok and tonumber(k) and tonumber(k) > 150 then t = tonumber(k) - 273.15 end
  end
  -- Making it snow also makes it cold enough for the snow to settle, unless you set ambient yourself.
  if settings.snowfall ~= "off" then t = math.min(t, -3) end
  return t
end

-- Rain and snow intensity 0..1 from the level's Precipitation objects.
local function readPrecipitation()
  local rain, snowDrops = 0, 0
  local names = scenetree and scenetree.findClassObjects and scenetree.findClassObjects("Precipitation") or {}
  for _, name in ipairs(names) do
    local o = scenetree.findObject(name)
    if o then
      local datablock = string.lower(tostring(o:getField("dataBlock", 0) or ""))
      local hidden = tostring(o:getField("hidden", 0) or "") == "1"
      local drops = tonumber(o:getField("numDrops", 0)) or 0
      if not hidden then
        if string.find(datablock, "snow", 1, true) then snowDrops = snowDrops + drops
        else rain = rain + drops end
      end
    end
  end
  return clamp(rain / 1500, 0, 1), clamp(snowDrops / 2000, 0, 1)
end

local function updateRoad(dt)
  local fixed = ROAD_MODES[settings.wetMode]
  if fixed then
    wetness, snow, ice = fixed[1], fixed[2], fixed[3]
    return
  end
  rainIntensity, snowIntensity = readPrecipitation()
  -- Our own snowfall counts even where the level has no snow effect to show it.
  snowIntensity = math.max(snowIntensity, SNOWFALL[settings.snowfall].intensity)
  local freezing = ambient <= 0

  if snowIntensity > 0.02 then
    if ambient <= 2 then
      -- Heavy snow covers the road in about four minutes.
      snow = snow + dt * snowIntensity / 240
    else
      -- Too warm: it falls as slush and just wets the road.
      wetness = wetness + dt * snowIntensity / 300
    end
  end

  if rainIntensity > 0.02 then
    if freezing then
      -- Freezing rain glazes the road.
      ice = ice + dt * rainIntensity / 180
    else
      -- Heavy rain soaks the road in about a minute and a half.
      wetness = wetness + dt * rainIntensity / 90
    end
  elseif ambient > 0 then
    -- Roads dry in roughly 15 minutes, faster when it is warm.
    wetness = wetness - dt / 900 * (1 + math.max(0, ambient - 10) / 15)
  end

  if freezing then
    -- Standing water freezes, faster the colder it is (about 10 minutes at -1 C, 1 minute at -10 C).
    local frozen = math.min(wetness, dt * math.max(wetness, 0.1) * (-ambient + 0.5) / 600)
    wetness = wetness - frozen
    ice = ice + frozen
  else
    -- Snow and ice melt into water above freezing (10 C melts snow in about 10 minutes).
    local snowMelt = math.min(snow, dt * ambient / 6000)
    local iceMelt = math.min(ice, dt * ambient / 3000)
    snow, ice = snow - snowMelt, ice - iceMelt
    wetness = wetness + snowMelt * 0.6 + iceMelt
  end

  wetness, snow, ice = clamp(wetness, 0, 1), clamp(snow, 0, 1), clamp(ice, 0, 1)
end

-- Vehicles -------------------------------------------------------------------------------------------

local function buildContext()
  local ctx = {}
  for k in pairs(defaults) do
    if k ~= "wetMode" and k ~= "snowfall" and not NON_NUMERIC[k] then ctx[k] = settings[k] end
  end
  ctx.ambient = round(ambient, 1)
  ctx.wetness = round(wetness, 2)
  ctx.snow = round(snow, 2)
  ctx.ice = round(ice, 2)
  return ctx
end

local function contextCommand()
  return "if " .. VEHICLE_EXTENSION .. " then " .. VEHICLE_EXTENSION .. ".setContext(" .. serialize(buildContext()) .. ") end"
end

local function compoundCommand(axle, compoundId)
  return string.format("if %s then %s.setCompound(%q, %q) end", VEHICLE_EXTENSION, VEHICLE_EXTENSION, axle, compoundId)
end

local function forEachVehicle(fn)
  if not be then return end
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh then fn(veh) end
  end
end

local function sendOverrides(veh)
  local o = compoundOverrides[veh:getID()]
  if not o then return end
  if o.front then veh:queueLuaCommand(compoundCommand("front", o.front)) end
  if o.rear then veh:queueLuaCommand(compoundCommand("rear", o.rear)) end
end

local function loadInto(veh)
  veh:queueLuaCommand("if not " .. VEHICLE_EXTENSION .. " then extensions.load('" .. VEHICLE_EXTENSION .. "') end")
  veh:queueLuaCommand(contextCommand())
end

-- Called by the vehicle extension when it (re)loads, e.g. after a part change respawn.
function M.sendContextTo(vehId)
  local veh = getObjectByID(tonumber(vehId) or -1)
  if veh then
    veh:queueLuaCommand(contextCommand())
    sendOverrides(veh)
  end
end

local function broadcast()
  local cmd = contextCommand()
  forEachVehicle(function(veh) veh:queueLuaCommand(cmd) end)
  lastSent = cmd
end

local function playerVehicle()
  return getPlayerVehicle and getPlayerVehicle(0) or nil
end

-- UI API ---------------------------------------------------------------------------------------------

function M.requestSettings()
  local s = deepcopy(settings)
  s.currentAmbient = round(ambient, 1)
  s.currentWetness = round(wetness, 2)
  s.currentSnow = round(snow, 2)
  s.currentIce = round(ice, 2)
  s.rainIntensity = round(rainIntensity, 2)
  s.snowIntensity = round(snowIntensity, 2)
  s.snowEffectAvailable = findSnowDatablock() and true or false
  local veh = playerVehicle()
  local o = veh and compoundOverrides[veh:getID()] or {}
  s.playerCompounds = {front = o.front or "auto", rear = o.rear or "auto"}
  guihooks.trigger("DynamicTyresSettings", s)
end

function M.setSetting(key, value)
  if defaults[key] == nil and not NON_NUMERIC[key] then return end
  if key == "ambientOverride" then
    value = tonumber(value)
  elseif type(defaults[key]) == "number" then
    value = tonumber(value) or defaults[key]
  elseif type(defaults[key]) == "boolean" then
    value = value == true
  elseif key == "wetMode" then
    if value ~= "auto" and not ROAD_MODES[value] then value = "auto" end
  elseif key == "snowfall" then
    if not SNOWFALL[value] then value = "off" end
  end
  settings[key] = value
  saveSettings()
  if key == "snowfall" then applySnowfall() end
  ambient = readAmbient()
  updateRoad(0)
  broadcast()
  M.requestSettings()
end

function M.resetSettings()
  settings = deepcopy(defaults)
  saveSettings()
  applySnowfall()
  ambient = readAmbient()
  broadcast()
  M.requestSettings()
end

-- Runs a dynamicTyres function on the player's vehicle: fitNewTyres, warmTyres, resetColdPressure,
-- adjustColdPressure(axle, deltaKPa) or setCompound(axle, compoundId).
local allowedVehicleCalls = {fitNewTyres = true, warmTyres = true, resetColdPressure = true, adjustColdPressure = true, setCompound = true}
function M.playerVehicleCall(fnName, axle, value)
  if not allowedVehicleCalls[fnName] then return end
  local veh = playerVehicle()
  if not veh then
    ui_message("No vehicle", 3, "dynamicTyres")
    return
  end
  local args = ""
  if fnName == "adjustColdPressure" then
    if not AXLES[axle] then return end
    args = string.format("%q, %s", axle, tostring(tonumber(value) or 0))
  elseif fnName == "setCompound" then
    if not AXLES[axle] or not COMPOUNDS[value] then return end
    local o = compoundOverrides[veh:getID()] or {}
    if axle == "front" or axle == "all" then o.front = value ~= "auto" and value or nil end
    if axle == "rear" or axle == "all" then o.rear = value ~= "auto" and value or nil end
    compoundOverrides[veh:getID()] = o
    veh:queueLuaCommand(compoundCommand(axle, value))
    M.requestSettings()
    return
  end
  veh:queueLuaCommand("if " .. VEHICLE_EXTENSION .. " then " .. VEHICLE_EXTENSION .. "." .. fnName .. "(" .. args .. ") end")
end

-- Hooks ----------------------------------------------------------------------------------------------

function M.onUpdate(dtReal)
  dtReal = dtReal or 0
  timer = timer + dtReal
  fullSyncTimer = fullSyncTimer + dtReal
  if timer < 1 then return end
  local dt = timer
  timer = 0
  ambient = readAmbient()
  updateRoad(dt)
  local cmd = contextCommand()
  -- Only resend when something changed, plus a slow full sync for vehicles that missed one.
  if cmd ~= lastSent or fullSyncTimer > 10 then
    fullSyncTimer = 0
    broadcast()
  end
end

function M.onVehicleSpawned(vehId)
  local veh = getObjectByID(vehId)
  if veh then loadInto(veh) end
end

function M.onVehicleDestroyed(vehId)
  compoundOverrides[vehId] = nil
end

function M.onExtensionLoaded()
  loadSettings()
  ambient = readAmbient()
  forEachVehicle(loadInto)
  lastSent = contextCommand()
  applySnowfall()
end

function M.onExtensionUnloaded()
  removeSnowfall()
end

function M.onClientStartMission()
  wetness, snow, ice = 0, 0, 0
  snowDatablock = nil
  snowWarned = false
  compoundOverrides = {}
  ambient = readAmbient()
  forEachVehicle(loadInto)
  applySnowfall()
end

return M
