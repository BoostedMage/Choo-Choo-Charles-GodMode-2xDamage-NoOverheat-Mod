-- Focused regressions for the failures in the actual v0.2 and v0.3 reports.
-- This test compiles a native Lua 5.4 fixture, not a permissive Lua iterator stub.
-- It reproduces the retained-callback stack sequence in the official v4.0.0
-- ForEachProperty, ForEachFunction, and TArray:ForEach bindings. No Unreal/game
-- behavior is simulated by this fixture; only the actual Lua C API boundary.
-- Sources:
-- https://github.com/UE4SS-RE/RE-UE4SS/blob/v4.0.0/UE4SS/src/LuaType/LuaUStruct.cpp
-- https://github.com/UE4SS-RE/RE-UE4SS/blob/v4.0.0/UE4SS/src/LuaType/LuaTArray.cpp
-- https://github.com/UE4SS-RE/RE-UE4SS/blob/v4.0.0/deps/first/LuaMadeSimple/src/LuaMadeSimple.cpp
assert(_VERSION == 'Lua 5.4', 'native iterator regression requires Lua 5.4')

local fixture_source = [=[
#include <stddef.h>
#include <stdint.h>

/* Public Lua 5.4 C API declarations used by this self-contained test fixture. */
typedef struct lua_State lua_State;
typedef long long lua_Integer;
typedef intptr_t lua_KContext;
typedef int (*lua_CFunction)(lua_State *);
typedef int (*lua_KFunction)(lua_State *, int, lua_KContext);
extern int lua_gettop(lua_State *);
extern void lua_settop(lua_State *, int);
extern void lua_pushvalue(lua_State *, int);
extern void lua_rotate(lua_State *, int, int);
extern void lua_pushinteger(lua_State *, lua_Integer);
extern void lua_pushboolean(lua_State *, int);
extern void lua_pushcclosure(lua_State *, lua_CFunction, int);
extern int lua_type(lua_State *, int);
extern int lua_toboolean(lua_State *, int);
extern size_t lua_rawlen(lua_State *, int);
extern int lua_rawgeti(lua_State *, int, lua_Integer);
extern int lua_pcallk(lua_State *, int, int, int, lua_KContext, lua_KFunction);
extern int lua_error(lua_State *);
extern void lua_createtable(lua_State *, int, int);
extern void lua_setfield(lua_State *, int, const char *);
extern void *lua_newuserdatauv(lua_State *, size_t, int);
extern int lua_setmetatable(lua_State *, int);

#define UPVALUE(i) (-1001000 - (i))
#define LUA_TBOOLEAN 1

static void remove_at(lua_State *L, int position) {
    lua_rotate(L, position, -1);
    lua_settop(L, -2);
}

static int keep_error(lua_State *L) { (void)L; return 1; }

static int iterator(lua_State *L) {
    const int with_index = lua_toboolean(L, UPVALUE(2));
    const size_t count = lua_rawlen(L, UPVALUE(1));
    size_t i;
    /* LuaMadeSimple::get_userdata consumes the self argument. */
    remove_at(L, 1);
    for (i = 1; i <= count; ++i) {
        int arguments = with_index ? 2 : 1;
        int callback_position;
        int result;
        /* Keep the original callback at slot 1 between iterations. */
        lua_pushvalue(L, 1);
        if (with_index) lua_pushinteger(L, (lua_Integer)i);
        lua_rawgeti(L, UPVALUE(1), (lua_Integer)i);
        /* LuaMadeSimple::call_function inserts and then removes its handler. */
        callback_position = lua_gettop(L) - arguments;
        lua_pushcclosure(L, keep_error, 0);
        lua_rotate(L, callback_position, 1);
        result = lua_pcallk(L, arguments, 1, callback_position, 0, NULL);
        remove_at(L, callback_position);
        if (result != 0) return lua_error(L);
        if (lua_type(L, 2) == LUA_TBOOLEAN) {
            const int stop = lua_toboolean(L, 2);
            /* get_bool(2) removes the value, including boolean false. */
            remove_at(L, 2);
            if (stop) break;
        }
        /* The v4.0.0 else branch executes this even after false was removed. */
        remove_at(L, 2);
    }
    return with_index ? 0 : 1;
}

static int make_iterator(lua_State *L) {
    /* Arguments: item table, whether to pass an array index. */
    lua_settop(L, 2);
    lua_pushcclosure(L, iterator, 2);
    return 1;
}

static int make_array(lua_State *L) {
    /* A real userdata makes diagnostics take its native TArray branch. */
    lua_settop(L, 1);
    lua_newuserdatauv(L, 1, 0);
    lua_createtable(L, 0, 2);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pushvalue(L, 1);
    lua_pushboolean(L, 1);
    lua_pushcclosure(L, iterator, 2);
    lua_setfield(L, -2, "ForEach");
    lua_setmetatable(L, -2);
    return 1;
}

int luaopen_ccc_iterator_fixture(lua_State *L) {
    lua_createtable(L, 0, 2);
    lua_pushcclosure(L, make_iterator, 0);
    lua_setfield(L, -2, "iterator");
    lua_pushcclosure(L, make_array, 0);
    lua_setfield(L, -2, "array");
    return 1;
}
]=]

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end
local fixture_path = os.getenv('CCC_ITERATOR_FIXTURE')
if not fixture_path then
    assert(package.config:sub(1, 1) == '/',
        'set CCC_ITERATOR_FIXTURE to a native build of the embedded Lua 5.4 test module on this platform')
    local temporary = assert(os.getenv('CCC_TEST_ROOT'), 'run through Verification/run_lua_tests.py')
    local c_path = temporary .. '/ccc_iterator_fixture.c'
    fixture_path = temporary .. '/ccc_iterator_fixture.so'
    local compiler_log = temporary .. '/ccc_iterator_fixture_build.log'
    local file = assert(io.open(c_path, 'w')); file:write(fixture_source); file:close()
    local command = shell_quote(os.getenv('CC') or 'cc') .. ' -std=c99 -O0 -shared -fPIC '
        .. shell_quote(c_path) .. ' -Wl,-z,defs -l:liblua5.4.so.0 -o ' .. shell_quote(fixture_path)
        .. ' 2>' .. shell_quote(compiler_log)
    local compiled = os.execute(command)
    if compiled ~= true and compiled ~= 0 then
        local output = io.open(compiler_log, 'r')
        local detail = output and output:read('*a') or 'compiler output unavailable'
        if output then output:close() end
        error('native Lua 5.4 regression fixture build failed: ' .. detail)
    end
end
local native = assert(package.loadlib(fixture_path, 'luaopen_ccc_iterator_fixture'))()

-- Prove the fixture exhibits the real reported failure before using it below.
local probe = {ForEachProperty = native.iterator({1, 2, 3}, false)}
local seen = 0
local false_ok, false_error = pcall(function()
    probe:ForEachProperty(function() seen = seen + 1; return false end)
end)
assert(not false_ok and seen == 1 and tostring(false_error):find('attempt to call a nil value', 1, true),
    'v4 false-result double removal must fail on iteration 2 with the reported nil-call error')
seen = 0
probe:ForEachProperty(function() seen = seen + 1 end)
assert(seen == 3, 'no-value callback return must enumerate every property')
seen = 0
local detached = probe.ForEachProperty
detached(probe, function() seen = seen + 1 end)
assert(seen == 3, 'detached method syntax is valid; false return was the fault')
seen = 0
probe:ForEachProperty(function() seen = seen + 1; return true end)
assert(seen == 1, 'true still stops safely')
local array_probe = native.array({1, 2, 3})
seen = 0
local array_false_ok = pcall(function()
    array_probe:ForEach(function() seen = seen + 1; return false end)
end)
assert(not array_false_ok and seen == 1, 'native TArray has the same false-return failure')
seen = 0
array_probe:ForEach(function(index, value) assert(index == value); seen = seen + 1 end)
assert(seen == 3, 'native TArray nil continuation enumerates all elements')

local scripts = os.getenv('CCC_MOD_SCRIPTS') or './Mod/ChooChooCharles_GodMode/Scripts'
local Diagnostics = dofile(scripts .. '/diagnostics.lua')
local serial = 0
local function base(name)
    serial = serial + 1
    local result = {name = name, address = serial}
    function result:IsValid() return true end
    function result:GetAddress() return self.address end
    function result:GetFullName() return self.name end
    function result:GetFName() return {ToString = function() return self.name end} end
    return result
end

local function property(name, kind, offset, flags)
    local result = base(name)
    function result:GetClass()
        -- FFieldClass deliberately has no IsValid method.
        return {GetFName = function() return {ToString = function() return kind end} end}
    end
    function result:GetOffset_Internal() return offset or 0 end
    if flags ~= nil then function result:GetPropertyFlags() return flags end end
    return result
end

local function class(name, properties, functions, parent)
    local result = base(name)
    result.ForEachProperty = native.iterator(properties or {}, false)
    result.ForEachFunction = native.iterator(functions or {}, false)
    function result:GetSuperStruct() return parent end
    return result
end

local world = base('World /Game/Island.Photorealistic_Island')
local function actor(name, cls, values)
    local result = base(name)
    result.values = values or {}
    function result:GetClass() return cls end
    function result:GetWorld() return world end
    function result:GetPropertyValue(name) return self.values[name] end
    setmetatable(result, {__index = function(self, key) return self.values[key] end})
    return result
end

local fn = class('Function /Game/Player.Player_C:Damage', {
    property('Damage Amount', 'FloatProperty', 0),
    property('ReturnValue', 'BoolProperty', 4),
})
function fn:GetFName() return {ToString = function() return 'Damage' end} end
function fn:GetFunctionFlags() return 0x04000000 end

local props = {property('UberGraphFrame', 'StructProperty', 0)}
for n = 1, 290 do props[#props + 1] = property('Unrelated Component ' .. n, 'ObjectProperty', n * 8) end
props[#props + 1] = property('Train Health', 'FloatProperty', 2400)
props[#props + 1] = property('Dead?', 'BoolProperty', 2404)
props[#props + 1] = property('Machine Gun Stats', 'ObjectProperty', 2416)
props[#props + 1] = property('Stats', 'StructProperty', 2424)
local struct_class = class('UserDefinedStruct /Game/GunStatsStruct.GunStatsStruct', {
    property('DamageAmount_14_RAW_GUID', 'FloatProperty', 0),
    property('Enabled', 'BoolProperty', 4),
})
props[#props].GetStruct = function() return struct_class end
props[#props + 1] = property('Overheating', 'BoolProperty', 2432)
props[#props + 1] = property('Heat', 'FloatProperty', 2436)
props[#props + 1] = property('Jammed', 'BoolProperty', 2440)
local gun_class = class('BlueprintGeneratedClass /Game/GunStats.GunStats_C', {
    property('Damage Amount', 'FloatProperty', 10),
})
local gun = actor('GunStats_C /Game/Island.Island:PersistentLevel.Train_4.Machine Gun Stats', gun_class, {['Damage Amount'] = 16})
local native_class = class('Class /Script/Engine.Actor', {property('bCanBeDamaged', 'BoolProperty', 100)}, {})
local unrelated_function = class('Function /Game/PlayerTrain.PlayerTrain_C:Tick', {})
function unrelated_function:GetFName() return {ToString = function() return 'Tick' end} end
local heat_function = class('Function /Game/PlayerTrain.PlayerTrain_C:GunJamOverheat', {})
function heat_function:GetFName() return {ToString = function() return 'GunJamOverheat' end} end
local train_class = class('BlueprintGeneratedClass /Game/PlayerTrain.PlayerTrain_C', props,
    {unrelated_function, fn, heat_function}, native_class)
local train = actor('PlayerTrain_C /Game/Island.Island:PersistentLevel.Train_4', train_class, {
    ['Train Health'] = 75,
    ['Dead?'] = false,
    ['bCanBeDamaged'] = false,
    ['Machine Gun Stats'] = gun,
    ['Stats'] = {DamageAmount_14_RAW_GUID = 9, Enabled = false},
    ['Overheating'] = false, Heat = 0.25, Jammed = false,
})
local player_class = class('BlueprintGeneratedClass /Game/Player.Player_C', {
    property('varHealthMain', 'FloatProperty', 16),
})
local player = actor('Player_C /Game/Island.Island:PersistentLevel.Player_2', player_class, {varHealthMain = 100})
local lines = {}
local d = Diagnostics.new({emit = function(line) lines[#lines + 1] = line end})
local ok, event1 = d:snapshot('F9-before-hit', {player = player, train = train})
assert(ok == true)
local text = table.concat(lines, '\n')
assert(text:find('train["Train Health"] type=FloatProperty offset=2400 value=75', 1, true), 'health after field 250 must be captured')
assert(text:find('train["Dead?"] type=BoolProperty offset=2404 value=false', 1, true), 'false must not become nil')
assert(text:find('train["Machine Gun Stats"]["Damage Amount"] type=FloatProperty offset=10 value=16', 1, true), 'live weapon component values are expanded')
assert(text:find('train["Stats"]["DamageAmount_14_RAW_GUID"] type=FloatProperty offset=0 value=9', 1, true), 'mapped struct values are captured')
assert(text:find('flags=0x4000000', 1, true), 'actual UFunction flags are recorded')
assert(text:find('DECLARED_FIELD "Damage Amount" type=FloatProperty', 1, true), 'exact raw spaced field name')
assert(text:find('DECLARED_FIELD "ReturnValue" type=BoolProperty', 1, true), 'function schema continues after its first field')
assert(text:find('FUNCTION Function /Game/PlayerTrain.PlayerTrain_C:GunJamOverheat', 1, true), 'heat function beyond the first function is captured')
assert(text:find('train["Overheating"] type=BoolProperty offset=2432 value=false', 1, true), 'heat/jam state must include live scalar values')
assert(text:find('train["Heat"] type=FloatProperty offset=2436 value=0.25', 1, true), 'numeric heat is included without a guessed write')
assert(not text:find('ENUMERATION_ERROR', 1, true) and not text:find('FUNCTION_FIELDS_ERROR', 1, true), 'native iterators finish without stack-corruption errors')
assert(text:find('property_flags=UNAVAILABLE_IN_UE4SS_LUA', 1, true), 'missing property flags are explicit')
assert(not text:find('PARAMETER "Damage Amount"', 1, true), 'missing CPF_Parm flags do not become inferred parameter classification')
local own_at = assert(text:find('train["Train Health"]', 1, true))
local component_at = assert(text:find('NESTED_OBJECT', 1, true))
assert(own_at < component_at, 'primary own properties precede component expansion')

-- Event parameter wrappers preserve false and nil; positional arguments stay positional.
local wrapper = {type = function() return 'RemoteUnrealParam' end, get = function() return false end}
local ok_event, event2 = d:event('Damage-post', player, '/Game/Player.Player_C:Damage', {n = 3, 5, wrapper, nil})
assert(ok_event and event1 ~= event2, 'event labels have unique identities')
text = table.concat(lines, '\n')
assert(text:find('ARGUMENT position=2 value=false', 1, true), 'false event parameter survives unwrap')
assert(text:find('ARGUMENT position=3 value=<nil>', 1, true), 'packed nil event parameter is included')

-- Menu actors are ignored, including when GetWorld would otherwise succeed.
local menu = actor('PlayerTrain_C /Game/_GAME/MainMenu/MainMenu_Level.MainMenu_Level:PersistentLevel.Train_4', train_class)
local previous_count = #lines
assert(d:snapshot('menu-poll', {train = menu}) == false)
assert(d:observe('menu-event', menu) == false)
assert(#lines == previous_count, 'ignored menu polling writes no spam')

-- A configured limit is an explicit truncation, never silent success.
local bounded = {}
local limited = Diagnostics.new({max_properties = 12, emit = function(line) bounded[#bounded + 1] = line end})
assert(limited:snapshot('bounded', {train = train}) == true)
local bounded_text = table.concat(bounded, '\n')
assert(bounded_text:find('TRUNCATED property metadata', 1, true))
assert(bounded_text:find('END properties=12', 1, true))

-- Actual flags can be used when an extended runtime supplies them.
local with_flags = class('Function /Game/Player.Player_C:DamageWithFlags', {
    property('Damage Amount', 'FloatProperty', 0, 0x80),
    property('ReturnValue', 'BoolProperty', 4, 0x480),
    property('Local Temporary', 'FloatProperty', 8, 0),
})
function with_flags:GetFunctionFlags() return 0x200 end
local schema = d:function_schema(with_flags)
assert(schema.parameters_verified)
assert(schema.fields[1].is_parameter == true and schema.fields[1].is_return == false)
assert(schema.fields[2].is_parameter == true and schema.fields[2].is_return == true)
assert(schema.fields[3].is_parameter == false)

-- Owned components can exist without a reflected actor member named Stats.
local hidden_stats = actor('Stats_C /Game/Island.Island:PersistentLevel.Train_4.Stats',
    class('BlueprintGeneratedClass /Game/Stats.Stats_C', {property('Health', 'FloatProperty', 0)}), {Health = 62})
local native_getter = base('Function /Script/Engine.Actor:GetComponentsByClass')
setmetatable(native_getter, {__call = function(_, owner)
    if owner == train then return {hidden_stats} end
    return {}
end})
function StaticFindObject(path)
    if path == '/Script/Engine.ActorComponent' then return base('Class /Script/Engine.ActorComponent') end
    if path == '/Script/Engine.Actor:GetComponentsByClass' then return native_getter end
end
lines = {}
assert(d:snapshot('owned-components', {train = train}))
text = table.concat(lines, '\n')
assert(text:find('COMPONENT_REF train', 1, true))
assert(text:find('Health"] type=FloatProperty offset=0 value=62', 1, true), 'unexported owned Stats component is inspected')

-- Native TArray path: skip an invalid first object and retain later components.
-- The fixture is userdata, so this cannot accidentally test the Lua table branch.
local hidden_heat = actor('GunStats_C /Game/Island.Island:PersistentLevel.Train_4.GunStats',
    class('BlueprintGeneratedClass /Game/GunStats.GunStats_C', {
        property('Heat', 'FloatProperty', 0), property('Jammed', 'BoolProperty', 4),
    }), {Heat = 0.75, Jammed = false})
local invalid_component = {IsValid = function() return false end}
local function remote(value)
    return {type = function() return 'RemoteUnrealParam' end, get = function() return value end}
end
setmetatable(native_getter, {__call = function(_, owner)
    if owner == train then
        return native.array({remote(invalid_component), remote(hidden_stats), remote(hidden_heat)})
    end
    return native.array({})
end})
lines = {}
assert(d:snapshot('native-owned-components', {train = train}))
text = table.concat(lines, '\n')
assert(text:find('COMPONENT_REF train index=2', 1, true), 'invalid first native element does not lose the iterator callback')
assert(text:find('COMPONENT_REF train index=3', 1, true), 'native component iterator reaches its final element')
assert(text:find('Heat"] type=FloatProperty offset=0 value=0.75', 1, true), 'native owned heat component values are captured')
assert(text:find('Jammed"] type=BoolProperty offset=4 value=false', 1, true), 'native component field enumeration preserves false')
assert(not text:find('COMPONENT_ARRAY_ERROR', 1, true) and not text:find('ENUMERATION_ERROR', 1, true),
    'native array and nested class enumeration do not corrupt their callback stacks')

-- Compact observations enumerate relevant fields even without an earlier F9.
local cold_lines = {}
local cold = Diagnostics.new({emit = function(line) cold_lines[#cold_lines + 1] = line end})
assert(cold:observe('before-first-snapshot', train))
local cold_text = table.concat(cold_lines, '\n')
assert(cold_text:find('VALUE "Train Health"=75', 1, true), 'cold observation reaches health after the irrelevant first property')
assert(cold_text:find('VALUE "Overheating"=false', 1, true), 'cold observation captures heat state')
assert(cold_text:find('VALUE "Heat"=0.25', 1, true), 'cold observation includes numeric heat')

-- The latest real report lost Easy Save Ref behind 2,000 native scene fields.
-- Its child svrSubClass was also omitted from value selection. Prove both
-- bridges and their maps are reached before inherited/visual metadata.
local function named_function(name, fields)
    local value = class('Function /Game/EasySave/easySaveObject.easySaveObject_C:' .. name, fields or {})
    function value:GetFName() return {ToString = function() return name end} end
    setmetatable(value, {__call = function() error('diagnostics must never invoke a save getter/setter') end})
    return value
end
local function native_map(keys, values)
    local underlying = native.array(values)
    return {
        type = function() return 'TMap' end,
        ForEach = function(_, callback)
            underlying:ForEach(function(index, value)
                -- Preserve the callback result so a regression to false hits
                -- the actual retained-callback stack failure in our fixture.
                return callback(remote(keys[index]), value)
            end)
        end,
    }
end
local health_key = {type = function() return 'FString' end, ToString = function() return 'Player Health' end}
local save_floats = native_map({health_key, 'Train Health'}, {remote(73), remote(0)})
local save_bools = native_map({'Dead'}, {remote(false)})
local get_float = named_function('GetFloatValue', {
    property('KeyName', 'StrProperty', 0), property('ReturnValue', 'FloatProperty', 16),
})
local set_float = named_function('SetFloatValue', {
    property('KeyName', 'StrProperty', 0), property('Value', 'FloatProperty', 16),
})
local saving_class = class('BlueprintGeneratedClass /Game/EasySave/savingClass.savingClass_C', {
    property('bool', 'MapProperty', 80), property('float', 'MapProperty', 0),
}, {get_float, set_float})
local save_data = actor('savingClass_C /Engine/Transient.savingClass_C_1', saving_class, {
    float = save_floats, bool = save_bools,
})
function save_data:GetWorld() return nil end -- A live SaveGame object has no World.
local load_value = named_function('EasyLoadValue', {property('ValueAsFloat', 'FloatProperty', 0)})
local save_value = named_function('EasySaveValue', {property('KeyValue', 'StrProperty', 0)})
local easy_class = class('BlueprintGeneratedClass /Game/EasySave/easySaveObject.easySaveObject_C', {
    property('svrSubClass', 'ObjectProperty', 560), property('KeyName', 'StrProperty', 568),
}, {load_value, save_value})
local easy = actor('easySaveObject_C /Game/Island.Island:PersistentLevel.easySaveObject_2', easy_class, {
    svrSubClass = save_data, KeyName = 'last-used-key',
})
local scene_props = {}
for index = 1, 900 do scene_props[index] = property('UnrelatedSceneField' .. index, 'FloatProperty', index * 4) end
scene_props[#scene_props + 1] = property('bCanBeDamaged', 'BoolProperty', 4000)
local huge_native = class('Class /Script/Engine.Actor', scene_props)
local widget_class = class('Class /Script/UMG.WidgetComponent', scene_props)
local ui = actor('WidgetComponent /Game/Island.Island:PersistentLevel.Player_2.Stats', widget_class, {bCanBeDamaged = false})
local bridge_player_class = class('BlueprintGeneratedClass /Game/Player.Player_C', {
    property('varHealthMain', 'FloatProperty', 16),
    property('HUD Stats', 'ObjectProperty', 24),
    property('Easy Save Ref', 'ObjectProperty', 32),
}, {}, huge_native)
local bridge_player = actor('Player_C /Game/Island.Island:PersistentLevel.Player_2', bridge_player_class, {
    varHealthMain = 100, ['HUD Stats'] = ui, ['Easy Save Ref'] = easy, bCanBeDamaged = false,
})
local bridge_lines = {}
local bridge = Diagnostics.new({max_properties = 60, emit = function(line) bridge_lines[#bridge_lines + 1] = line end})
assert(bridge:snapshot('save-bridge', {player = bridge_player}))
local bridge_text = table.concat(bridge_lines, '\n')
local data_path = 'player["Easy Save Ref"]["svrSubClass"]'
assert(bridge_text:find('PROPERTY player["Easy Save Ref"]["svrSubClass"] type=ObjectProperty offset=560 value=', 1, true),
    'live svrSubClass reference is read, not metadata-only')
local bridge_at = assert(bridge_text:find('NESTED_OBJECT ' .. data_path, 1, true))
local ui_at = assert(bridge_text:find('NESTED_OBJECT player["HUD Stats"]', 1, true))
assert(bridge_at < ui_at, 'save data precedes cosmetic Stats widgets')
assert(bridge_text:find('MAP_ENTRY ' .. data_path .. '["float"]["Player Health"]=73', 1, true),
    'native map keys unwrap FString and preserve the actual value')
assert(bridge_text:find('MAP_ENTRY ' .. data_path .. '["float"]["Train Health"]=0', 1, true),
    'native map iteration reaches its second entry and preserves zero')
assert(bridge_text:find('MAP_ENTRY ' .. data_path .. '["bool"]["Dead"]=false', 1, true),
    'native map boolean false survives parameter unwrap')
for _, name in ipairs({'EasyLoadValue', 'EasySaveValue', 'GetFloatValue', 'SetFloatValue'}) do
    assert(bridge_text:find('FUNCTION Function /Game/EasySave/easySaveObject.easySaveObject_C:' .. name, 1, true),
        'save schema captured without calling ' .. name)
end
assert(bridge_text:find('native_unrelated_skipped=900', 1, true), 'large native field sets are filtered with explicit counts')
assert(not bridge_text:find('TRUNCATED', 1, true) and not bridge_text:find('ENUMERATION_', 1, true),
    'save bridge and native maps fit the small budget without iterator failures')

local map_bound_lines = {}
local map_bound = Diagnostics.new({max_map_entries = 1, emit = function(line) map_bound_lines[#map_bound_lines + 1] = line end})
assert(map_bound:snapshot('bounded-save-map', {player = bridge_player}))
local map_bound_text = table.concat(map_bound_lines, '\n')
assert(map_bound_text:find('TRUNCATED map values; total_map_entry_limit=1', 1, true), 'map cap is explicit')
assert(map_bound_text:find('MAP_ENTRY ' .. data_path .. '["float"]["Player Health"]=73', 1, true),
    'float maps take priority over earlier boolean maps within the entry cap')
assert(not map_bound_text:find('MAP_ENTRY ' .. data_path .. '["float"]["Train Health"]', 1, true), 'true safely stops at the map bound')

save_data.values.float = {type = function() return 'UnsupportedMap' end}
bridge_lines = {}
assert(bridge:snapshot('unsupported-save-map', {player = bridge_player}))
bridge_text = table.concat(bridge_lines, '\n')
assert(bridge_text:find('MAP_ENUMERATION_UNAVAILABLE ' .. data_path .. '["float"]', 1, true), 'unsupported container API is explicit')
save_data.values.float = save_floats

-- Merely naming a numeric field svrSubClass must not turn it into a pointer.
local wrong_easy_class = class('BlueprintGeneratedClass /Game/EasySave/easySaveObject.easySaveObject_C', {
    property('svrSubClass', 'FloatProperty', 560),
})
local wrong_easy = actor('easySaveObject_C /Game/Island.Island:PersistentLevel.easySaveObject_3', wrong_easy_class, {svrSubClass = 42})
bridge_player.values['Easy Save Ref'] = wrong_easy
bridge_lines = {}
assert(bridge:snapshot('wrong-save-bridge-type', {player = bridge_player}))
bridge_text = table.concat(bridge_lines, '\n')
assert(not bridge_text:find('NESTED_OBJECT ' .. data_path, 1, true), 'only reflected object properties are traversed')

print('diagnostics regressions passed: native v4 nil iterators; primary fields/schemas; save bridge priority; bounded read-only TMaps; native-noise filtering; native arrays; cold observations')
