-- Choo-Choo Charles v0.6.0 ALPHA. Performance update to the working v0.5 mechanisms.
-- F6 player / F7 train / F8 double / F9 snapshot / F10 no heat / F11 HUD.
-- See README: live readback is not proof that every scripted death is blocked.
local VERSION = "0.6.0-alpha"
local source = debug.getinfo(1, "S").source:gsub("\\", "/"):gsub("^@", "")
local script_dir = source:match("^(.*)/[^/]+$") or "."
local root = script_dir:match("^(.*)/[Ss]cripts$") or script_dir
package.path = script_dir .. "/?.lua;" .. package.path
local Core = require("core")
local HUD = require("hud")
local Diagnostics = require("diagnostics")
local NoHeat = require("noheat")
local PlayerGuard = require("playerguard")
local Logger = require("logger")

local counters = {steps = 0, heat_steps = 0, scans = 0, global_searches = 0,
    full_names = 0, identity_cache_hits = 0, full_snapshots = 0,
    compact_snapshots = 0, damage_events = 0}
local logger = Logger.new({root = root, report = function(message)
    print("[CCC-GODMOD] " .. tostring(message) .. "\n")
end})
local function append(filename, text)
    return logger:append(filename, text)
end
local function log(text)
    print("[CCC-GODMOD] " .. tostring(text) .. "\n")
    append("CCC_Mod_Status.log", text)
end
local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end
local function read(object, name)
    if object == nil then return nil end
    if name == "bCanBeDamaged" then
        local ok, value = pcall(function() return object:GetCanBeDamaged() end)
        if ok and type(value) == "boolean" then return value end
    end
    local ok, value = pcall(function() return object[name] end)
    if ok and value ~= nil then return value end
    ok, value = pcall(function() return object:GetPropertyValue(name) end)
    if ok then return value end
end
local function write(object, name, value)
    if name == "bCanBeDamaged" then
        local ok = pcall(function() object:SetCanBeDamaged(value) end)
        if ok and read(object, name) == value then return true end
    end
    local ok = pcall(function() object[name] = value end)
    return ok
end
-- Per-pass caches cannot outlive the next maintenance/key/discovery pass.
-- Preserve the original address+path identity used by core restoration records.
local name_cache, identity_cache = {}, {}
local function new_pass()
    name_cache, identity_cache = {}, {}
end
local function full(object)
    if object == nil then return "<invalid>" end
    if name_cache[object] then return name_cache[object] end
    counters.full_names = counters.full_names + 1
    local ok, value = pcall(function() return object:GetFullName() end)
    local name = ok and tostring(value) or "<invalid>"
    name_cache[object] = name
    return name
end
local function identity(object)
    if not valid(object) then return "none" end
    if identity_cache[object] then
        counters.identity_cache_hits = counters.identity_cache_hits + 1
        return identity_cache[object]
    end
    local ok, value = pcall(function() return object:GetAddress() end)
    local id = (ok and tostring(value) or "?") .. "|" .. full(object)
    identity_cache[object] = id
    return id
end
local function unwrap(parameter)
    local ok, value = pcall(function() return parameter:get() end)
    if ok then return value end
    return parameter
end
local function is_gameplay(object)
    if not valid(object) then return false end
    local name = full(object):lower()
    return name:find(":persistentlevel.", 1, true) ~= nil
        and name:find("default__", 1, true) == nil
        and name:find("/mainmenu/", 1, true) == nil
        and name:find("pre-menulevel", 1, true) == nil
end
local CLASS = {
    player = "BP_NMCharacter_Player_C",
    train = "PlayerTrain_C",
    charles = "CharlesCharacter_C",
}
local CLASSPATH = {
    player = "/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter_Player.BP_NMCharacter_Player_C",
    train = "/Game/_GAME/Blueprints/TrainBlueprints/PlayerTrain.PlayerTrain_C",
    charles = "/Game/_GAME/Blueprints/TrainBlueprints/CharlesCharacter.CharlesCharacter_C",
}
local function matches(object, kind)
    if not valid(object) then return false end
    local ok, value = pcall(function() return object:IsA(CLASSPATH[kind]) end)
    if ok and value == true then return true end
    local got, class = pcall(function() return object:GetClass() end)
    if not got then return false end
    for _ = 1, 8 do
        if not valid(class) then break end
        local named, name = pcall(function() return class:GetFName():ToString() end)
        if named and name == CLASS[kind] then return true end
        local parent, next_class = pcall(function() return class:GetSuperStruct() end)
        if not parent then break end
        class = next_class
    end
    return false
end
local function world_of(object)
    local ok, world = pcall(function() return object:GetWorld() end)
    if ok and valid(world) then return identity(world) end
    return full(object):match("^[^ ]+ (.-):")
end
local function all(class_name)
    counters.global_searches = counters.global_searches + 1
    local ok, objects = pcall(function() return FindAllOf(class_name) end)
    return ok and type(objects) == "table" and objects or {}
end

local state = {
    ticks = 0, controller = nil, world = nil, needs_scan = true,
    snapshot_at = nil, snapshot_notice_until = 0, last_error = nil,
    last_status = nil, active = false, manual_snapshots = 0,
    train_watch = {}, train_id = nil,
    heat_scheduled = false, heat_bind_pending = false, hud_dirty = true,
    guard_force = false, flush_pending = false,
}
local reflection = Diagnostics.new({emit = function(line) append("CCC_Reflection.log", line) end,
    is_gameplay = is_gameplay})
local core = Core.new({read = read, write = write, valid = valid, identity = identity,
    log = log, event = function(line)
        log(line)
        append("CCC_Events.log", line)
        state.snapshot_at = state.ticks + 1
    end})
local noheat = NoHeat.new({read = read, write = write, valid = valid, identity = identity,
    log = function(message) log("NOHEAT " .. tostring(message)) end})
local playerguard = PlayerGuard.new({script_dir = script_dir, valid = valid, log = log})
local function modes_view()
    local view = core:view()
    local guard = playerguard:view()
    view.player.ready = view.player.ready and guard.ready
    view.player.restoring = view.player.restoring or guard.restoring
    view.noheat = noheat:view()
    return view
end
local hud = HUD.new({log = log, is_valid = valid, get_controller = function() return state.controller end,
    get_context_key = function() return state.world end, read_property = read,
    get_view = function()
        local view = modes_view()
        if state.ticks < state.snapshot_notice_until then view.snapshot_notice = "Snapshot saved" end
        return view
    end})

local engine_cache
local function pick_controller(force_discovery)
    local preferred_world
    if not valid(engine_cache) then
        counters.global_searches = counters.global_searches + 1
        local ok, engine = pcall(function() return FindFirstOf("Engine") end)
        engine_cache = ok and engine or nil
    end
    if valid(engine_cache) then
        local viewport = read(engine_cache, "GameViewport")
        if valid(viewport) then preferred_world = world_of(viewport) end
    end
    -- A retained local controller in the viewport's current world is already
    -- the desired instance. Do not walk the global object array twice/second.
    -- Construction/BeginPlay notifications and world changes bypass this path.
    local retained = state.controller
    if not force_discovery and preferred_world and valid(retained)
        and world_of(retained) == preferred_world then
        local ok, is_local = pcall(function() return retained:IsLocalPlayerController() end)
        if not ok then ok, is_local = pcall(function() return retained:IsLocalController() end) end
        if ok and is_local == true then return retained end
    end
    local candidates = {}
    for _, controller in ipairs(all("PlayerController")) do
        if valid(controller) and not full(controller):find("Default__", 1, true) then
            local local_ok, is_local = pcall(function() return controller:IsLocalPlayerController() end)
            if not local_ok then local_ok, is_local = pcall(function() return controller:IsLocalController() end) end
            if local_ok and is_local == true then
                if preferred_world and world_of(controller) == preferred_world then return controller end
                candidates[#candidates + 1] = controller
            end
        end
    end
    if #candidates == 1 then return candidates[1] end
    -- Ambiguous old/new worlds: wait for travel to settle instead of patching
    -- an arbitrary FindFirstOf instance in the menu or previous level.
end
local function choose(kind, reference, world)
    if is_gameplay(reference) and matches(reference, kind) and world_of(reference) == world then return reference end
    local candidates = {}
    for _, object in ipairs(all(CLASS[kind])) do
        if is_gameplay(object) and matches(object, kind) and world_of(object) == world then
            candidates[#candidates + 1] = object
        end
    end
    if #candidates == 1 then return candidates[1] end
end
local function scan()
    new_pass()
    counters.scans = counters.scans + 1
    local controller = pick_controller(state.needs_scan)
    state.controller = controller
    state.world = valid(controller) and world_of(controller) or nil
    local actors = {}
    if state.world then
        actors.player = choose("player", read(controller, "Pawn"), state.world)
        actors.train = choose("train", read(actors.player, "Train Ref"), state.world)
        actors.charles = choose("charles", read(actors.player, "Charles Ref"), state.world)
    end
    local changed = false
    local train_changed = identity(actors.train) ~= identity(core.actors.train)
    for _, kind in ipairs({"player", "train", "charles"}) do
        if identity(actors[kind]) ~= identity(core.actors[kind]) then changed = true end
    end
    core:set_actors(actors)
    noheat:set_train(actors.train)
    if train_changed then state.heat_bind_pending = true end
    state.needs_scan = false
    if changed then
        state.guard_force, state.hud_dirty = true, true
        state.flush_pending = true
        state.snapshot_at = state.ticks + 20
        for _, kind in ipairs({"player", "train", "charles"}) do
            if valid(actors[kind]) then log("ACTOR " .. kind .. " " .. full(actors[kind])) end
        end
    end
end

local function snapshot(label)
    counters.full_snapshots = counters.full_snapshots + 1
    local modes = {version = VERSION, player = core.enabled.player, train = core.enabled.train,
        double = core.enabled.double, player_ready = core.ready.player and playerguard.ready, train_ready = core.ready.train,
        double_ready = core.ready.double, player_nightmare = read(core.actors.player, "NightmareMode"),
        charles_nightmare = read(core.actors.charles, "NightmareMode"),
        noheat_enabled = noheat.enabled, noheat_ready = noheat.ready}
    local ok, id = reflection:snapshot(label, core.actors, modes)
    if ok then
        log("SNAPSHOT " .. label .. " " .. tostring(id))
        for key, value in pairs(playerguard:snapshot()) do
            append("CCC_Events.log", "PLAYERGUARD SNAPSHOT " .. tostring(key) .. "=" .. tostring(value))
        end
        local heat = noheat:snapshot()
        -- Supplemental heat status is kept even if a broader reflection dump
        -- hits its size bound. Never pretend a name candidate is a bound field.
        for key, value in pairs(heat or {}) do
            if type(value) ~= "table" then
                append("CCC_Events.log", "NOHEAT SNAPSHOT " .. tostring(key) .. "=" .. tostring(value))
            else
                for _, field in ipairs(value) do
                    if type(field) == "table" then
                        append("CCC_Events.log", "NOHEAT SNAPSHOT " .. tostring(key) .. " " .. tostring(field.name)
                            .. " type=" .. tostring(field.type) .. " value=" .. tostring(field.value))
                    end
                end
            end
        end
    else
        log("SNAPSHOT skipped: enter a gameplay level first (" .. tostring(id) .. ")")
    end
    return ok
end

-- Read-only train health discovery. Every reflected property is considered,
-- including those beyond the old 250-property truncation. No guessed HP writes.
local function watch_train()
    local object = core.actors.train
    if not valid(object) then state.train_id = nil; state.train_watch = {}; return end
    local current_id = identity(object)
    if state.train_id ~= current_id then
        state.train_id, state.train_watch = current_id, {}
        local ok, class = pcall(function() return object:GetClass() end)
        if ok and valid(class) then
            pcall(function() class:ForEachProperty(function(property)
                local name = property:GetFName():ToString()
                local lower = name:lower()
                if lower:find("health", 1, true) or lower == "hp" or lower == "_hp" then
                    local value = read(object, name)
                    if type(value) == "number" then state.train_watch[name] = value end
                end
            end) end)
        end
    end
    for name, old in pairs(state.train_watch) do
        local value = read(object, name)
        if type(value) == "number" and value ~= old then
            append("CCC_Events.log", "TRAIN HEALTH field=" .. string.format("%q", name)
                .. " old=" .. tostring(old) .. " new=" .. tostring(value)
                .. " train_enabled=" .. tostring(core.enabled.train))
            if value < old and core.enabled.train then
                -- Conservative warning; diagnostics explicitly name the field.
                core:mark_breach("train", "reflected health candidate " .. name .. " decreased: " .. old .. " -> " .. value)
            end
            state.train_watch[name] = value
        end
    end
end

local hook_ids, hook_counts = {}, {}
local bp_hooks = {
    {kind = "player", path = "/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C:Damage"},
    {kind = "player", path = "/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C:ReceiveAnyDamage"},
    {kind = "train", path = "/Game/_GAME/Blueprints/TrainBlueprints/PlayerTrain.PlayerTrain_C:Damage Train"},
    {kind = "charles", path = "/Game/_GAME/Blueprints/TrainBlueprints/CharlesCharacter.CharlesCharacter_C:Damage"},
}
local function install_bp_observers()
    if type(RegisterHook) ~= "function" then return end
    for _, specification in ipairs(bp_hooks) do
        local spec = specification
        if not hook_ids[spec.path] then
            local got, fn = pcall(function() return StaticFindObject(spec.path) end)
            if got and valid(fn) then
                local ok, pre, post = pcall(RegisterHook, spec.path, function(context, ...)
                    local object = unwrap(context)
                    if not is_gameplay(object) or identity(object) ~= identity(core.actors[spec.kind]) then return end
                    local arguments = table.pack(...)
                    local called, err = pcall(function()
                        hook_counts[spec.path] = (hook_counts[spec.path] or 0) + 1
                        counters.damage_events = counters.damage_events + 1
                        local count = hook_counts[spec.path]
                        if spec.kind == "player" and count == 1 then
                            state.snapshot_at = state.ticks + 1
                            append("CCC_Events.log", "PLAYER DAMAGE OBSERVED guard_ready=" .. tostring(playerguard.ready))
                        end
                        if spec.kind ~= "charles" or count <= 16 or count % 25 == 0 then
                            -- Keep scalar evidence without walking properties or
                            -- writing dozens of lines inside each damage call.
                            local parts = {"DAMAGE POST kind=" .. spec.kind, "count=" .. count,
                                "function=" .. string.format("%q", spec.path)}
                            for index = 1, math.min(8, arguments.n) do
                                local value = unwrap(arguments[index])
                                local kind = type(value)
                                if kind == "number" or kind == "boolean" or kind == "nil" then
                                    parts[#parts + 1] = "arg" .. index .. "=" .. tostring(value)
                                else
                                    parts[#parts + 1] = "arg" .. index .. "=<" .. kind .. ">"
                                end
                            end
                            append("CCC_Events.log", table.concat(parts, " "))
                        end
                        -- POST: observe first. Never install/remove the native
                        -- entry guard from inside the function being guarded.
                        -- It is maintained at timer/key/BeginPlay safe points.
                        core:refresh("Blueprint damage POST")
                        state.hud_dirty = true
                    end)
                    if not called then log("POST OBSERVER ERROR " .. tostring(err)) end
                end)
                if ok then
                    hook_ids[spec.path] = {pre, post}
                    log("POST OBSERVER installed " .. spec.path)
                else
                    log("POST OBSERVER unavailable " .. spec.path .. " " .. tostring(pre))
                    -- Retry only on the slow scan cadence.
                end
            end
        end
    end
end
local function install_native_guard(path)
    if type(RegisterHook) ~= "function" then return end
    local ok, pre, post = pcall(RegisterHook, path, function(_, target_parameter, damage_parameter)
        local target = unwrap(target_parameter)
        for _, kind in ipairs({"player", "train"}) do
            if core.enabled[kind] and valid(target) and identity(target) == identity(core.actors[kind]) then
                local good, err = pcall(function()
                    local original = damage_parameter:get()
                    if type(original) == "number" and original > 0 then
                        damage_parameter:set(0)
                        if damage_parameter:get() ~= 0 then error("parameter readback was not zero") end
                        hook_counts[path] = (hook_counts[path] or 0) + 1
                        local count = hook_counts[path]
                        if count <= 12 or count % 50 == 0 then
                            append("CCC_Events.log", "NATIVE PRE BLOCK " .. kind .. " " .. path .. " incoming=" .. original .. " count=" .. count)
                        end
                    end
                end)
                if not good then log("NATIVE GUARD ERROR " .. tostring(err)) end
                return -- No return-value override or claim of Blueprint cancellation.
            end
        end
    end)
    if ok then hook_ids[path] = {pre, post}; log("NATIVE PRE GUARD installed " .. path)
    else log("NATIVE PRE GUARD unavailable " .. path .. " " .. tostring(pre)) end
end

local function status_line()
    local parts = {}
    local view = modes_view()
    for _, mode in ipairs({"player", "train", "double"}) do
        parts[#parts + 1] = mode .. "=" .. (core.enabled[mode] and "ON" or "OFF") .. "/ready=" .. tostring(view[mode].ready)
    end
    parts[#parts + 1] = "noheat=" .. (noheat.enabled and "ON" or "OFF") .. "/ready=" .. tostring(noheat.ready)
    return table.concat(parts, " ")
end
local function compact_snapshot(label)
    counters.compact_snapshots = counters.compact_snapshots + 1
    append("CCC_Events.log", "COMPACT " .. label .. " version=" .. VERSION .. " " .. status_line()
        .. " player_nightmare=" .. tostring(read(core.actors.player, "NightmareMode"))
        .. " charles_nightmare=" .. tostring(read(core.actors.charles, "NightmareMode")))
    local guard = playerguard:snapshot()
    append("CCC_Events.log", "PERF COUNTS (not FPS) steps=" .. counters.steps
        .. " heat_steps=" .. counters.heat_steps .. " scans=" .. counters.scans
        .. " global_searches=" .. counters.global_searches .. " full_names=" .. counters.full_names
        .. " identity_cache_hits=" .. counters.identity_cache_hits
        .. " full_snapshots=" .. counters.full_snapshots .. " compact_snapshots=" .. counters.compact_snapshots
        .. " damage_events=" .. counters.damage_events
        .. " guard_enable=" .. tostring(guard.native_enable_calls)
        .. " guard_check=" .. tostring(guard.native_check_calls)
        .. " guard_cached=" .. tostring(guard.cached_refreshes)
        .. " guard_failures=" .. tostring(guard.native_failures)
        .. " heat_checks=" .. tostring(noheat.checks) .. " heat_clears=" .. tostring(noheat.clears))
    local stats = logger:snapshot()
    local parts = {"LOG COUNTS"}
    local keys = {}
    for key, value in pairs(stats) do if type(value) ~= "table" then keys[#keys + 1] = key end end
    table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. tostring(stats[key]) end
    append("CCC_Events.log", table.concat(parts, " "))
end
local heat_running, heat_error = false, nil
local function heat_step()
    if heat_running then return end
    heat_running = true
    counters.heat_steps = counters.heat_steps + 1
    state.heat_bind_pending = false
    local ok, err = pcall(function() noheat:refresh() end)
    heat_running = false
    if not ok then
        noheat.ready = false
        if tostring(err) ~= heat_error then
            heat_error = tostring(err)
            log("NOHEAT ERROR " .. heat_error)
        end
    else
        heat_error = nil
    end
end
local function step()
    if state.active then return end
    state.active = true
    local ok, err = pcall(function()
        new_pass()
        state.ticks = state.ticks + 1
        counters.steps = counters.steps + 1
        if state.needs_scan or state.ticks % 10 == 1 then scan() end
        playerguard:refresh(core.actors.player, core.enabled.player, state.guard_force)
        state.guard_force = false
        core:refresh("50ms poll")
        if not state.heat_scheduled or state.heat_bind_pending then heat_step() end
        watch_train()
        if state.ticks % 20 == 1 then install_bp_observers() end
        if state.snapshot_at and state.ticks >= state.snapshot_at then
            state.snapshot_at = nil
            compact_snapshot("automatic-bind-or-protection-gap")
        end
        if state.hud_dirty or state.ticks % 4 == 1 then
            hud:update()
            state.hud_dirty = false
            local line = status_line()
            if line ~= state.last_status then log("STATUS " .. line); state.last_status = line end
        end
        if state.ticks % 600 == 0 then compact_snapshot("periodic-performance") end
        if state.flush_pending or state.ticks % 20 == 0 then
            logger:flush()
            state.flush_pending = false
        end
        state.last_error = nil
    end)
    state.active = false
    if not ok and tostring(err) ~= state.last_error then
        state.last_error = tostring(err)
        core.ready.player, core.ready.train, core.ready.double = false, false, false
        log("LOOP ERROR " .. state.last_error)
        pcall(function() hud:update() end)
        logger:flush()
    end
end
local function bind(key_name, callback)
    if type(RegisterKeyBind) ~= "function" or not Key or not Key[key_name] then
        log("KEY ERROR " .. key_name .. " unavailable")
        return
    end
    local ok, err = pcall(RegisterKeyBind, Key[key_name], function()
        local queued, why = pcall(function()
            ExecuteInGameThread(function()
                log("KEY " .. key_name)
                local called, failure = pcall(callback)
                if not called then log("KEY ERROR " .. key_name .. " " .. tostring(failure)) end
                logger:flush()
            end)
        end)
        -- A failed queue can leave this callback on the input thread. Keep
        -- that rare error in UE4SS's console log without touching our buffers.
        if not queued then print("[CCC-GODMOD] KEY QUEUE ERROR " .. key_name .. " " .. tostring(why) .. "\n") end
    end)
    if not ok then log("BIND ERROR " .. key_name .. " " .. tostring(err)) end
end
local function toggle(mode)
    scan()
    core:set_enabled(mode, not core.enabled[mode])
    playerguard:refresh(core.actors.player, core.enabled.player)
    hud:update()
    append("CCC_Events.log", "KEY TOGGLE " .. mode .. "=" .. tostring(core.enabled[mode]))
end

log("SESSION START Choo-Choo Charles " .. VERSION)
log("F6 God Mode | F7 Train God Mode | F8 Double Damage | F9 Snapshot | F10 No Overheat | F11 Hide/show HUD. No Ctrl modifier.")
log("v0.6 performance update: retained guard, cached discovery, compact automatic diagnostics and batched log writes.")
log("v0.5 No Overheat and NPC protection were user-confirmed. This build preserves those gameplay mechanisms.")
log("Player readiness requires the custom Damage entry guard as well as the existing source protections.")
install_native_guard("/Script/Engine.GameplayStatics:ApplyDamage")
install_native_guard("/Script/Engine.GameplayStatics:ApplyPointDamage")
bind("F6", function() toggle("player") end)
bind("F7", function() toggle("train") end)
bind("F8", function() toggle("double") end)
bind("F9", function()
    scan(); playerguard:refresh(core.actors.player, core.enabled.player, true); core:refresh("F9"); heat_step()
    state.guard_force = false
    state.manual_snapshots = state.manual_snapshots + 1
    if snapshot("F9-" .. state.manual_snapshots) then state.snapshot_notice_until = state.ticks + 60 end
    compact_snapshot("F9-performance")
    hud:update()
end)
bind("F10", function()
    scan()
    noheat:set_enabled(not noheat.enabled)
    heat_step()
    hud:update()
    append("CCC_Events.log", "KEY TOGGLE noheat=" .. tostring(noheat.enabled))
end)
bind("F11", function() hud:set_visible(not hud:is_visible()); log("HUD visible=" .. tostring(hud:is_visible())) end)

-- Construct notifications only request a rescan: Blueprint defaults and save
-- state may not be initialized at that moment. BeginPlay applies after setup.
if type(NotifyOnNewObject) == "function" then
    for _, path in pairs(CLASSPATH) do
        pcall(NotifyOnNewObject, path, function() state.needs_scan = true end)
    end
end
if type(RegisterBeginPlayPostHook) == "function" then
    local ok, err = pcall(RegisterBeginPlayPostHook, function(context)
        local object = unwrap(context)
        if is_gameplay(object) and (matches(object, "player") or matches(object, "train") or matches(object, "charles")) then
            state.needs_scan = true
            state.guard_force = true
            step()
        end
    end)
    if not ok then log("BeginPlay observer unavailable " .. tostring(err)) end
end
local scheduled = false
if type(LoopInGameThreadWithDelay) == "function" then
    local ok, handle = pcall(LoopInGameThreadWithDelay, 50, step)
    scheduled = ok
    if ok then state.timer = handle else log("Game-thread timer failed " .. tostring(handle)) end
end
if not scheduled and type(LoopAsync) == "function" and type(ExecuteInGameThread) == "function" then
    local pending = false
    local ok, err = pcall(LoopAsync, 50, function()
        if not pending then
            pending = true
            local queued = pcall(ExecuteInGameThread, function() step(); pending = false end)
            if not queued then pending = false end
        end
        return false -- Legacy LoopAsync: false continues, true stops.
    end)
    scheduled = ok
    if not ok then log("Legacy timer failed " .. tostring(err)) end
end
if not scheduled then log("FATAL: no supported game-thread scheduler. Modes are NOT READY.") end

-- Heat maintenance is independent of the established 50 ms protection loop.
-- A 16 ms game-thread timer clears supported heat state before it accumulates.
local heat_scheduled = false
if type(LoopInGameThreadWithDelay) == "function" then
    local ok, handle = pcall(LoopInGameThreadWithDelay, 16, heat_step)
    if ok then state.heat_timer = handle; heat_scheduled = true
    else log("NOHEAT timer unavailable " .. tostring(handle)) end
end
if not heat_scheduled and type(LoopAsync) == "function" and type(ExecuteInGameThread) == "function" then
    local pending = false
    local ok, err = pcall(LoopAsync, 16, function()
        if not pending then
            pending = true
            local queued = pcall(ExecuteInGameThread, function() heat_step(); pending = false end)
            if not queued then pending = false end
        end
        return false
    end)
    heat_scheduled = ok
    if not ok then log("NOHEAT legacy timer unavailable " .. tostring(err)) end
end
if not heat_scheduled then log("NOHEAT using the existing 50 ms game-thread maintenance loop") end
state.heat_scheduled = heat_scheduled
logger:flush()

-- Returned only for the isolated regression harness; UE4SS ignores this value.
return {core = core, noheat = noheat, playerguard = playerguard, state = state, hud = hud,
    step = step, heat_step = heat_step, scan = scan, snapshot = snapshot, modes_view = modes_view,
    logger = logger, counters = counters, compact_snapshot = compact_snapshot}
