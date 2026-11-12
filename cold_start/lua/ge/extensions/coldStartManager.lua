-- Cold Start - game-engine side.
--
-- * loads the "coldStart" vehicle extension into every vehicle and keeps it loaded,
-- * stores the settings (settings/coldStart.json in the user folder),
-- * sets the outside temperature: the override is written to the game's own environment temperature,
--   so engine thermals, the temperature gauge, air density and exhaust steam all follow it,
-- * runs the UI app's commands.

local M = {}

-- Run after core_environment, which writes the level's temperature every frame.
M.dependencies = {"core_environment"}

local SETTINGS_FILE = "settings/coldStart.json"
local VEHICLE_EXTENSION = "coldStart"
local KELVIN = 273.15

local PRESETS = {arcade = 0.45, realistic = 1, brutal = 1.7}

local defaults = {
  enabled = true,
  preset = "realistic",       -- arcade | realistic | brutal
  wear = true,
  soakOnReset = true,
  engineOffOnReset = false,
  rechargeOnReset = true,
  aiVehicles = false,
  batteryDrain = 1,
  chargeRate = 4,
  outsideOverride = nil,      -- deg C at sea level, nil = from the level
}
local NON_DEFAULT = {outsideOverride = true}

local settings = {}
local soakSerial = 0
local overriding = false
local overrideBroken = false
local timer = 0
local fullSyncTimer = 0
local lastSent = nil

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function round(x, d) local m = 10 ^ (d or 0); return math.floor(x * m + 0.5) / m end

local function loadSettings()
  settings = deepcopy(defaults)
  local saved = jsonReadFile(SETTINGS_FILE)
  if type(saved) == "table" then
    for k, val in pairs(saved) do
      if defaults[k] ~= nil or NON_DEFAULT[k] then settings[k] = val end
    end
  end
  if not PRESETS[settings.preset] then settings.preset = "realistic" end
  if type(settings.outsideOverride) ~= "number" then settings.outsideOverride = nil end
end

local function saveSettings()
  jsonWriteFile(SETTINGS_FILE, settings, true)
end

-- Outside temperature --------------------------------------------------------------------------------

local function levelTempC()
  if core_environment and core_environment.getTemperatureK then
    local ok, k = pcall(core_environment.getTemperatureK)
    if ok and tonumber(k) and tonumber(k) > 150 then return tonumber(k) - KELVIN end
  end
  return nil
end

local function writeSeaLevelTemp(c)
  be:setSeaLevelTemperatureK(c + KELVIN)
end

-- Called every frame after core_environment has written the level's temperature.
local function applyOutside()
  if overrideBroken or not be then return end
  local override = settings.enabled and settings.outsideOverride or nil
  if type(override) == "number" then
    if pcall(writeSeaLevelTemp, override) then overriding = true else overrideBroken = true end
  elseif overriding then
    overriding = false
    -- Levels without a temperature curve never write it themselves, so put it back.
    local c = levelTempC()
    if c then pcall(writeSeaLevelTemp, c) end
  end
end

-- Outside temperature in deg C as this mod sees it (other mods can read it too).
function M.getOutsideC()
  if overriding and type(settings.outsideOverride) == "number" then return settings.outsideOverride end
  return levelTempC()
end

function M.isOverridingTemperature()
  return overriding
end

-- Vehicles -------------------------------------------------------------------------------------------

local function buildContext()
  return {
    enabled = settings.enabled,
    preset = settings.preset,
    difficulty = PRESETS[settings.preset] or 1,
    wear = settings.wear,
    soakOnReset = settings.soakOnReset,
    engineOffOnReset = settings.engineOffOnReset,
    rechargeOnReset = settings.rechargeOnReset,
    aiVehicles = settings.aiVehicles,
    batteryDrain = settings.batteryDrain,
    chargeRate = settings.chargeRate,
    soakSerial = soakSerial,
  }
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
end

-- Model year of a vehicle from its info files (the configuration's own years if it has them).
local function readModelYear(vehId)
  local details = core_vehicles.getVehicleDetails(vehId)
  local years = (type(details.configs) == "table" and details.configs.Years) or (type(details.model) == "table" and details.model.Years)
  if type(years) ~= "table" then return nil end
  local lo, hi = tonumber(years.min), tonumber(years.max)
  if lo and hi then return math.floor((lo + hi) / 2) end
  return lo or hi
end

local function infoCommand(vehId)
  local year
  if core_vehicles and core_vehicles.getVehicleDetails then
    local ok, res = pcall(readModelYear, vehId)
    if ok then year = res end
  end
  return "if " .. VEHICLE_EXTENSION .. " and " .. VEHICLE_EXTENSION .. ".setVehicleInfo then " .. VEHICLE_EXTENSION .. ".setVehicleInfo(" .. serialize({year = year}) .. ") end"
end

-- Called by the vehicle extension when it (re)loads.
function M.sendContextTo(vehId)
  vehId = tonumber(vehId) or -1
  local veh = getObjectByID(vehId)
  if veh then
    veh:queueLuaCommand(infoCommand(vehId))
    veh:queueLuaCommand(contextCommand())
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

local failure = nil

function M.requestSettings()
  local s = deepcopy(settings)
  s.error = failure
  local level = levelTempC()
  s.levelTemp = level and round(level, 1) or nil
  s.overrideAvailable = not overrideBroken
  guihooks.trigger("ColdStartSettings", s)
end

function M.setSetting(key, value)
  if defaults[key] == nil and not NON_DEFAULT[key] then return end
  if key == "outsideOverride" then
    value = tonumber(value)
    if value then value = clamp(round(value), -50, 50) end
    if value ~= settings.outsideOverride then soakSerial = soakSerial + 1 end
  elseif key == "preset" then
    if not PRESETS[value] then value = "realistic" end
  elseif type(defaults[key]) == "number" then
    value = tonumber(value) or defaults[key]
  elseif type(defaults[key]) == "boolean" then
    value = value == true
  end
  -- Switching the mod on or off switches the temperature override with it.
  if key == "enabled" and value ~= settings.enabled and settings.outsideOverride ~= nil then soakSerial = soakSerial + 1 end
  settings[key] = value
  saveSettings()
  applyOutside()
  broadcast()
  M.requestSettings()
end

-- Moves the outside temperature by a number of degrees, starting from the level's temperature.
function M.nudgeOutside(delta)
  local base = settings.outsideOverride
  if type(base) ~= "number" then base = round(levelTempC() or 15) end
  M.setSetting("outsideOverride", base + (tonumber(delta) or 0))
end

function M.resetSettings()
  if settings.outsideOverride ~= nil then soakSerial = soakSerial + 1 end
  settings = deepcopy(defaults)
  saveSettings()
  applyOutside()
  broadcast()
  M.requestSettings()
end

-- Runs a coldStart function on the player's vehicle: coldSoak, chargeBattery, setBattery(percent),
-- setHeater(true | false | nil to toggle).
local allowedVehicleCalls = {coldSoak = true, chargeBattery = true, setBattery = true, setHeater = true}
function M.playerVehicleCall(fnName, value)
  if not allowedVehicleCalls[fnName] then return end
  local veh = playerVehicle()
  if not veh then
    ui_message("No vehicle", 3, "coldStart")
    return
  end
  local args = ""
  if fnName == "setBattery" then
    args = tostring(clamp(tonumber(value) or 100, 0, 100))
  elseif fnName == "setHeater" then
    args = value == nil and "nil" or tostring(value == true)
  end
  veh:queueLuaCommand("if " .. VEHICLE_EXTENSION .. " then " .. VEHICLE_EXTENSION .. "." .. fnName .. "(" .. args .. ") end")
end

-- Hooks ----------------------------------------------------------------------------------------------

function M.onUpdate(dtReal)
  applyOutside()
  dtReal = dtReal or 0
  timer = timer + dtReal
  fullSyncTimer = fullSyncTimer + dtReal
  if timer < 1 then return end
  timer = 0
  local cmd = contextCommand()
  if cmd ~= lastSent then
    broadcast()
  elseif fullSyncTimer > 10 then
    -- Slow full sync: reloads the extension into vehicles that lost it (e.g. a vehicle Lua reload).
    fullSyncTimer = 0
    forEachVehicle(loadInto)
    broadcast()
  end
end

-- Last word on the temperature before the vehicles read it for this frame.
function M.onPreRender()
  applyOutside()
end

function M.onVehicleSpawned(vehId)
  local veh = getObjectByID(vehId)
  if veh then loadInto(veh) end
end

function M.onExtensionLoaded()
  loadSettings()
  applyOutside()
  forEachVehicle(loadInto)
  lastSent = contextCommand()
end

function M.onExtensionUnloaded()
  settings.outsideOverride = nil
  applyOutside()
end

function M.onClientStartMission()
  overriding = false
  applyOutside()
  forEachVehicle(loadInto)
end

-- Safety net: an error in here must never become a fatal Lua error. The first one switches the manager
-- off and is reported in the log and in the UI app.
local function report()
  pcall(function() guihooks.trigger("ColdStartSettings", {error = failure, enabled = false}) end)
end
for name, fn in pairs(M) do
  if type(fn) == "function" then
    M[name] = function(...)
      if failure then
        if name == "requestSettings" then report() end
        return
      end
      local res = {xpcall(fn, debug.traceback, ...)}
      if not res[1] then
        failure = name .. ": " .. tostring(res[2])
        pcall(log, "E", "coldStart", failure)
        report()
        return
      end
      return unpack(res, 2)
    end
  end
end

return M
