-- v0.6: keep the working cave NPC guard armed without reapplying it 20x/sec.
-- Blueprint RegisterHook is POST; it cannot cancel a lethal Blueprint body.
-- This companion uses the installed UE4SS's exported accessors to suppress
-- only BP_NMCharacter:Damage in memory, with ownership-checked OFF restoration.
-- Invoke refresh only at game-thread safe points, never from Damage POST.
local PlayerGuard = {}
local TARGET = "/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C:Damage"
local PLAYER = "/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter_Player.BP_NMCharacter_Player_C"
-- The native patch persists between calls. Routine refreshes run every 50 ms;
-- an owned, verified guard needs one ownership readback per twenty refreshes.
-- Activation, player changes, explicit checks and OFF never wait for this.
local VERIFY_EVERY = 20
local ERRORS = {
    [0] = "ready", [1] = "player Damage function not loaded", [2] = "required UE4SS exports unavailable",
    [3] = "unexpected Damage function signature", [4] = "unexpected Blueprint bytecode layout",
    [5] = "runtime memory validation failed", [6] = "another change conflicts with the owned guard",
    [7] = "wrong thread", [8] = "native accessor exception", [9] = "guard readback was not active",
}
-- A Lua C function can return its existing argument values. The helper returns
-- only their count, so it neither imports Lua nor accesses lua_State internals.
local function invoke(fn)
    return select("#", fn(false,false,false,false,false,false,false,false,
        false,false,false,false,false,false,false,false))
end
function PlayerGuard.new(deps)
    local self = {enabled = true, ready = false, armed = false, restoring = false,
        status = "waiting for player", last_code = nil, schema_id = nil, schema_ok = false,
        player_id = nil, remaining = 0, refreshes = 0, cached_refreshes = 0,
        schema_lookups = 0, native_enable_calls = 0, native_check_calls = 0,
        native_disable_calls = 0, native_failures = 0}
    local handles, load_error, attempted = nil, nil, false
    local function status(value)
        if self.status ~= value then
            self.status = value
            deps.log("PLAYERGUARD " .. value)
        end
    end
    local function compatible()
        local ok, major, minor, patch = pcall(function() return UE4SS.GetVersion() end)
        if not ok or major ~= 4 or minor ~= 0 or patch ~= 0 then
            return false, "requires the UE4SS 4.0.0 ABI verified in this report"
        end
        local engine_ok, equal = pcall(function() return UnrealVersion.IsEqual(4, 26) end)
        if not engine_ok or equal ~= true then return false, "requires the detected Unreal 4.26 build" end
        return true
    end
    local function load()
        if attempted then return handles ~= nil end
        attempted = true
        local supported, why = compatible()
        if not supported then load_error = why; return false end
        local path = deps.script_dir .. "/native/ccc_guard.dll"
        local found = {}
        for _, action in ipairs({"enable", "disable", "check"}) do
            local ok, fn, err = pcall(package.loadlib, path, "ccc_guard_" .. action)
            if not ok or type(fn) ~= "function" then
                load_error = tostring(err or fn or "native companion unavailable")
                return false
            end
            found[action] = fn
        end
        handles = found
        return true
    end
    local function call(action)
        local counter = "native_" .. action .. "_calls"
        self[counter] = self[counter] + 1
        local ok, code = pcall(invoke, handles[action])
        if not ok or type(code) ~= "number" or ERRORS[code] == nil then
            self.last_code = -1
            self.native_failures = self.native_failures + 1
            return false, "native bridge failed: " .. tostring(code)
        end
        self.last_code = code
        if code ~= 0 then self.native_failures = self.native_failures + 1 end
        return code == 0, ERRORS[code]
    end
    local function schema()
        self.schema_lookups = self.schema_lookups + 1
        local ok, fn = pcall(StaticFindObject, TARGET)
        if not ok or not deps.valid(fn) then return false, "waiting for player Damage function" end
        local address_ok, address = pcall(function() return fn:GetAddress() end)
        if address_ok and address == self.schema_id and self.schema_ok then return true end
        self.schema_ok = false
        local fields, count = {}, 0
        local inspected, why = pcall(function()
            assert(fn:GetFullName() == "Function " .. TARGET, "different function path")
            assert((fn:GetFunctionFlags() & 0x00400400) == 0, "expected non-native Blueprint without output parameters")
            fn:ForEachProperty(function(property)
                count = count + 1
                assert(count <= 16, "unexpected function fields")
                local name = property:GetFName():ToString()
                local kind = property:GetClass():GetFName():ToString()
                assert(fields[name] == nil, "duplicate field")
                fields[name] = kind
                -- nil continues, including UE4SS 4.0 iterator stack behavior.
            end)
            assert(count == 3 and fields["Damage Applied"] == "FloatProperty"
                and fields["Slowing Multiplier"] == "FloatProperty"
                and fields["Hit Component"] == "ObjectProperty", "unexpected Damage fields")
        end)
        if not inspected then return false, "Damage schema rejected: " .. tostring(why) end
        self.schema_id, self.schema_ok = address_ok and address or nil, true
        return true
    end
    local function disable()
        self.ready = false
        self.player_id, self.remaining = nil, 0
        self.schema_id, self.schema_ok = nil, false
        if not handles or not self.armed then self.restoring = false; return true end
        local ok, why = call("disable")
        self.restoring = not ok
        if ok then self.armed = false else status("OFF (RESTORING): " .. why) end
        return ok
    end
    function self:refresh(player, enabled, force)
        self.refreshes = self.refreshes + 1
        self.enabled = enabled == true
        if not self.enabled then
            if disable() then status("OFF; original player Damage restored") end
            return
        end
        if not deps.valid(player) then
            if disable() then status("waiting for gameplay player") end
            return
        end
        -- IsValid and a scalar address are enough to identify the same live
        -- actor between readbacks. GetFullName and reflected IsA/schema/native
        -- lookups stay out of the ordinary 50 ms path. If identity cannot be
        -- read, use the fully validated path rather than trusting a cache.
        local address_ok, address = pcall(function() return player:GetAddress() end)
        local player_id = address_ok and type(address) == "number" and address ~= 0 and address or nil
        local same_player = player_id ~= nil and player_id == self.player_id
        if self.ready and same_player and not force and self.remaining > 0 then
            self.remaining = self.remaining - 1
            self.cached_refreshes = self.cached_refreshes + 1
            return
        end
        self.ready, self.remaining = false, 0
        self.player_id = player_id
        if not same_player then self.schema_id, self.schema_ok = nil, false end
        local got, matches = pcall(function() return player:IsA(PLAYER) end)
        if not got or not matches then
            disable(); status("NOT READY: unexpected player class"); return
        end
        if not load() then status("NOT READY: " .. tostring(load_error)); return end
        local supported, why = schema()
        if not supported then disable(); status("NOT READY: " .. why); return end
        -- check is read-only and validates ownership, bytecode and the event
        -- pointer in the unchanged native companion. It is sufficient while
        -- armed; enable is only needed for activation or recovery/rebinding.
        local ok, reason = false, nil
        if self.armed and not self.restoring then
            ok, reason = call("check")
        end
        if not ok then
            -- An error can occur after the companion captured/changed part of
            -- its owned state. Preserve cleanup intent before that boundary.
            self.armed = true
            ok, reason = call("enable")
            if not ok then status("NOT READY: " .. reason); return end
            ok, reason = call("check")
            if not ok then status("NOT READY: " .. reason); return end
        end
        self.ready, self.restoring = true, false
        self.remaining = VERIFY_EVERY - 1
        status("READY; custom player Damage body blocked before execution")
    end
    function self:view()
        return {enabled = self.enabled, ready = self.ready, restoring = self.restoring, status = self.status}
    end
    function self:snapshot()
        return {enabled = self.enabled, ready = self.ready, armed = self.armed,
            restoring = self.restoring, status = self.status, target = TARGET,
            native_code = self.last_code, schema_verified = self.schema_ok,
            verification_interval_refreshes = VERIFY_EVERY, refreshes = self.refreshes,
            cached_refreshes = self.cached_refreshes, schema_lookups = self.schema_lookups,
            native_enable_calls = self.native_enable_calls, native_check_calls = self.native_check_calls,
            native_disable_calls = self.native_disable_calls, native_failures = self.native_failures}
    end
    return self
end
return PlayerGuard
