-- Choo-Choo Charles v0.5.0: read-only, bounded runtime diagnostics.
-- Call from the game thread. This module registers no hooks and changes no game data.
-- A Blueprint RegisterHook callback is post-execution; label events accordingly.
--
-- local d = require("diagnostics").new({emit = append_to_diagnostics_log})
-- d:snapshot("F9", {player = player, train = train, charles = charles}, modes)
-- d:event("player.Damage-post", player, function_path, table.pack(...))
-- d:observe("health-change", player, {old_health=100, new_health=90})
-- d:function_schema(function_path) -- explicit inspection, not interception

local Diagnostics = {}
local Instance = {}
Instance.__index = Instance
local unpack_values = table.unpack or unpack

-- UE4SS v4.0.0 iterator callbacks must return nil to continue, true to stop.
-- LuaUStruct.cpp, LuaTArray.cpp and LuaTMap.cpp (ForEach)
-- call get_bool(2), which removes a boolean result. For false, their else branch
-- removes again and loses the retained callback; the next call then targets nil.
-- Do not replace the no-value returns below with `return false`.
-- Source: RE-UE4SS/v4.0.0, UE4SS/src/LuaType/LuaUStruct.cpp, LuaTArray.cpp and LuaTMap.cpp;
-- deps/first/LuaMadeSimple/src/LuaMadeSimple.cpp, get_bool/discard_value.

local function call(object, method, ...)
    if object == nil then return false, "nil object" end
    local arguments = {n = select("#", ...), ...}
    return pcall(function()
        local fn = object[method]
        if type(fn) ~= "function" then error("method unavailable: " .. method) end
        return fn(object, unpack_values(arguments, 1, arguments.n))
    end)
end

local function valid(object)
    local ok, value = call(object, "IsValid")
    return ok and value == true
end

local function full_name(object)
    local ok, value = call(object, "GetFullName")
    if ok and type(value) == "string" then return value end
    return "<name unavailable>"
end

local function short_name(object)
    -- FProperty::GetClass returns an FFieldClass wrapper, not a UObject.
    -- Do not demand IsValid on the class wrapper before reading its FName.
    local ok, value = call(object, "GetFName")
    if ok then
        local ok_name, name = call(value, "ToString")
        if ok_name and type(name) == "string" then return name end
    end
    return "<name unavailable>"
end

local function identity(object)
    local ok, value = call(object, "GetAddress")
    if ok and value ~= nil then return tostring(value) end
    return full_name(object)
end

local function read_property(object, name)
    -- Only called with names supplied by reflection, never guessed field offsets.
    -- In particular, [] reads mapped UScriptStruct data; its inherited UObject
    -- GetPropertyValue can refer to the metadata wrapper on some versions.
    local ok, value = pcall(function() return object[name] end)
    if ok then return true, value end
    return call(object, "GetPropertyValue", name)
end

local function clean(value, limit)
    local result = tostring(value):gsub("[\r\n\t]", " ")
    if #result > (limit or 220) then return result:sub(1, limit or 220) .. "..." end
    return result
end

local function quote(value)
    return string.format("%q", clean(value, 400))
end

local function scalar(value)
    local kind = type(value)
    if kind == "nil" then return "<nil>" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then return string.format("%.12g", value) end
    if kind == "string" then return quote(value) end
    local ok, wrapper = call(value, "type")
    if valid(value) then
        return "<" .. (ok and tostring(wrapper) or kind) .. " " .. full_name(value) .. ">"
    end
    return "<" .. (ok and tostring(wrapper) or kind) .. ">"
end

local function unpack_parameter(value)
    local ok, wrapper = call(value, "type")
    if ok and (wrapper == "RemoteUnrealParam" or wrapper == "LocalUnrealParam") then
        local got, raw = call(value, "get")
        if not got then got, raw = call(value, "Get") end
        if got then return raw end
    end
    return value
end

local function property_type(property)
    local ok, class = call(property, "GetClass")
    return ok and short_name(class) or "<type unavailable>"
end

local function flag_string(value)
    if type(value) ~= "number" then return "UNAVAILABLE_IN_UE4SS_LUA" end
    local ok, hex = pcall(string.format, "0x%X", value)
    return ok and hex or tostring(value)
end

local function relevant(name)
    local lower = name:lower()
    for _, token in ipairs({"health", "damage", "dead", "death", "dying", "god", "invul",
        "armor", "armour", "nightmare", "difficulty", "stats", "weapon", "gun", "bullet",
        "rocket", "flame", "projectile", "hit", "kill", "respawn", "reset", "fall", "landed", "landing", "water",
        "heat", "jam", "cool"}) do
        if lower:find(token, 1, true) then return true end
    end
    return lower == "hp" or lower == "_hp" or lower == "train ref"
        or lower == "charles ref" or lower == "player ref" or lower:find("save ref", 1, true) ~= nil
        or lower == "svrsubclass" or lower == "keyname"
        or lower == "in train?" or lower == "can move?" or lower == "canjump?"
        or lower == "can shoot?" or lower == "tutorial mode" or lower == "tutorial mode?"
end

local function relevant_function(name)
    local lower = name:lower()
    for _, token in ipairs({"damage", "health", "dead", "death", "die", "kill", "hit", "reset", "respawn", "nightmare",
        "heat", "jam", "cool"}) do
        if lower:find(token, 1, true) then return true end
    end
    return false
end

local function value_priority(path)
    local lower = path:lower()
    if lower:find('["easy save ref"]', 1, true) or lower:find('["svrsubclass"]', 1, true) then return -10 end
    if lower:find("stats", 1, true) or lower:find("health", 1, true) then return 0 end
    if lower:find("damage", 1, true) or lower:find("weapon", 1, true) then return 1 end
    return 2
end

local function save_context(path)
    return value_priority(path) == -10
end

local function save_function(name)
    local lower = name:lower()
    -- Schema inspection only: none of these getters/setters are invoked here.
    return lower == "easyloadvalue" or lower == "easysavevalue"
        or lower:match("^get.*float") ~= nil or lower:match("^set.*float") ~= nil
end

local function nested_priority(entry)
    local priority = value_priority(entry.path)
    if priority < 0 or entry.struct then return priority end
    local ok, class = call(entry.object, "GetClass")
    local name = ok and full_name(class) or ""
    -- Reflected Stats fields in this game include visual WidgetComponents.
    -- Actual Blueprint gameplay objects are inspected before those widgets.
    if name:find("/Script/UMG.", 1, true) then return 10 end
    if name:find("/Script/", 1, true) then return priority + 4 end
    return priority
end

local function default_is_gameplay(object)
    if not valid(object) then return false end
    local name = full_name(object):lower()
    if name:find("default__", 1, true) or name:find("/mainmenu/", 1, true)
        or name:find("mainmenu_level", 1, true) or name:find("pre-menulevel", 1, true) then return false end
    local ok, world = call(object, "GetWorld")
    if ok and valid(world) then
        local world_name = full_name(world):lower()
        if world_name:find("/mainmenu/", 1, true) or world_name:find("mainmenu_level", 1, true)
            or world_name:find("pre-menulevel", 1, true) then return false end
        return true
    end
    -- Also supports the live-object form observed in the user's reports when
    -- a particular UE4SS build cannot supply GetWorld.
    return name:find(":persistentlevel.", 1, true) ~= nil
end

function Diagnostics.new(options)
    options = options or {}
    assert(type(options.emit) == "function", "diagnostics requires an append-only emit(line) function")
    local self = setmetatable({}, Instance)
    self.emit = options.emit
    self.is_gameplay = options.is_gameplay or default_is_gameplay
    self.max_properties = math.min(2000, math.max(1, tonumber(options.max_properties) or 2000))
    self.max_functions = math.min(180, math.max(1, tonumber(options.max_functions) or 100))
    self.max_objects = math.min(32, math.max(1, tonumber(options.max_objects) or 20))
    self.max_map_entries = math.min(1024, math.max(1, tonumber(options.max_map_entries) or 512))
    self.sequence = 0
    self.session = os.date("!%Y%m%dT%H%M%SZ") .. "-" .. tostring({}):gsub("[^%w]", "")
    self.schema_cache = {}
    self.known_values = {}
    return self
end

function Instance:_map_values(context, value, path)
    local count = 0
    local function inspect(key, entry)
        if (context.map_entries or 0) >= self.max_map_entries then
            if not context.map_truncated then
                context.map_truncated = true
                self:_line(context.id, "TRUNCATED map values; total_map_entry_limit=" .. self.max_map_entries)
            end
            return true
        end
        context.map_entries = (context.map_entries or 0) + 1
        count = count + 1
        key, entry = unpack_parameter(key), unpack_parameter(entry)
        local key_text
        if type(key) == "string" or type(key) == "number" or type(key) == "boolean" then
            key_text = tostring(key)
        else
            local ok, text = call(key, "ToString")
            key_text = ok and type(text) == "string" and text or scalar(key)
        end
        self:_line(context.id, "MAP_ENTRY " .. path .. "[" .. quote(key_text) .. "]=" .. scalar(entry))
        -- Nil continues UE4SS's native TMap iterator. Never mutate key/value.
    end
    local typed, wrapper = call(value, "type")
    if typed and wrapper == "TMap" then
        local ok, err = call(value, "ForEach", inspect)
        if not ok then self:_line(context.id, "MAP_ENUMERATION_UNAVAILABLE " .. path .. " " .. clean(err)) end
    elseif type(value) == "table" and not typed then
        -- Some reflected adapters expose a plain Lua table instead of TMap.
        for key, entry in next, value do if inspect(key, entry) then break end end
    else
        self:_line(context.id, "MAP_ENUMERATION_UNAVAILABLE " .. path .. " wrapper=" .. scalar(value))
    end
    self:_line(context.id, "MAP_ENTRY_COUNT " .. path .. "=" .. count)
end

function Instance:_line(event_id, text)
    self.emit("[CCC-DIAG " .. event_id .. "] " .. text)
end

function Instance:_begin(label)
    self.sequence = self.sequence + 1
    local id = self.session .. "/" .. tostring(self.sequence)
    self:_line(id, "BEGIN " .. quote(label) .. " utc=" .. os.date("!%Y-%m-%dT%H:%M:%SZ"))
    return id
end

function Instance:_live(object)
    if not valid(object) then return false end
    local ok, result = pcall(self.is_gameplay, object)
    return ok and result == true
end

function Instance:_live_reference(object)
    if not valid(object) then return false end
    local name = full_name(object):lower()
    if name:find("default__", 1, true) or name:find("/mainmenu/", 1, true)
        or name:find("pre-menulevel", 1, true) then return false end
    if self:_live(object) then return true end
    -- A SaveGame/GameInstance-style data object can be referenced by a live
    -- actor while having no World of its own. Keep transient runtime references
    -- reachable from that actor; never scan unrelated globals or asset defaults.
    return name:find("/engine/transient.", 1, true) ~= nil
        or name:find("/engine/transient:", 1, true) ~= nil
end

function Instance:_extra(id, extra)
    if type(extra) ~= "table" then return end
    local keys = {}
    for key in pairs(extra) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for index, key in ipairs(keys) do
        if index > 32 then self:_line(id, "TRUNCATED extra metadata: limit=32"); break end
        self:_line(id, "META " .. quote(key) .. "=" .. scalar(extra[key]))
    end
end

function Instance:_budget(context, label)
    if context.properties < self.max_properties then
        context.properties = context.properties + 1
        return true
    end
    if not context.property_truncated then
        context.property_truncated = true
        self:_line(context.id, "TRUNCATED property metadata at " .. quote(label)
            .. "; total_property_limit=" .. self.max_properties)
    end
    return false
end

function Instance:_chain(object)
    local chain, seen = {}, {}
    local ok, class = call(object, "GetClass")
    if not ok then return chain end
    for depth = 0, 12 do
        if not valid(class) then break end
        local class_id = identity(class)
        if seen[class_id] then break end
        seen[class_id] = true
        chain[#chain + 1] = {class = class, depth = depth, name = full_name(class)}
        local got, parent = call(class, "GetSuperStruct")
        if not got then break end
        class = parent
    end
    return chain
end

local function unwrap_entry(value)
    -- Accept either live UObject or the {obj=...} entries used by earlier mods.
    if type(value) == "table" and rawget(value, "obj") ~= nil then return value.obj end
    return value
end

function Instance:_queue_nested(context, value, property, path, depth)
    if depth >= 2 then return end
    local kind = property_type(property)
    if kind == "StructProperty" then
        local ok, struct = call(property, "GetStruct")
        if ok and valid(struct) and value ~= nil then
            context.nested[#context.nested + 1] = {object = value, class = struct, path = path, depth = depth + 1, struct = true}
        end
    elseif kind == "ObjectProperty" or kind == "ObjectPtrProperty" then
        if not valid(value) then return end
        local id = identity(value)
        if context.seen_objects[id] then return end
        -- Only expand live objects/components. Referenced asset templates and
        -- class defaults can have plausible defaults unrelated to this play.
        if not self:_live_reference(value) then return end
        context.seen_objects[id] = true
        context.nested[#context.nested + 1] = {object = value, path = path, depth = depth + 1}
    end
end

function Instance:_component_refs(context, root)
    -- Blueprint component variables are not the only way an actor may own
    -- components. Enumerate the reflected native getter when it exists.
    local ok, component_class = pcall(function() return StaticFindObject("/Script/Engine.ActorComponent") end)
    if not ok or not valid(component_class) then return end
    local getter
    for _, path in ipairs({"/Script/Engine.Actor:GetComponentsByClass", "/Script/Engine.Actor:K2_GetComponentsByClass"}) do
        local found, fn = pcall(function() return StaticFindObject(path) end)
        if found and valid(fn) then getter = fn; break end
    end
    if getter == nil then
        self:_line(context.id, "COMPONENT_ENUMERATION_UNAVAILABLE " .. root.key .. ": native getter not exposed")
        return
    end
    local got, components = pcall(function() return getter(root.object, component_class) end)
    if not got then
        self:_line(context.id, "COMPONENT_ENUMERATION_ERROR " .. root.key .. " " .. clean(components))
        return
    end
    local function collect(index, value)
        context.component_refs = context.component_refs + 1
        if context.component_refs > 512 then
            if not context.components_truncated then
                context.components_truncated = true
                self:_line(context.id, "TRUNCATED component references; total_limit=512")
            end
            return true
        end
        local component = unpack_parameter(value)
        if not valid(component) then return end
        local got_class, class = call(component, "GetClass")
        local class_name = got_class and full_name(class) or "<class unavailable>"
        local name = short_name(component)
        local selected = relevant(name) or relevant(class_name)
        self:_line(context.id, "COMPONENT_REF " .. root.key .. " index=" .. tostring(index)
            .. " object=" .. quote(full_name(component)) .. " class=" .. quote(class_name)
            .. " selected=" .. tostring(selected))
        local object_id = identity(component)
        if selected and not context.seen_objects[object_id] and self:_live(component) then
            context.seen_objects[object_id] = true
            context.nested[#context.nested + 1] = {object = component, path = root.key .. ".component[" .. quote(name) .. "]", depth = 1}
        end
        -- Nil continues UE4SS's native TArray iterator without its false-result bug.
    end
    if type(components) == "table" then
        for index, component in ipairs(components) do if collect(index, component) then break end end
    else
        local iterated, err = call(components, "ForEach", collect)
        if not iterated then self:_line(context.id, "COMPONENT_ARRAY_ERROR " .. root.key .. " " .. clean(err)) end
    end
end

function Instance:_properties(context, object, class, path, depth, struct_values)
    local count, skipped = 0, 0
    local pending_maps = {}
    local native_class = full_name(class):find("/Script/", 1, true) ~= nil
    local save_object = save_context(path)
    local ok, err = call(class, "ForEachProperty", function(property)
        local name = short_name(property)
        local kind = property_type(property)
        local primitive = kind == "FloatProperty" or kind == "DoubleProperty" or kind == "BoolProperty"
            or kind == "ByteProperty" or kind == "EnumProperty" or kind:find("Int", 1, true) ~= nil
        local selected = relevant(name) or (struct_values == true and primitive)
            or (save_object and kind == "MapProperty")
        -- Native scene/UMG inheritance previously consumed the entire budget
        -- before Easy Save Ref was reached. Keep their relevant fields only.
        if native_class and not selected then skipped = skipped + 1; return end
        if not self:_budget(context, path .. "." .. name) then return true end
        count = count + 1
        local ok_offset, offset = call(property, "GetOffset_Internal")
        local suffix = ok_offset and (" offset=" .. tostring(offset)) or ""
        local value, read_ok
        if selected then
            read_ok, value = read_property(object, name)
            suffix = suffix .. " value=" .. (read_ok and scalar(value) or ("<READ_ERROR " .. clean(value) .. ">"))
        end
        self:_line(context.id, "PROPERTY " .. path .. "[" .. quote(name) .. "] type=" .. kind .. suffix)
        if selected and read_ok then
            if save_object and kind == "MapProperty" then
                pending_maps[#pending_maps + 1] = {name = name, value = value, path = path .. "[" .. quote(name) .. "]"}
            end
            self:_queue_nested(context, value, property, path .. "[" .. quote(name) .. "]", depth)
            if depth == 0 and (type(value) == "number" or type(value) == "boolean") then
                local id = identity(object)
                self.known_values[id] = self.known_values[id] or {}
                self.known_values[id][name] = true
            end
        end
        -- Nil continues UE4SS's native property iterator.
    end)
    if not ok then self:_line(context.id, "PROPERTY_ENUMERATION_ERROR " .. path .. " " .. clean(err)) end
    table.sort(pending_maps, function(a, b)
        local function rank(name)
            name = name:lower()
            return (name:find("float", 1, true) or name:find("health", 1, true) or name == "hp") and 0 or 1
        end
        local ar, br = rank(a.name), rank(b.name)
        if ar == br then return a.name < b.name end
        return ar < br
    end)
    for _, entry in ipairs(pending_maps) do self:_map_values(context, entry.value, entry.path) end
    self:_line(context.id, "PROPERTY_COUNT " .. path .. "=" .. count .. " native_unrelated_skipped=" .. skipped)
end

function Instance:_schema(fn, context, emit_lines)
    local path = full_name(fn)
    local ok_flags, flags = call(fn, "GetFunctionFlags")
    local schema = {path = path, flags = ok_flags and flags or nil, fields = {}, parameters_verified = true}
    if emit_lines then self:_line(context.id, "FUNCTION " .. path .. " flags=" .. flag_string(schema.flags)) end
    local ok, err = call(fn, "ForEachProperty", function(property)
        if not self:_budget(context, path) then return true end
        local field = {name = short_name(property), type = property_type(property), full_name = full_name(property)}
        local got_offset, offset = call(property, "GetOffset_Internal")
        if got_offset then field.offset = offset end
        -- Not exposed in the standard UE4SS Lua API; preserve the distinction
        -- between missing metadata and actual zero property flags.
        local got_flags, property_flags = call(property, "GetPropertyFlags")
        if got_flags and type(property_flags) == "number" then
            field.flags = property_flags
            field.is_parameter = math.floor(property_flags / 128) % 2 == 1 -- CPF_Parm
            field.is_out = math.floor(property_flags / 256) % 2 == 1 -- CPF_OutParm
            field.is_return = math.floor(property_flags / 1024) % 2 == 1 -- CPF_ReturnParm
        else
            schema.parameters_verified = false
        end
        schema.fields[#schema.fields + 1] = field
        if emit_lines then
            local label = field.is_parameter == true and "PARAMETER" or "DECLARED_FIELD"
            self:_line(context.id, "  " .. label .. " " .. quote(field.name) .. " type=" .. field.type
                .. " offset=" .. tostring(field.offset or "UNAVAILABLE") .. " property_flags=" .. flag_string(field.flags))
        end
        -- Nil continues UE4SS's native property iterator.
    end)
    if not ok then
        schema.parameters_verified = false
        schema.error = clean(err)
        if emit_lines then self:_line(context.id, "FUNCTION_FIELDS_ERROR " .. path .. " " .. schema.error) end
    end
    if not schema.parameters_verified and emit_lines then
        self:_line(context.id, "  PARAMETER_CLASSIFICATION_UNAVAILABLE: declared fields may include locals; no argument order is inferred")
    end
    self.schema_cache[path] = schema
    return schema
end

function Instance:_functions(context, class, path)
    local candidates = {}
    local ok, err = call(class, "ForEachFunction", function(fn)
        local name = short_name(fn)
        if relevant_function(name) or (save_context(path) and save_function(name)) then candidates[#candidates + 1] = fn end
        -- Nil continues UE4SS's native function iterator.
    end)
    if not ok then self:_line(context.id, "FUNCTION_ENUMERATION_ERROR " .. path .. " " .. clean(err)); return end
    table.sort(candidates, function(a, b) return full_name(a) < full_name(b) end)
    for _, fn in ipairs(candidates) do
        if context.functions >= self.max_functions then
            if not context.function_truncated then
                context.function_truncated = true
                self:_line(context.id, "TRUNCATED functions; function_limit=" .. self.max_functions)
            end
            return
        end
        local fn_id = identity(fn)
        if not context.seen_functions[fn_id] then
            context.seen_functions[fn_id] = true
            context.functions = context.functions + 1
            self:_schema(fn, context, true)
        end
    end
end

function Instance:_drain_nested(context, critical_only)
    while #context.nested > 0 and context.properties < self.max_properties do
        local selected, priority
        for index, entry in ipairs(context.nested) do
            local rank = nested_priority(entry)
            if (not critical_only or rank < 0) and (priority == nil or rank < priority) then
                selected, priority = index, rank
            end
        end
        if selected == nil then return end
        if context.objects >= self.max_objects then
            self:_line(context.id, "TRUNCATED nested objects; object_limit=" .. self.max_objects)
            return
        end
        local entry = table.remove(context.nested, selected)
        context.objects = context.objects + 1
        if entry.struct then
            self:_line(context.id, "NESTED_STRUCT " .. entry.path .. " " .. full_name(entry.class))
            self:_properties(context, entry.object, entry.class, entry.path, entry.depth, true)
        else
            self:_line(context.id, "NESTED_OBJECT " .. entry.path .. " " .. full_name(entry.object))
            local chain = self:_chain(entry.object)
            for _, item in ipairs(chain) do self:_properties(context, entry.object, item.class, entry.path, entry.depth) end
            for _, item in ipairs(chain) do self:_functions(context, item.class, entry.path) end
        end
        -- Newly discovered svrSubClass entries are prioritized immediately.
    end
end

function Instance:snapshot(label, actors, extra)
    actors = actors or {}
    local roots, keys = {}, {}
    for _, key in ipairs({"player", "train", "charles"}) do
        if actors[key] ~= nil then keys[#keys + 1] = key end
    end
    local other = {}
    for key in pairs(actors) do
        if key ~= "player" and key ~= "train" and key ~= "charles" then other[#other + 1] = key end
    end
    table.sort(other, function(a,b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(other) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do
        local object = unwrap_entry(actors[key])
        if self:_live(object) then roots[#roots + 1] = {object = object, key = clean(key), chain = self:_chain(object)} end
    end
    if #roots == 0 then return false, "no live gameplay actors" end
    local id = self:_begin(label)
    local context = {id = id, properties = 0, functions = 0, objects = #roots, component_refs = 0,
        nested = {}, seen_objects = {}, seen_functions = {}}
    self:_extra(id, extra)
    for _, root in ipairs(roots) do
        context.seen_objects[identity(root.object)] = true
        self:_line(id, "ROOT " .. root.key .. " " .. full_name(root.object))
    end
    -- All gameplay Blueprint fields of ALL primary actors come before native
    -- inherited fields, function metadata and nested components. No 250 cap.
    for _, native_pass in ipairs({false, true}) do
        for _, root in ipairs(roots) do
            for _, item in ipairs(root.chain) do
                local is_native = item.name:find("/Script/", 1, true) ~= nil
                if is_native == native_pass then
                    self:_line(id, "CLASS " .. root.key .. " depth=" .. item.depth .. " " .. item.name)
                    self:_properties(context, root.object, item.class, root.key, 0)
                end
            end
        end
        if not native_pass then self:_drain_nested(context, true) end
    end
    for _, root in ipairs(roots) do
        for _, item in ipairs(root.chain) do self:_functions(context, item.class, root.key) end
    end
    for _, root in ipairs(roots) do self:_component_refs(context, root) end
    self:_drain_nested(context, false)
    if #context.nested > 0 and context.properties >= self.max_properties then
        self:_line(id, "TRUNCATED remaining nested values; total_property_limit=" .. self.max_properties)
    end
    self:_line(id, "END properties=" .. context.properties .. " functions=" .. context.functions .. " objects=" .. context.objects)
    return true, id
end

function Instance:function_schema(function_or_path)
    local fn = function_or_path
    if type(fn) == "string" then
        local ok, result = pcall(function() return StaticFindObject(fn) end)
        if not ok or not valid(result) then return nil, "function is not loaded" end
        fn = result
    end
    if not valid(fn) then return nil, "invalid function" end
    local id = self:_begin("function-schema")
    local context = {id = id, properties = 0}
    local result = self:_schema(fn, context, true)
    self:_line(id, "END function-schema")
    return result
end

function Instance:_observe_values(id, object)
    local names = self.known_values[identity(object)]
    if names == nil then
        names = {}
        for _, entry in ipairs(self:_chain(object)) do
            call(entry.class, "ForEachProperty", function(property)
                local name = short_name(property)
                if relevant(name) then
                    local kind = property_type(property)
                    if kind:find("Float", 1, true) or kind:find("Double", 1, true)
                        or kind:find("Int", 1, true) or kind == "BoolProperty" then names[name] = true end
                end
                -- Nil continues UE4SS's native property iterator.
            end)
        end
        self.known_values[identity(object)] = names
    end
    local ordered = {}
    for name in pairs(names) do ordered[#ordered + 1] = name end
    table.sort(ordered)
    for index, name in ipairs(ordered) do
        if index > 80 then self:_line(id, "TRUNCATED compact values; limit=80"); break end
        local ok, value = read_property(object, name)
        self:_line(id, "VALUE " .. quote(name) .. "=" .. (ok and scalar(value) or ("<READ_ERROR " .. clean(value) .. ">")))
    end
end

function Instance:observe(label, object, extra)
    object = unwrap_entry(object)
    if not self:_live(object) then return false, "not a live gameplay actor" end
    local id = self:_begin(label)
    self:_line(id, "OBJECT " .. full_name(object))
    self:_extra(id, extra)
    self:_observe_values(id, object)
    self:_line(id, "END observation")
    return true, id
end

function Instance:event(label, object, function_path, arguments)
    object = unwrap_entry(object)
    if not self:_live(object) then return false, "not a live gameplay actor" end
    local id = self:_begin(label)
    self:_line(id, "OBJECT " .. full_name(object))
    self:_line(id, "EVENT_FUNCTION " .. clean(function_path or "<unspecified>", 500))
    arguments = type(arguments) == "table" and arguments or {}
    local count = type(arguments.n) == "number" and arguments.n or #arguments
    for index = 1, math.min(40, count) do
        self:_line(id, "ARGUMENT position=" .. index .. " value=" .. scalar(unpack_parameter(arguments[index])))
    end
    if count > 40 then self:_line(id, "TRUNCATED hook arguments; supplied=" .. count .. " limit=40") end
    -- Do not align positional values with DECLARED_FIELD metadata: FProperty
    -- flags are unavailable on standard Lua builds and locals may be present.
    self:_observe_values(id, object)
    self:_line(id, "END event")
    return true, id
end

return Diagnostics
