-- End-to-end Lua control wiring with a small engine boundary mock.
-- This verifies inputs, scoping and hook argument handling, NOT game behavior.
local scripts = os.getenv("CCC_MOD_SCRIPTS") or "./Mod/ChooChooCharles_GodMode/Scripts"
package.path = scripts .. "/?.lua;" .. package.path
local RealHUD = require("hud")
local check_count = 0
local function check(value, message) assert(value,message); check_count=check_count+1 end
-- Exact names/types observed in report_104224; values below simulate active
-- gameplay so the control wiring can be tested without running Unreal.
local heat_schema={
    {"Machine Gun Jamming","FloatProperty"},{"Machine Gun Jammed","BoolProperty"},
    {"Range Gun Jamming","FloatProperty"},{"Range Gun Jammed","BoolProperty"},
    {"Flamethrower Jamming","FloatProperty"},{"Flamethrower Jammed","BoolProperty"},
    {"Machine Gun Jam THRESHHOLD","FloatProperty"},{"Range Gun Jam THRESHHOLD","FloatProperty"},
    {"Flamethrower Jam THRESHHOLD","FloatProperty"},{"Fire Rate","FloatProperty"},
}
local serial = 100
local function object(class,name,world,fields)
    serial=serial+1
    local o=fields or {}; o.id=serial; o.classname=class; o.name=name; o.world=world; o.valid=true
    function o:IsValid() return self.valid end
    function o:GetAddress() return self.id end
    function o:GetFullName()
        self.fullname_reads = (self.fullname_reads or 0) + 1
        return self.classname .. " " .. self.name
    end
    function o:GetWorld() return self.world end
    function o:IsA(path) return path:match("([^%.]+)$")==self.classname end
    function o:GetClass()
        local class_name=self.classname
        return {IsValid=function() return true end,GetFName=function() return {ToString=function() return class_name end} end,
            GetFullName=function()
                if class_name=="PlayerTrain_C" then
                    return "BlueprintGeneratedClass /Game/_GAME/Blueprints/TrainBlueprints/PlayerTrain.PlayerTrain_C"
                end
                return "BlueprintGeneratedClass /Game/Test." .. class_name
            end,
            GetSuperStruct=function() return nil end,ForEachProperty=function(_, callback)
                if class_name ~= "PlayerTrain_C" then return end
                for _, field in ipairs(heat_schema) do
                    local prop={}
                    function prop:GetFName() return {ToString=function() return field[1] end} end
                    function prop:GetClass() return {GetFName=function() return {ToString=function() return field[2] end} end} end
                    local result=callback(prop)
                    assert(result ~= false,"UE4SS 4 iterator must continue with nil")
                    if result == true then break end
                end
            end}
    end
    function o:GetPropertyValue(n) return rawget(self,n) end
    function o:GetCanBeDamaged() return self.bCanBeDamaged end
    function o:SetCanBeDamaged(v) self.bCanBeDamaged=v end
    return o
end
local world=object("World","/Game/Island_a_Landscape/Maps/Photorealistic_Island.Photorealistic_Island")
local menu_world=object("World","/Game/_GAME/MainMenu/MainMenu_Level.MainMenu_Level")
local prefix="/Game/Island_a_Landscape/Maps/Photorealistic_Island.Photorealistic_Island:PersistentLevel."
local player=object("BP_NMCharacter_Player_C",prefix.."Player",world,{varHealthMain=100,varHealth=0,["Dead?"]=false,bCanBeDamaged=true,NightmareMode=true})
local train=object("PlayerTrain_C",prefix.."PlayerTrain_4",world,{bCanBeDamaged=true,
    ["Machine Gun Jamming"]=7.5841679573059,["Machine Gun Jammed"]=true,
    ["Range Gun Jamming"]=0,["Range Gun Jammed"]=false,
    ["Flamethrower Jamming"]=0,["Flamethrower Jammed"]=false,
    ["Machine Gun Jam THRESHHOLD"]=38.5,["Range Gun Jam THRESHHOLD"]=10.8000001907,
    ["Flamethrower Jam THRESHHOLD"]=15,["Fire Rate"]=0.1})
local charles=object("CharlesCharacter_C",prefix.."CharlesCharacter_2",world,{bCanBeDamaged=true,
    ["Damage to Player"]=25,["Damage to Player on Train"]=20,["Damage to Train"]=15,
    ["Face Damage Multiplier"]=2,["Body Damage Multiplier"]=1,["Legs Damage Multiplier"]=0.5,NightmareMode=true})
player["Train Ref"]=train; player["Charles Ref"]=charles
local menu_train=object("PlayerTrain_C","/Game/_GAME/MainMenu/MainMenu_Level.MainMenu_Level:PersistentLevel.PlayerTrain_5",menu_world,{bCanBeDamaged=true})
local controller=object("PlayerController",prefix.."Controller",world,{Pawn=player})
function controller:IsLocalPlayerController() return true end
local viewport=object("GameViewportClient","/Engine/Transient.GameViewport",world)
local engine=object("Engine","/Engine/Transient.Engine",nil,{GameViewport=viewport})
local registry={PlayerController={controller},BP_NMCharacter_Player_C={player},PlayerTrain_C={menu_train,train},CharlesCharacter_C={charles}}
local searches={all=0,first=0}
FindAllOf=function(n) searches.all=searches.all+1; return registry[n] end
FindFirstOf=function(n) searches.first=searches.first+1; if n=="Engine" then return engine end end
local loaded_function=object("Function","/Game/MockFunction")
local damage_path="/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C:Damage"
local damage_function=object("Function",damage_path)
function damage_function:GetFunctionFlags() return 0xC020000 end
function damage_function:ForEachProperty(callback)
    for _, field in ipairs({{"Damage Applied","FloatProperty"},{"Slowing Multiplier","FloatProperty"},{"Hit Component","ObjectProperty"}}) do
        local property={}
        function property:GetFName() return {ToString=function() return field[1] end} end
        function property:GetClass() return {GetFName=function() return {ToString=function() return field[2] end} end} end
        local result=callback(property)
        assert(result~=false,"guard reflection must continue with nil")
        if result==true then break end
    end
end
StaticFindObject=function(path) if path==damage_path then return damage_function end; return loaded_function end
UE4SS={GetVersion=function() return 4,0,0 end}
UnrealVersion={IsEqual=function(major,minor) return major==4 and minor==26 end}
-- This mocks only the native DLL boundary. It cannot verify native bytecode
-- changes; those require the companion tests and a live game run.
local guard_native={active=false,calls={},codes={},loads=0}
package.loadlib=function(path,symbol)
    check(path:sub(-21)=="/native/ccc_guard.dll","guard loads its scoped native companion")
    local action=symbol:match("^ccc_guard_(%a+)$")
    assert(action=="enable" or action=="disable" or action=="check","known guard entry point")
    guard_native.loads=guard_native.loads+1
    return function(...)
        local args=table.pack(...)
        assert(args.n==16,"guard native bridge receives sixteen sentinels")
        for i=1,args.n do assert(args[i]==false,"guard native sentinels are false") end
        guard_native.calls[#guard_native.calls+1]=action
        local code=guard_native.codes[action] or 0
        if code==0 then
            if action=="enable" then guard_native.active=true
            elseif action=="disable" then guard_native.active=false
            elseif not guard_native.active then code=9 end
        end
        return table.unpack(args,1,code)
    end
end
local binds,hooks={},{}
Key={F6=6,F7=7,F8=8,F9=9,F10=10,F11=11}
RegisterKeyBind=function(...)
    local arguments=table.pack(...)
    check(arguments.n==2 and type(arguments[2])=="function","no Ctrl modifier registered")
    binds[arguments[1]]=arguments[2]
end
RegisterHook=function(path,callback) hooks[path]=callback; return 1,2 end
ExecuteInGameThread=function(fn) fn() end
local timers={}
LoopInGameThreadWithDelay=function(ms,fn)
    check(ms==50 or ms==16,"game-thread protection/heat intervals")
    timers[ms]=fn; return ms
end
NotifyOnNewObject=function() end
RegisterBeginPlayPostHook=function(fn) _G.beginplay=fn end
local snapshots,snapshot_modes={},{}
package.loaded.diagnostics={new=function() return {
    snapshot=function(_,label,actors,modes)
        if not actors.player then return false,"no gameplay" end
        snapshots[#snapshots+1]=label; snapshot_modes[#snapshot_modes+1]=modes
        return true,"mock-"..#snapshots
    end,event=function() end,observe=function() end,
} end}
package.loaded.hud={new=function(deps)
    local h={visible=true}
    function h:update() self.updates=(self.updates or 0)+1; self.text=RealHUD.format_text(deps.get_view()); return true end
    function h:set_visible(v) self.visible=v; self:update() end
    function h:is_visible() return self.visible end
    return h
end}
-- Load with an isolated filename so the real append/rotation code cannot alter
-- development logs or the deliverable. run_lua_tests.py creates this directory.
local f=assert(io.open(scripts .. "/main.lua","r")); local source=f:read("*a"); f:close()
local runtime = assert(os.getenv("CCC_TEST_ROOT"), "run through run_lua_tests.py for isolated log output")
local chunk=assert(load(source,"@" .. runtime .. "/Scripts/main.lua"))
local mod=chunk(); mod.step()
check(mod.core.ready.player and mod.core.ready.train and mod.core.ready.double,"gameplay actors bound")
check(mod.playerguard.ready and guard_native.active and mod.modes_view().player.ready,
    "player HUD readiness requires the verified native entry guard as well as core state")
check(guard_native.loads==3,"exactly one set of native guard exports loaded")
check(mod.noheat.enabled and mod.noheat.ready and train["Machine Gun Jamming"]==0
    and train["Machine Gun Jammed"]==false,"no-heat enabled and applied to the exact game state by default")
check(timers[16]~=nil and timers[50]~=nil,"independent heat and existing protection timers")
check(train["Fire Rate"]==0.1 and train["Machine Gun Jam THRESHHOLD"]==38.5
    and train["Range Gun Jam THRESHHOLD"]==10.8000001907 and train["Flamethrower Jam THRESHHOLD"]==15,
    "no heat leaves fire rate and actual thresholds unchanged")
check(menu_train.bCanBeDamaged==true,"menu train untouched")
check(mod.hud.text:find("F6 God Mode: ON",1,true),"initial F6 label")
-- A minute of ordinary maintenance exercises the actual orchestrator, with
-- call budgets at the engine/native boundaries rather than mock elapsed FPS.
local benchmark={all=searches.all,first=searches.first,heat=mod.noheat.checks,
    names=charles.fullname_reads,enable=mod.playerguard.native_enable_calls,
    verify=mod.playerguard.native_check_calls,opens=mod.logger:snapshot().file_opens}
for _=1,1200 do timers[50]() end
check(searches.all==benchmark.all and searches.first==benchmark.first,
    "stable gameplay uses retained context without global object-array searches")
check(mod.playerguard.native_enable_calls==benchmark.enable,
    "stable maintenance does not reinstall the working native guard")
check(mod.playerguard.native_check_calls-benchmark.verify==60 and mod.playerguard.ready and guard_native.active,
    "one minute of maintenance performs60 guard checks while protection stays armed")
check(charles.fullname_reads-benchmark.names<=1200,
    "six core patch fields share a single Charles name per maintenance pass")
check(mod.noheat.checks==benchmark.heat,
    "healthy dedicated heat timer is not duplicated by the50ms loop")
check(#snapshots==0 and mod.counters.full_snapshots==0 and mod.counters.compact_snapshots>=3,
    "bind and periodic diagnostics never start full reflection dumps")
check(mod.logger:snapshot().file_opens-benchmark.opens<=6,
    "steady-state diagnostics produce a few batches rather than per-line file opens")
train["Machine Gun Jamming"]=5; train["Machine Gun Jammed"]=true; timers[16]()
check(train["Machine Gun Jamming"]==0 and train["Machine Gun Jammed"]==false,
    "dedicated heat loop still clears a live counter and jam latch after long stable play")
local heat_before_fallback=mod.noheat.checks
mod.state.heat_scheduled=false; timers[50](); mod.state.heat_scheduled=true
check(mod.noheat.checks==heat_before_fallback+1,"50ms heat fallback remains active when independent timer is absent")
print("PERFORMANCE CALL BUDGET:1200 maintenance callbacks;60 native checks,0 native reinstalls,0 global searches,0 full automatic dumps")
binds[6]()
check(mod.hud.text:find("F6 God Mode: OFF",1,true),"plain F6 flips displayed state")
check(not mod.playerguard.armed and not guard_native.active,"F6 OFF restores the guarded player function")
check(mod.core.enabled.train and mod.core.enabled.double,"F6 independent")
binds[7]()
check(mod.hud.text:find("F7 Train God Mode: OFF",1,true),"plain F7 label")
binds[8]()
check(mod.hud.text:find("F8 Double Damage: OFF",1,true),"plain F8 label")
check(not mod.playerguard.enabled and not guard_native.active,"F7/F8 cannot reactivate an OFF player guard")
check(charles["Body Damage Multiplier"]==1,"F8 OFF restored original")
binds[11](); check(not mod.hud.visible,"F11 hides")
check(not mod.core.enabled.player and not mod.core.enabled.train,"hide doesn't enable modes")
binds[9](); check(#snapshots==1,"F9 captures even when hidden")
binds[11](); check(mod.hud.visible,"F11 shows")
local guard_before_heat=#guard_native.calls
binds[10](); check(not mod.noheat.enabled and mod.hud.text:find("F10 No Overheat: OFF",1,true),"F10 independently disables heat cooling")
train["Machine Gun Jamming"]=11.0009851456; timers[16]()
check(train["Machine Gun Jamming"]==11.0009851456,"F10 OFF resumes normal heat accumulation")
binds[10](); check(mod.noheat.enabled and train["Machine Gun Jamming"]==0,"F10 ON clears current heat")
check(not mod.core.enabled.player and not mod.core.enabled.train and not mod.core.enabled.double,"F10 does not change other toggles")
train["Machine Gun Jamming"]=0.2; train["Range Gun Jamming"]=0.3; train["Flamethrower Jamming"]=0.4
timers[16]()
check(train["Machine Gun Jamming"]==0 and train["Range Gun Jamming"]==0
    and train["Flamethrower Jamming"]==0,"fast heat timer maintains all three gun states")
check(#guard_native.calls==guard_before_heat,"heat toggles and 16ms maintenance never change the player entry guard")
binds[6](); binds[7](); binds[8]()
check(mod.playerguard.ready and guard_native.active,"F7/F8 preserve an enabled player guard")
local function remote(value)
    return {get=function() return value end,set=function(_,v) value=v end}
end
local dmg=remote(50)
hooks["/Script/Engine.GameplayStatics:ApplyDamage"](remote(nil),remote(player),dmg)
check(dmg:get()==0,"native incoming player damage zeroed in pre callback")
local other=object("Cultist_C",prefix.."Enemy",world)
dmg=remote(50)
hooks["/Script/Engine.GameplayStatics:ApplyDamage"](remote(nil),remote(other),dmg)
check(dmg:get()==50,"native unrelated outgoing damage unchanged")

-- A native entry guard failure must be visible even while the established
-- Charles damage fields and native actor flags still appear ready.
guard_native.codes.check=9
for _=1,20 do timers[50]() end
check(mod.core.ready.player and not mod.playerguard.ready and not mod.modes_view().player.ready,
    "working core fields cannot conceal failed entry-guard readback")
local captures_before=#snapshots
binds[9]()
check(#snapshots==captures_before+1 and snapshot_modes[#snapshot_modes].player_ready==false,
    "F9 records combined player readiness after checking the native guard")
check(mod.hud.text:find("F6 God Mode: ON (NOT READY)",1,true),"failed native entry guard is shown on the HUD")
check(mod.core.enabled.train and mod.core.enabled.double and mod.noheat.ready,
    "entry-guard failure does not disable train protection, double damage or no heat")
guard_native.codes.check=0
for _=1,4 do timers[50]() end
check(mod.modes_view().player.ready and not mod.hud.text:find("F6 God Mode: ON (NOT READY)",1,true),
    "successful later readback restores honest HUD readiness")

guard_native.codes.disable=6; binds[6]()
check(not mod.core.enabled.player and mod.playerguard.restoring and guard_native.active,
    "a failed F6 OFF restore retains ownership until restoration succeeds")
check(mod.modes_view().player.restoring and mod.hud.text:find("F6 God Mode: OFF (RESTORING)",1,true),
    "HUD exposes a pending native restoration")
guard_native.codes.disable=0
for _=1,4 do timers[50]() end
check(not mod.playerguard.restoring and not guard_native.active and not mod.modes_view().player.restoring,
    "regular maintenance retries and completes an OFF restoration")
check(not mod.hud.text:find("OFF (RESTORING)",1,true),"completed restoration clears the HUD notice")
binds[6]()
check(mod.modes_view().player.ready and guard_native.active,"player guard can be enabled after restoration")

local guard_before_beginplay=#guard_native.calls
beginplay(remote(player))
check(#guard_native.calls==guard_before_beginplay+1 and mod.playerguard.ready,
    "BeginPlay checks the entry guard at a game-thread safe point")
local guard_before_post=#guard_native.calls
captures_before=#snapshots
local compact_before=mod.counters.compact_snapshots
local hud_before=mod.hud.updates
local opens_before=mod.logger:snapshot().file_opens
hooks[damage_path](remote(player),remote(0))
check(#guard_native.calls==guard_before_post,"Blueprint Damage POST never mutates the function that is executing")
check(#snapshots==captures_before and mod.hud.updates==hud_before and mod.logger:snapshot().file_opens==opens_before,
    "player Damage POST queues compact evidence without reflection, HUD work or file I/O inline")
timers[50]()
check(#snapshots==captures_before and #guard_native.calls==guard_before_post
    and mod.counters.compact_snapshots==compact_before+1 and mod.hud.updates==hud_before+1,
    "the next safe timer updatesHUD and recordscompact evidence without native reinstallation or deep reflection")

-- The cache must not keep an old controller through map travel, even while
-- that controller remains valid and reports itself as local.
local next_world=object("World","/Game/Test/NextMap.NextMap")
local next_controller=object("PlayerController","/Game/Test/NextMap.NextMap:PersistentLevel.Controller",next_world,{})
function next_controller:IsLocalPlayerController() return true end
registry.PlayerController={controller,next_controller}; viewport.world=next_world
local discovery_before=searches.all
mod.scan()
check(mod.state.controller==next_controller and not mod.core.actors.player and not mod.core.actors.train,
    "viewport world change rejects retained old-world controller and actors")
check(searches.all>discovery_before,"world change triggers required discovery")
timers[50]()
check(not guard_native.active and not mod.playerguard.ready,"leaving the gameplay player restores owned guard at a safe point")
viewport.world=world; registry.PlayerController={controller}; mod.state.needs_scan=true; timers[50]()
check(mod.core.actors.player==player and mod.playerguard.ready and guard_native.active and mod.noheat.ready,
    "returning gameplay rebinds and immediately restores the working protection and cooling")

binds[7](); dmg=remote(50)
hooks["/Script/Engine.GameplayStatics:ApplyPointDamage"](remote(nil),remote(train),dmg)
check(dmg:get()==50,"disabled train native damage untouched")
check(mod.playerguard.ready and guard_native.active,"F7 OFF leaves player entry protection active")
player.varHealthMain=0; player["Dead?"]=true
guard_before_post=#guard_native.calls
hooks[damage_path](remote(player),remote(500))
check(player.varHealthMain==0 and player["Dead?"]==true,"Blueprint post hook never masquerades as cancellation")
check(#guard_native.calls==guard_before_post,"even a lethal POST observation does not install/remove the entry guard inline")
check(mod.playerguard.ready and not mod.core.ready.player and not mod.modes_view().player.ready,
    "an armed entry guard cannot conceal an independently observed core protection gap")
timers[50]()
check(mod.hud.text:find("F6 God Mode: ON (NOT READY)",1,true),"observed protection failure visible")
print("PASS main: "..check_count.." checks; performance call budgets, map travel, protection/heat timing, native guard restoration, HUD and damage parameters")
