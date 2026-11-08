-- Dynamic Tyres - game-engine side.
--
-- * loads the "dynamicTyres" vehicle extension into every vehicle,
-- * stores the settings (settings/dynamicTyres.json in the user folder),
-- * works out ambient temperature and road wetness (from rain, or a manual override),
-- * sends both to the vehicles, and runs the UI app's commands.

local M = {}

local SETTINGS_FILE = "settings/dynamicTyres.json"
local VEHICLE_EXTENSION = "dynamicTyres"

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
  wetMode = "auto",       -- auto | dry | damp | wet | soaked
  ambientOverride = nil,  -- deg C, nil = from the level
}

local WET_LEVELS = {dry = 0, damp = 0.3, wet = 0.65, soaked = 1}

local settings = {}
local wetness = 0
local rainIntensity = 0
local ambient = 20
local timer = 0
local fullSyncTimer = 0
local lastSent = nil

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

local function loadSettings()
  settings = deepcopy(defaults)
  local saved = jsonReadFile(SETTINGS_FILE)
  if type(saved) == "table" then
    for k, val in pairs(saved) do
      if defaults[k] ~= nil or k == "ambientOverride" then settings[k] = val end
    end
  end
end

local function saveSettings()
  jsonWriteFile(SETTINGS_FILE, settings, true)
end

-- Environment ----------------------------------------------------------------------------------------

local function readAmbient()
  if type(settings.ambientOverride) == "number" then return settings.ambientOverride end
  if core_environment and core_environment.getTemperatureK then
    local ok, k = pcall(core_environment.getTemperatureK)
    if ok and tonumber(k) and tonumber(k) > 150 then return tonumber(k) - 273.15 end
  end
  return 20
end

-- Rain intensity 0..1 from the level's Precipitation objects (snow does not wet the road).
local function readRain()
  local total = 0
  local names = scenetree and scenetree.findClassObjects and scenetree.findClassObjects("Precipitation") or {}
  for _, name in ipairs(names) do
    local o = scenetree.findObject(name)
    if o then
      local datablock = string.lower(tostring(o:getField("dataBlock", 0) or ""))
      local hidden = tostring(o:getField("hidden", 0) or "") == "1"
      if not hidden and not string.find(datablock, "snow", 1, true) then
        total = total + (tonumber(o:getField("numDrops", 0)) or 0)
      end
    end
  end
  return clamp(total / 1500, 0, 1)
end

local function updateWetness(dt)
  local mode = settings.wetMode
  if WET_LEVELS[mode] then
    wetness = WET_LEVELS[mode]
    return
  end
  rainIntensity = readRain()
  if rainIntensity > 0.02 then
    -- Heavy rain soaks the road in about a minute and a half.
    wetness = math.min(1, wetness + dt * rainIntensity / 90)
  else
    -- Roads dry in roughly 15 minutes, faster when it is warm.
    wetness = math.max(0, wetness - dt / 900 * (1 + math.max(0, ambient - 10) / 15))
  end
end

-- Vehicles -------------------------------------------------------------------------------------------

local function buildContext()
  local ctx = {}
  for k in pairs(defaults) do
    if k ~= "wetMode" and k ~= "ambientOverride" then ctx[k] = settings[k] end
  end
  ctx.ambient = math.floor(ambient * 10 + 0.5) / 10
  ctx.wetness = math.floor(wetness * 100 + 0.5) / 100
  return ctx
end

local function contextCommand()
  return "if " .. VEHICLE_EXTENSION .. " then " .. VEHICLE_EXTENSION .. ".setContext(" .. serialize(buildContext()) .. ") end"
end

local function forEachVehicle(fn)
  if not be then return end
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh then fn(veh) end
  end
end

local function loadInto(veh)
  veh:queueLuaCommand("if not " .. VEHICLE_EXTENSION .. " then extensions.load('" .. VEHICLE_EXTENSION .. "') end")
  veh:queueLuaCommand(contextCommand())
end

function M.sendContextTo(vehId)
  local veh = getObjectByID(tonumber(vehId) or -1)
  if veh then veh:queueLuaCommand(contextCommand()) end
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
  s.currentAmbient = math.floor(ambient * 10 + 0.5) / 10
  s.currentWetness = math.floor(wetness * 100 + 0.5) / 100
  s.rainIntensity = math.floor(rainIntensity * 100 + 0.5) / 100
  guihooks.trigger("DynamicTyresSettings", s)
end

function M.setSetting(key, value)
  if defaults[key] == nil and key ~= "ambientOverride" then return end
  if key == "ambientOverride" then
    value = tonumber(value)
  elseif type(defaults[key]) == "number" then
    value = tonumber(value) or defaults[key]
  elseif type(defaults[key]) == "boolean" then
    value = value == true
  elseif key == "wetMode" then
    if value ~= "auto" and not WET_LEVELS[value] then value = "auto" end
  end
  settings[key] = value
  saveSettings()
  ambient = readAmbient()
  updateWetness(0)
  broadcast()
  M.requestSettings()
end

function M.resetSettings()
  settings = deepcopy(defaults)
  saveSettings()
  ambient = readAmbient()
  broadcast()
  M.requestSettings()
end

-- Runs a dynamicTyres function on the player's vehicle: fitNewTyres, warmTyres, resetColdPressure,
-- or adjustColdPressure with (axle, deltaKPa).
local allowedVehicleCalls = {fitNewTyres = true, warmTyres = true, resetColdPressure = true, adjustColdPressure = true}
function M.playerVehicleCall(fnName, axle, delta)
  if not allowedVehicleCalls[fnName] then return end
  local veh = playerVehicle()
  if not veh then
    ui_message("No vehicle", 3, "dynamicTyres")
    return
  end
  local args = ""
  if fnName == "adjustColdPressure" then
    args = string.format("%q, %s", tostring(axle or "all"), tostring(tonumber(delta) or 0))
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
  updateWetness(dt)
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

function M.onExtensionLoaded()
  loadSettings()
  ambient = readAmbient()
  forEachVehicle(loadInto)
  lastSent = contextCommand()
end

function M.onClientStartMission()
  wetness = 0
  ambient = readAmbient()
  forEachVehicle(loadInto)
end

return M
