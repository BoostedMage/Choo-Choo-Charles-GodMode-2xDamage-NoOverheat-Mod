-- Choo-Choo Charles v0.3.0: only fields observed in the supplied runtime report.
-- Run all methods on the game thread. This module does not claim to cancel
-- Blueprint damage functions; their UE4SS Lua callbacks run after execution.
local Core = {}

local incoming = {
    player = {"Damage to Player", "Damage to Player on Train"},
    train = {"Damage to Train"},
}
local outgoing = {"Face Damage Multiplier", "Body Damage Multiplier", "Legs Damage Multiplier"}

local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if finite(a) and finite(b) then
        return math.abs(a - b) <= math.max(0.00001, math.abs(b) * 0.00001)
    end
    return a == b
end

function Core.new(deps)
    assert(type(deps) == "table" and type(deps.read) == "function")
    assert(type(deps.write) == "function" and type(deps.valid) == "function")
    local read, write, valid = deps.read, deps.write, deps.valid
    local log = deps.log or function() end
    local event = deps.event or function() end
    local id = deps.identity or tostring
    local self = {
        enabled = {player = true, train = true, double = true},
        ready = {player = false, train = false, double = false},
        breached = {player = false, train = false},
        actors = {player = nil, train = nil, charles = nil},
        records = {}, native = {}, player_hp = nil,
        writes = 0, recoveries = 0,
    }

    local function checked_write(object, name, value)
        local ok, result = pcall(write, object, name, value)
        if not ok or result == false then return false end
        return equal(read(object, name), value)
    end

    local function restore_record(record)
        if not valid(record.object) then return true end
        -- Do not clobber a value the game/another mod changed after our patch.
        if equal(read(record.object, record.name), record.applied) then
            if not checked_write(record.object, record.name, record.baseline) then
                if not record.restore_failed then log("RESTORE FAILED " .. record.name .. " (will retry)") end
                record.restore_failed = true
                return false
            end
            log("RESTORED " .. record.name .. "=" .. tostring(record.baseline))
        end
        return true
    end

    local function clear_mode_records(mode)
        for key, record in pairs(self.records) do
            if record.mode == mode then
                if restore_record(record) then self.records[key] = nil end
            end
        end
    end

    local function patch(object, name, mode, transform)
        if not valid(object) then return false end
        local current = read(object, name)
        if not finite(current) or current < 0 then return false end
        local key = tostring(id(object)) .. "|" .. name
        local record = self.records[key]
        if not record then
            record = {object = object, name = name, mode = mode, baseline = current}
            self.records[key] = record
        elseif record.applied == nil then
            -- No write has succeeded yet; initialization may still replace
            -- this field. Only capture a restorable baseline at first success.
            record.baseline = current
        elseif record.applied ~= nil and not equal(current, record.applied) then
            -- Level/difficulty/boss phase may install a fresh unmodified value.
            -- Capture it once; never repeatedly multiply our own output.
            record.baseline = current
            log("GAME VALUE CHANGED " .. name .. "=" .. tostring(current))
        end
        record.retiring = nil
        local target = transform(record.baseline)
        if not finite(target) then return false end
        if record.applied ~= nil and equal(current, target) then return true end
        if not checked_write(object, name, target) then
            if not record.failed then log("WRITE/READBACK FAILED " .. name) end
            record.failed = true
            return false
        end
        record.applied, record.failed = target, false
        self.writes = self.writes + 1
        log("APPLIED " .. mode .. " " .. name .. ": " .. tostring(record.baseline) .. " -> " .. tostring(target))
        return true
    end

    local function restore_native(kind)
        local record = self.native[kind]
        if record and valid(record.object) and type(record.original) == "boolean" then
            if read(record.object, "bCanBeDamaged") == false then
                if not checked_write(record.object, "bCanBeDamaged", record.original) then
                    if not record.restore_failed then log("RESTORE FAILED " .. kind .. ".bCanBeDamaged (will retry)") end
                    record.restore_failed = true
                    return false
                end
            end
        end
        self.native[kind] = nil
        return true
    end

    local function native_guard(kind)
        local object = self.actors[kind]
        if not valid(object) then return false end
        local current = read(object, "bCanBeDamaged")
        if type(current) ~= "boolean" then return false end
        local record = self.native[kind]
        if not record then
            record = {object = object, original = current}
            self.native[kind] = record
        elseif current ~= false then
            record.original = current
        end
        if current == false then return true end
        local ok = checked_write(object, "bCanBeDamaged", false)
        if ok then log("APPLIED " .. kind .. ".bCanBeDamaged=false") end
        return ok
    end

    function self:set_actors(actors)
        for _, kind in ipairs({"player", "train", "charles"}) do
            local old, new = self.actors[kind], actors[kind]
            if not valid(new) then new = nil end
            local same = old == new or (valid(old) and valid(new) and id(old) == id(new))
            if not same then
                if kind == "charles" then
                    for key, record in pairs(self.records) do
                        if restore_record(record) then self.records[key] = nil
                        else record.retiring = true end
                    end
                else
                    if not restore_native(kind) then
                        local record = self.native[kind]
                        local key = tostring(id(record.object)) .. "|bCanBeDamaged"
                        self.records[key] = {object = record.object, name = "bCanBeDamaged", mode = kind,
                            baseline = record.original, applied = false, retiring = true}
                        self.native[kind] = nil
                    end
                    self.breached[kind] = false
                    if kind == "player" then self.player_hp = nil end
                end
                self.actors[kind] = new
                log("BIND " .. kind .. "=" .. (new and tostring(id(new)) or "none"))
            end
        end
    end

    function self:mark_breach(kind, detail)
        if self.enabled[kind] and not self.breached[kind] then
            self.breached[kind] = true
            self.ready[kind] = false
            event("PROTECTION GAP " .. kind .. " " .. tostring(detail))
        end
    end

    function self:guard_player_health(reason)
        local object = self.actors.player
        if not valid(object) then self.player_hp = nil; return false end
        local hp = read(object, "varHealthMain")
        if not finite(hp) then return false end
        local dead = read(object, "Dead?") == true
        if not self.enabled.player then
            self.player_hp = hp > 0 and hp or nil
            return hp > 0 and not dead
        end
        if dead or hp <= 0 then
            if self.player_hp and self.player_hp > 0 then
                self:mark_breach("player", "death/zero health observed; no resurrection attempted")
            end
            self.player_hp = nil
            return false
        end
        if self.player_hp and hp < self.player_hp - 0.001 then
            local before = self.player_hp
            self:mark_breach("player", "varHealthMain " .. tostring(before) .. " -> " .. tostring(hp) .. " (" .. tostring(reason) .. ")")
            -- Recovery is bounded by an actually observed, positive HP value.
            -- Never write huge/infinite HP, revive a dead actor, or guess max HP.
            if checked_write(object, "varHealthMain", before) then
                self.recoveries = self.recoveries + 1
                log("NONLETHAL RECOVERY varHealthMain " .. tostring(hp) .. " -> " .. tostring(before))
                hp = before
            end
        end
        self.player_hp = hp
        return true
    end

    function self:refresh(reason)
        self.ready.player, self.ready.train, self.ready.double = false, false, false
        for key, record in pairs(self.records) do
            if record.retiring or not self.enabled[record.mode] then
                if restore_record(record) then self.records[key] = nil end
            end
        end
        for _, mode in ipairs({"player", "train"}) do
            if not self.enabled[mode] then restore_native(mode) end
        end
        local charles = self.actors.charles
        for _, mode in ipairs({"player", "train"}) do
            if self.enabled[mode] then
                local ready = native_guard(mode)
                for _, name in ipairs(incoming[mode]) do
                    local field_ready = patch(charles, name, mode, function() return 0 end)
                    ready = ready and field_ready
                end
                self.ready[mode] = ready and not self.breached[mode]
            end
        end
        local hp_ready = self:guard_player_health(reason or "poll")
        self.ready.player = self.ready.player and hp_ready and not self.breached.player
        if self.enabled.double then
            local ready = true
            for _, name in ipairs(outgoing) do
                local field_ready = patch(charles, name, "double", function(value) return value * 2 end)
                ready = ready and field_ready
            end
            self.ready.double = ready
        end
    end

    function self:set_enabled(mode, enabled)
        assert(self.enabled[mode] ~= nil, "unknown mode")
        enabled = enabled == true
        if self.enabled[mode] == enabled then return end
        self.enabled[mode] = enabled
        if not enabled then
            clear_mode_records(mode)
            if mode ~= "double" then restore_native(mode) end
        end
        -- A prior observed protection gap remains visible until actor reload;
        -- toggling cannot erase evidence that a damage route bypassed the patch.
        log("TOGGLE " .. mode .. "=" .. (enabled and "ON" or "OFF"))
        self:refresh("toggle")
    end

    function self:view()
        local view = {}
        for _, mode in ipairs({"player", "train", "double"}) do
            view[mode] = {enabled = self.enabled[mode], ready = self.ready[mode]}
            if not self.enabled[mode] then
                for _, record in pairs(self.records) do
                    if record.mode == mode then view[mode].restoring = true end
                end
                if self.native[mode] then view[mode].restoring = true end
            end
        end
        return view
    end

    function self:close()
        for _, mode in ipairs({"player", "train", "double"}) do
            if self.enabled[mode] then self:set_enabled(mode, false) end
        end
    end

    return self
end

return Core
