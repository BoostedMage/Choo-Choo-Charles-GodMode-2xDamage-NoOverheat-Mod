-- Choo-Choo Charles v0.5.0: the actual PlayerTrain weapon jamming state.
-- Exact names/types below were observed in the user's v0.4 runtime report,
-- CCC_Reflection.log lines 1317-1329. Machine Gun Jamming also changed while
-- playing (including small negative values from the game's cooling step).
-- Bind only this evidenced schema; a generic word such as "Overheat" is not
-- sufficient. Readiness requires all three counter/latch pairs and verified
-- writes. Thresholds are read-only diagnostics. OFF stops cooling and never
-- restores old heat. Fire rates, shooting flags and visuals are not changed.
-- All methods must be called from the game thread.

local NoHeat = {}
local TRAIN_PATH = "/Game/_GAME/Blueprints/TrainBlueprints/PlayerTrain.PlayerTrain_C"

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function normalized(name)
    return tostring(name):lower():gsub("[^a-z0-9]", "")
end

local function safe_name(object)
    local ok, name = pcall(function() return object:GetFName():ToString() end)
    return ok and type(name) == "string" and name or nil
end

local function safe_full(object)
    local ok, name = pcall(function() return object:GetFullName() end)
    return ok and type(name) == "string" and name or nil
end

local function property_type(property)
    -- FFieldClass is not a UObject; do not call IsValid on this wrapper.
    local ok, name = pcall(function() return property:GetClass():GetFName():ToString() end)
    return ok and type(name) == "string" and name or nil
end

local schema, required_fields = {}, {}
for _, weapon in ipairs({
    {"Machine Gun", "machinegun"},
    {"Range Gun", "rangegun"},
    {"Flamethrower", "flamethrower"},
}) do
    for _, state in ipairs({
        {" Jamming", "counter", "FloatProperty", true},
        {" Jammed", "latch", "BoolProperty", true},
        -- The spelling THRESHHOLD is the actual reflected property name.
        {" Jam THRESHHOLD", "threshold", "FloatProperty", false},
    }) do
        local raw = weapon[1] .. state[1]
        schema[raw] = {role=state[2], type=state[3], scope=weapon[2]}
        if state[4] then required_fields[#required_fields+1]=raw end
    end
end

local function classify(raw_name, kind)
    local expected = schema[raw_name]
    if expected then
        if kind ~= expected.type then
            return "mismatch", expected.scope, "expected " .. expected.type .. " from observed PlayerTrain schema"
        end
        return expected.role, expected.scope,
            expected.role == "threshold" and "read-only jamming threshold" or nil
    end
    local name = normalized(raw_name)
    if not (name:find("heat", 1, true) or name:find("jam", 1, true)) then return nil end
    return "ignored", nil, "not in the observed PlayerTrain jamming schema; read-only"
end

function NoHeat.new(deps)
    assert(type(deps) == "table" and type(deps.read) == "function" and type(deps.write) == "function")
    assert(type(deps.valid) == "function", "noheat requires valid(object)")
    local log = deps.log or function() end
    local identity = deps.identity or tostring
    local self = {enabled=true, ready=false, train=nil, counters={}, latches={}, thresholds={}, candidates={},
        status="WAITING FOR TRAIN", clears=0, latch_clears=0, heat_events=0, jam_events=0,
        checks=0, discoveries=0,
        schema_ok=false, discovered=false}
    local train_id, last_status, retry_after = nil, nil, 0

    local function valid(object)
        local ok, value = pcall(deps.valid, object)
        return ok and value == true
    end
    local function read(object, name)
        local ok, value = pcall(deps.read, object, name)
        if ok then return true, value end
        return false, nil
    end
    local function set_status(status)
        self.status = status
        if status ~= last_status then log("NO HEAT " .. status); last_status = status end
    end
    local function checked_clear(field, value)
        local ok, result = pcall(deps.write, self.train, field.name, value)
        if not ok or result == false then return false end
        local read_ok, actual = read(self.train, field.name)
        if not read_ok or type(actual) ~= type(value) then return false end
        return actual == value
    end

    local function discover()
        self.discoveries = self.discoveries + 1
        self.counters, self.latches, self.thresholds, self.candidates = {}, {}, {}, {}
        self.schema_ok, self.discovered = false, false
        local ok, class = pcall(function() return self.train:GetClass() end)
        if not ok or not valid(class) then set_status("NOT READY: train class unavailable"); return end
        local classes, found_train, seen = {}, false, {}
        for _ = 1, 10 do
            if not valid(class) then break end
            local name, full = safe_name(class), safe_full(class)
            local class_path = full and (full:match("^%S+%s+(.+)$") or full)
            if name == "PlayerTrain_C" and class_path == TRAIN_PATH then
                found_train = true
                classes[#classes + 1] = class
                break
            end
            if not full or full:find("/Script/", 1, true) then break end
            if seen[full] then break end
            seen[full] = true
            classes[#classes + 1] = class
            local got, parent = pcall(function() return class:GetSuperStruct() end)
            if not got then break end
            class = parent
        end
        if not found_train then set_status("NOT READY: object is not the PlayerTrain Blueprint"); self.discovered=true; return end
        local properties, complete = 0, true
        local names, bound = {}, {}
        for _, owner_class in ipairs(classes) do
            local enumerated, err = pcall(function()
                owner_class:ForEachProperty(function(property)
                    properties = properties + 1
                    if properties > 4096 then complete=false; return true end
                    local name = safe_name(property)
                    if name and not names[name] then
                        names[name] = true
                        local kind = property_type(property)
                        local role, scope, reason = classify(name, kind)
                        if role then
                            local got, value = read(self.train, name)
                            local field = {name=name, type=kind or "unavailable", scope=scope,
                                role=role, reason=reason, last_read=nil, clears=0, verified=false}
                            -- Preserve false without and/or conversion.
                            if got then field.initial_value=value end
                            self.candidates[#self.candidates + 1] = field
                            if role == "counter" then
                                self.counters[#self.counters + 1] = field
                                bound[name] = true
                            elseif role == "latch" then self.latches[#self.latches + 1] = field
                                bound[name] = true
                            elseif role == "threshold" then self.thresholds[#self.thresholds + 1] = field end
                        end
                    end
                    -- UE4SS v4 ForEachProperty has a stack bug for false.
                    -- Continue with no return value; return true only to stop.
                end)
            end)
            if not enumerated then
                complete = false
                log("NO HEAT metadata error: " .. tostring(err))
                break
            end
        end
        local function by_name(a,b) return a.name < b.name end
        table.sort(self.candidates, by_name); table.sort(self.counters, by_name)
        table.sort(self.latches, by_name); table.sort(self.thresholds, by_name)
        for _, field in ipairs(self.candidates) do
            log("NO HEAT CANDIDATE " .. string.format("%q", field.name) .. " type=" .. field.type
                .. " role=" .. field.role .. " prevalue=" .. tostring(field.initial_value)
                .. (field.reason and (" reason=" .. field.reason) or ""))
        end
        if not complete then set_status("NOT READY: incomplete reflected metadata"); return end
        self.discovered = true
        local missing = {}
        for _, name in ipairs(required_fields) do
            if not bound[name] then missing[#missing+1] = name end
        end
        if #missing > 0 then
            set_status("NOT READY: missing/wrong-type jamming state [" .. table.concat(missing, ", ") .. "]")
            return
        end
        self.schema_ok = true
        for _, field in ipairs(self.counters) do
            log("NO HEAT BOUND counter " .. string.format("%q", field.name) .. " type=" .. field.type
                .. " scope=" .. field.scope .. " prevalue=" .. tostring(field.initial_value))
        end
        for _, field in ipairs(self.latches) do
            log("NO HEAT BOUND latch " .. string.format("%q", field.name) .. " type=" .. field.type
                .. " scope=" .. field.scope .. " prevalue=" .. tostring(field.initial_value))
        end
    end

    function self:set_train(object)
        if not valid(object) then object=nil end
        local new_id = object and tostring(identity(object)) or nil
        if new_id == train_id and self.train == object then return end
        if new_id == train_id and valid(self.train) then self.train=object; return end
        self.train, train_id = object, new_id
        self.ready, self.schema_ok, self.discovered = false, false, false
        self.counters, self.latches, self.thresholds, self.candidates = {}, {}, {}, {}
        self.clears, self.latch_clears, self.checks = 0, 0, 0
        self.heat_events, self.jam_events = 0, 0
        retry_after = 0
        set_status(object and "WAITING FOR REFLECTED HEAT STATE" or "WAITING FOR TRAIN")
    end

    function self:refresh()
        self.checks = self.checks + 1
        self.ready = false
        if not valid(self.train) then set_status("WAITING FOR TRAIN"); return false end
        if not self.enabled then set_status("OFF"); return false end
        if not self.discovered and self.checks >= retry_after then
            discover()
            retry_after = self.checks + 60
        end
        if not self.schema_ok then return false end
        -- Preflight every bound value before changing anything. An invalid
        -- counter or latch cannot partially enable an ambiguous schema.
        for _, field in ipairs(self.counters) do
            local ok, value = read(self.train, field.name)
            field.last_read = value
            -- The game's own cooling step crosses slightly below zero; this
            -- is observed runtime state, not an unsupported negative sentinel.
            if not ok or not finite(value) then
                set_status("NOT READY: nonnumeric/nonfinite counter " .. field.name)
                return false
            end
        end
        for _, field in ipairs(self.latches) do
            local ok, value = read(self.train, field.name)
            field.last_read = value
            if not ok or type(value) ~= "boolean" then
                set_status("NOT READY: nonboolean latch " .. field.name)
                return false
            end
        end
        local failed = {}
        for _, field in ipairs(self.counters) do
            if field.last_read ~= 0 or not field.verified then
                if checked_clear(field, 0) then
                    self.clears = self.clears + 1; field.clears=field.clears+1; field.verified=true
                    if field.last_read > 0 then self.heat_events=self.heat_events+1 end
                else failed[#failed+1]=field.name end
            end
        end
        if #failed > 0 then
            set_status("NOT READY: heat clear/readback failed [" .. table.concat(failed, ", ") .. "]")
            return false
        end
        for _, field in ipairs(self.latches) do
            if field.last_read == true or not field.verified then
                if checked_clear(field, false) then
                    self.latch_clears = self.latch_clears + 1; field.clears=field.clears+1; field.verified=true
                    if field.last_read == true then self.jam_events=self.jam_events+1 end
                else failed[#failed+1]=field.name end
            end
        end
        if #failed > 0 then
            set_status("NOT READY: jam clear/readback failed [" .. table.concat(failed, ", ") .. "]")
            return false
        end
        self.ready = true
        set_status("ON: verified PlayerTrain jamming counters=" .. #self.counters .. ", latches=" .. #self.latches)
        return true
    end

    function self:set_enabled(value)
        value = value == true
        if self.enabled == value then return end
        self.enabled, self.ready = value, false
        if not value then set_status("OFF"); return end
        self.discovered, self.schema_ok, retry_after = false, false, 0
        set_status("WAITING FOR REFLECTED HEAT STATE")
        self:refresh()
    end

    function self:view()
        return {enabled=self.enabled, ready=self.ready}
    end

    function self:snapshot()
        local result = {enabled=self.enabled, ready=self.ready, train=train_id or "none", status=self.status,
            clears=self.clears, latch_clears=self.latch_clears, checks=self.checks,
            heat_events=self.heat_events, jam_events=self.jam_events,
            discoveries=self.discoveries, schema="PlayerTrain.Jamming.v1",
            counters={}, latches={}, thresholds={}, candidates={}}
        local function copy_fields(source, destination)
            for _, field in ipairs(source) do
                local ok, value = read(self.train, field.name)
                local copy={name=field.name, type=field.type, role=field.role, scope=field.scope,
                    initial_value=field.initial_value, last_read=field.last_read, clears=field.clears, reason=field.reason}
                if ok then copy.value=value else copy.read_error=true end
                destination[#destination+1]=copy
            end
        end
        copy_fields(self.counters, result.counters)
        copy_fields(self.latches, result.latches)
        copy_fields(self.thresholds, result.thresholds)
        copy_fields(self.candidates, result.candidates)
        return result
    end

    return self
end

return NoHeat
