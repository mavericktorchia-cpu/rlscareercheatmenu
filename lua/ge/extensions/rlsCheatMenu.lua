-- RLS Career Cheat Menu - game-engine (GE) backend for the "RLS Cheat Menu" UI app.
--
-- Requires RLS Career Overhaul (https://github.com/RLS-Modding/rls_career_overhaul), written
-- against v2.8.x (BeamNG.drive 0.40). Every RLS module is looked up lazily and every action
-- runs inside pcall, so a missing or renamed module shows an error toast instead of breaking the game.
--
-- The UI calls these functions through bngApi.engineLua("rlsCheatMenu.<fn>(...)").
-- After each action the current state is pushed back with guihooks.trigger("RLSCheatMenuState", state).

local M = {}

local logTag = "rlsCheatMenu"
local cheatReason = {label = "Cheat Menu", tags = {"cheat"}}

-- Helpers ------------------------------------------------------------------------------------------

local function ext(name)
  return rawget(_G, name)
end

local function careerActive()
  local career = ext("overhaul_career_career")
  if not career or not career.isActive then return false end
  local ok, active = pcall(career.isActive)
  return ok and active == true
end

local function attrs()
  return ext("overhaul_career_economy_playerAttributes")
end

local function toast(msg, kind)
  ui_message(msg, 4, "rlsCheatMenu", kind == "error" and "error" or "info")
end

local function reason()
  -- addAttributes turns reason.tags into a lookup table in place, so hand it a fresh copy each time.
  return {label = cheatReason.label, tags = {"cheat"}}
end

local function translate(text)
  if type(text) ~= "string" then return tostring(text or "") end
  local locales = ext("core_locales")
  if locales and locales.translateWithOrWithoutContext then
    local ok, res = pcall(locales.translateWithOrWithoutContext, text)
    if ok and type(res) == "string" and res ~= "" then return res end
  end
  return text
end

local function requestSave()
  local saveSystem = ext("overhaul_career_saveSystem")
  if saveSystem and saveSystem.requestSave then
    pcall(saveSystem.requestSave, "rlsCheatMenu")
  end
end

-- Runs one cheat action. The action returns a message to show (or nothing), and may error().
local function run(actionName, fn, needsCareer)
  if needsCareer ~= false and not careerActive() then
    toast("RLS Career is not active. Load an RLS career first.", "error")
    M.requestState()
    return
  end
  local ok, res = pcall(fn)
  if ok then
    if res then toast(res) end
  else
    log("E", logTag, actionName .. " failed: " .. tostring(res))
    -- Drop the "file:line:" prefix that error() adds; the log line above keeps it.
    local shortMsg = tostring(res):gsub("^.-:%d+: ", "")
    toast(actionName .. " failed: " .. shortMsg, "error")
  end
  M.requestState()
end

-- State --------------------------------------------------------------------------------------------

local function collectSkills()
  local skills = ext("overhaul_career_progression_skills")
  local a = attrs()
  local list = {}
  if not skills or not skills.getSortedBranches or not a then return list end
  local ok, branches = pcall(skills.getSortedBranches)
  if not ok or type(branches) ~= "table" then return list end
  for _, branch in ipairs(branches) do
    local levels = branch.levels
    if not branch.isDomain and branch.attributeKey and type(levels) == "table" and #levels > 0 then
      local xp = a.getAttributeValue(branch.attributeKey) or 0
      local level = 0
      for i, lvl in ipairs(levels) do
        if lvl.requiredValue and xp >= lvl.requiredValue then level = i end
      end
      table.insert(list, {
        key = branch.attributeKey,
        name = translate(branch.name or branch.attributeKey),
        xp = xp,
        level = level,
        maxLevel = #levels,
      })
    end
  end
  return list
end

local function orgRepBounds(org)
  local rep = ext("overhaul_career_progression_reputation")
  local minV, maxV = -100, 100
  if rep then
    if rep.getMinimumValue then
      local ok, v = pcall(rep.getMinimumValue, org)
      if ok and type(v) == "number" then minV = v end
    end
    if rep.getMaximumValue then
      local ok, v = pcall(rep.getMaximumValue, org)
      if ok and type(v) == "number" then maxV = v end
    end
  end
  return minV, maxV
end

local function collectOrgs()
  local orgsExt = ext("overhaul_world_organizations")
  local a = attrs()
  local list = {}
  if not orgsExt or not orgsExt.getOrganizations or not a then return list end
  local ok, orgs = pcall(orgsExt.getOrganizations)
  if not ok or type(orgs) ~= "table" then return list end
  for orgId, org in pairs(orgs) do
    local id = (type(org) == "table" and org.id) or orgId
    local minV, maxV = orgRepBounds(org)
    table.insert(list, {
      id = id,
      name = translate(type(org) == "table" and org.name or id),
      value = a.getAttributeValue(id .. "Reputation") or 0,
      min = minV,
      max = maxV,
    })
  end
  table.sort(list, function(x, y) return tostring(x.name) < tostring(y.name) end)
  return list
end

local function getPoliceService()
  return ext("overhaul_integration_services_police") or ext("gameplay_police")
end

local function playerInPursuit()
  local police = getPoliceService()
  local vehId = be:getPlayerVehicleID(0)
  if not police or not police.isVehicleInPursuit or not vehId or vehId < 0 then return false end
  local ok, inPursuit = pcall(police.isVehicleInPursuit, vehId)
  return ok and inPursuit == true
end

function M.requestState()
  local state = {active = careerActive()}
  if state.active then
    local a = attrs()
    if a then
      state.money = a.getAttributeValue("money") or 0
      state.beamXP = a.getAttributeValue("beamXP") or 0
      state.vouchers = a.getAttributeValue("vouchers") or 0
    end
    local cheats = ext("overhaul_career_economy_cheats")
    state.cheatsMode = cheats and cheats.isCheatsMode and cheats.isCheatsMode() or false

    local insurance = ext("overhaul_career_repair_insurance")
    if insurance and insurance.getDriverScore then
      local ok, score = pcall(insurance.getDriverScore)
      if ok then state.driverScore = score end
    end

    local carmeets = ext("overhaul_career_carmeets_reputation")
    if carmeets and carmeets.getReputation then
      local ok1, rep = pcall(carmeets.getReputation)
      local ok2, maxRep = pcall(carmeets.getMaxReputation)
      if ok1 then state.carMeetRep = rep end
      if ok2 then state.carMeetRepMax = maxRep end
    end

    local loans = ext("overhaul_career_economy_loans")
    if loans and loans.getActiveLoans then
      local ok, active = pcall(loans.getActiveLoans)
      if ok and type(active) == "table" then state.activeLoans = #active end
    end

    local inventory = ext("overhaul_career_garage_inventory")
    if inventory and inventory.getCurrentVehicle then
      local ok, invId = pcall(inventory.getCurrentVehicle)
      state.ownedVehicle = ok and invId ~= nil
    end

    state.inPursuit = playerInPursuit()
    state.skills = collectSkills()
    state.orgs = collectOrgs()
  end
  local tod = core_environment and core_environment.getTimeOfDay and core_environment.getTimeOfDay()
  if type(tod) == "table" and tod.time then state.timeOfDay = tod.time end
  guihooks.trigger("RLSCheatMenuState", state)
  return state
end

-- Money / attributes -------------------------------------------------------------------------------

function M.addMoney(amount)
  amount = tonumber(amount)
  run("Add money", function()
    if not amount or amount == 0 then error("enter an amount") end
    attrs().addAttributes({money = amount}, reason())
    return string.format("%s$%s", amount >= 0 and "+" or "-", math.floor(math.abs(amount)))
  end)
end

function M.setMoney(amount)
  amount = tonumber(amount)
  run("Set money", function()
    if not amount then error("enter an amount") end
    attrs().setAttributes({money = amount}, reason())
    return "Money set to $" .. math.floor(amount)
  end)
end

-- key is "beamXP" or "vouchers" (any non-money attribute works).
function M.addAttribute(key, amount)
  amount = tonumber(amount)
  run("Add " .. tostring(key), function()
    if type(key) ~= "string" or key == "" then error("no attribute") end
    if key == "money" then error("use addMoney") end
    if not amount or amount == 0 then error("enter an amount") end
    attrs().addAttributes({[key] = amount}, reason())
    return string.format("%s %+d", key, amount)
  end)
end

-- Skills -------------------------------------------------------------------------------------------

local function findSkillBranch(attributeKey)
  local skills = ext("overhaul_career_progression_skills")
  if not skills then error("skills module not found") end
  for _, branch in ipairs(skills.getSortedBranches() or {}) do
    if branch.attributeKey == attributeKey then return branch end
  end
  error("unknown skill " .. tostring(attributeKey))
end

local function xpForLevel(branch, level)
  local levels = branch.levels or {}
  level = math.max(0, math.min(level, #levels))
  if level == 0 then return 0 end
  return levels[level].requiredValue or 0
end

-- Sets a skill to the start of the given level (0 = no XP). Lowering is allowed.
function M.setSkillLevel(attributeKey, level)
  level = tonumber(level) or 0
  run("Set skill", function()
    local branch = findSkillBranch(attributeKey)
    attrs().setAttributes({[attributeKey] = xpForLevel(branch, level)}, reason())
    return translate(branch.name or attributeKey) .. " -> level " .. math.max(0, math.min(level, #branch.levels))
  end)
end

function M.maxAllSkills()
  run("Max all skills", function()
    local a = attrs()
    local skills = ext("overhaul_career_progression_skills")
    local change = {}
    local count = 0
    for _, branch in ipairs(skills.getSortedBranches() or {}) do
      if not branch.isDomain and branch.attributeKey and type(branch.levels) == "table" and #branch.levels > 0 then
        local target = xpForLevel(branch, #branch.levels)
        local current = a.getAttributeValue(branch.attributeKey) or 0
        if target > current then
          change[branch.attributeKey] = target - current
          count = count + 1
        end
      end
    end
    if count == 0 then return "All skills are already maxed" end
    a.addAttributes(change, reason())
    return "Maxed " .. count .. " skills"
  end)
end

-- Reputation ---------------------------------------------------------------------------------------

function M.setOrgReputation(orgId, value)
  run("Set reputation", function()
    local orgsExt = ext("overhaul_world_organizations")
    local org = orgsExt and orgsExt.getOrganization and orgsExt.getOrganization(orgId)
    if not org then error("unknown organization " .. tostring(orgId)) end
    local minV, maxV = orgRepBounds(org)
    local target
    if value == "max" then target = maxV
    elseif value == "min" then target = minV
    else target = tonumber(value) end
    if not target then error("enter a value") end
    target = math.max(minV, math.min(maxV, target))
    attrs().setAttributes({[orgId .. "Reputation"] = target}, reason())
    return translate(org.name or orgId) .. " reputation -> " .. target
  end)
end

function M.maxAllOrgReputation()
  run("Max all reputation", function()
    local orgsExt = ext("overhaul_world_organizations")
    local a = attrs()
    local newValues, count = {}, 0
    for orgId, org in pairs(orgsExt.getOrganizations() or {}) do
      local id = (type(org) == "table" and org.id) or orgId
      local _, maxV = orgRepBounds(org)
      newValues[id .. "Reputation"] = maxV
      count = count + 1
    end
    a.setAttributes(newValues, reason())
    return "Maxed reputation with " .. count .. " organizations"
  end)
end

function M.maxCarMeetReputation()
  run("Max car meet reputation", function()
    local carmeets = ext("overhaul_career_carmeets_reputation")
    if not carmeets then error("car meet module not found") end
    local maxRep = carmeets.getMaxReputation()
    carmeets.addReputation(maxRep - carmeets.getReputation(), "rlsCheatMenu")
    requestSave()
    return "Car meet reputation maxed"
  end)
end

-- Insurance ----------------------------------------------------------------------------------------

function M.setDriverScore(score)
  score = tonumber(score)
  run("Set driver score", function()
    local insurance = ext("overhaul_career_repair_insurance")
    if not insurance or not insurance.setDriverScore then error("insurance module not found") end
    if not score then error("enter a score") end
    insurance.setDriverScore(score)
    requestSave()
    return "Driver score -> " .. score
  end)
end

-- Vehicle ------------------------------------------------------------------------------------------

-- Free instant repair of the owned vehicle you are driving (the same path RLS uses after a paid repair).
-- For a vehicle that is not in your inventory it falls back to a plain physics reset.
function M.repairVehicle()
  run("Repair", function()
    local inventory = ext("overhaul_career_garage_inventory")
    local insurance = ext("overhaul_career_repair_insurance")
    local invId = inventory and inventory.getCurrentVehicle and inventory.getCurrentVehicle()
    local vehInfo = invId and inventory.getVehicles()[invId]
    if vehInfo and insurance and insurance.startRepairInstant then
      insurance.startRepairInstant(vehInfo)
      return "Vehicle repaired for free"
    end
    local veh = getPlayerVehicle(0)
    if not veh then error("you are not in a vehicle") end
    veh:queueLuaCommand("obj:requestReset(RESET_PHYSICS)")
    veh:resetBrokenFlexMesh()
    return "Vehicle reset (not an owned vehicle)"
  end)
end

-- Fills every fuel tank / battery of the current vehicle.
function M.refuel()
  run("Refuel", function()
    local veh = getPlayerVehicle(0)
    if not veh then error("you are not in a vehicle") end
    veh:queueLuaCommand([[
      if energyStorage and energyStorage.getStorages then
        for _, s in pairs(energyStorage.getStorages()) do
          if s.setRemainingRatio then pcall(s.setRemainingRatio, s, 1) end
        end
      end
    ]])
    return "Tanks filled"
  end, false)
end

-- Resets RLS wear systems (engine/radiator/transmission maintenance, tires) on the current vehicle.
-- Mirrors what RLS's own Freeroam+ cheat mode does when you recover a vehicle.
function M.serviceVehicle()
  run("Service", function()
    local veh = getPlayerVehicle(0)
    if not veh then error("you are not in a vehicle") end
    veh:queueLuaCommand([[
      if overhaulMaintenance and overhaulMaintenance.debugResetCategory then
        pcall(overhaulMaintenance.debugResetCategory, "engine")
        pcall(overhaulMaintenance.debugResetCategory, "radiator")
        pcall(overhaulMaintenance.debugResetCategory, "transmission")
      end
      if not overhaulTires then pcall(extensions.load, "overhaulTires") end
      if overhaulTires and overhaulTires.applyFreshAndInflate then pcall(overhaulTires.applyFreshAndInflate) end
    ]])
    return "Maintenance and tires reset"
  end, false)
end

-- Police / loans / world ---------------------------------------------------------------------------

-- Ends the pursuit on your vehicle without the arrest or evade outcome.
function M.clearWanted()
  run("Clear wanted", function()
    local police = getPoliceService()
    local vehId = be:getPlayerVehicleID(0)
    if not police or not police.setPursuitMode then error("police module not found") end
    if not vehId or vehId < 0 then error("you are not in a vehicle") end
    police.setPursuitMode(0, vehId)
    return "Pursuit cleared"
  end, false)
end

function M.clearLoans()
  run("Clear loans", function()
    local loans = ext("overhaul_career_economy_loans")
    if not loans or not loans.clearAllLoans then error("loans module not found") end
    local count = loans.clearAllLoans()
    return "Cleared " .. tostring(count or 0) .. " loans"
  end)
end

-- t: 0..1 where 0 = noon, 0.5 = midnight (BeamNG time-of-day convention).
function M.setTimeOfDay(t)
  t = tonumber(t)
  run("Set time", function()
    if not t then error("bad time") end
    core_environment.setTimeOfDay({time = t % 1})
    return nil
  end, false)
end

function M.saveCareer()
  run("Save", function()
    local saveSystem = ext("overhaul_career_saveSystem")
    if not saveSystem or not saveSystem.saveCurrent then error("save system not found") end
    saveSystem.saveCurrent()
    return "Career saved"
  end)
end

-- Hooks --------------------------------------------------------------------------------------------

-- The app tells us when it is on screen, so live refreshes cost nothing while it is hidden.
local uiOpen = false
local refreshPending = false
local refreshTimer = 0

function M.setUiOpen(open)
  uiOpen = open == true
  if uiOpen then M.requestState() end
end

local function queueRefresh()
  if uiOpen then refreshPending = true end
end

-- Coalesce bursts of changes (job payouts, per-second updates) into at most two pushes a second.
M.onUpdate = function(dtReal)
  if not refreshPending then return end
  refreshTimer = refreshTimer + (dtReal or 0)
  if refreshTimer >= 0.5 then
    refreshTimer = 0
    refreshPending = false
    M.requestState()
  end
end

M.onOverhaulActive = queueRefresh
M.onOverhaulPlayerAttributesChanged = queueRefresh
M.onPursuitAction = queueRefresh
M.onVehicleSwitched = queueRefresh

return M
