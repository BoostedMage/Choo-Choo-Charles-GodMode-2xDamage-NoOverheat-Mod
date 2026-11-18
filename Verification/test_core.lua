local scripts = os.getenv("CCC_MOD_SCRIPTS") or "./Mod/ChooChooCharles_GodMode/Scripts"
package.path = scripts .. "/?.lua;" .. package.path
local Core = require("core")
local checks = 0
local function check(condition, message)
    assert(condition, message); checks = checks + 1
end
local next_id = 0
local function actor(properties)
    next_id = next_id + 1
    return {id = next_id, properties = properties, valid = true}
end
-- Values copied from the user's actual reflection log. Unknown writes fail.
local function fixture()
    return {
        player = actor({varHealthMain=100, varHealth=0, ["Dead?"]=false, bCanBeDamaged=true, NightmareMode=true}),
        train = actor({bCanBeDamaged=true}),
        charles = actor({["Damage to Player"]=25, ["Damage to Player on Train"]=20, ["Damage to Train"]=15,
            ["Face Damage Multiplier"]=2, ["Body Damage Multiplier"]=1, ["Legs Damage Multiplier"]=0.5,
            ["Can Damage"]=true, NightmareMode=true}),
    }
end
local messages, writes = {}, {}
local core = Core.new({
    valid=function(o) return o ~= nil and o.valid end,
    identity=function(o) return o.id end,
    read=function(o,n) return o and o.properties[n] end,
    write=function(o,n,v)
        assert(o.properties[n] ~= nil, "invented field write: " .. n)
        if o.fail == n then return false end
        o.properties[n] = v; writes[#writes+1] = n; return true
    end,
    log=function(s) messages[#messages+1]=s end,
    event=function(s) messages[#messages+1]=s end,
})
local a=fixture()
core:set_actors(a); core:refresh()
check(a.charles.properties["Damage to Player"]==0, "actual player damage source zero")
check(a.charles.properties["Damage to Player on Train"]==0, "on-train player source zero")
check(a.charles.properties["Damage to Train"]==0, "train source zero")
check(a.charles.properties["Face Damage Multiplier"]==4, "face 2x")
check(a.charles.properties["Body Damage Multiplier"]==2, "body 2x")
check(a.charles.properties["Legs Damage Multiplier"]==1, "legs 2x")
check(a.charles.properties["Can Damage"]==true, "independent toggle does not globally disable Charles")
check(a.player.properties.varHealth==0 and a.player.properties.varHealthMain==100, "unused varHealth untouched")
check(core.ready.player and core.ready.train and core.ready.double, "readback readiness")
local write_count=#writes
for _=1,200 do core:refresh() end
check(#writes==write_count, "steady polling does not rewrite/compound multipliers")

core:set_enabled("player",false)
check(a.charles.properties["Damage to Player"]==25 and a.charles.properties["Damage to Player on Train"]==20, "F6 restores player sources")
check(a.charles.properties["Damage to Train"]==0, "F6 preserves train mode")
check(a.player.properties.bCanBeDamaged==true and a.train.properties.bCanBeDamaged==false, "native modes independent")
core:set_enabled("train",false)
check(a.charles.properties["Damage to Train"]==15, "F7 restores original train source")
check(a.charles.properties["Body Damage Multiplier"]==2, "F6/F7 do not affect F8")
core:set_enabled("double",false)
check(a.charles.properties["Face Damage Multiplier"]==2 and a.charles.properties["Body Damage Multiplier"]==1 and a.charles.properties["Legs Damage Multiplier"]==0.5,"F8 exact baseline restore")

a.player.properties.varHealthMain=75; core:refresh()
core:set_enabled("player",true)
check(a.player.properties.varHealthMain==75, "enabling does not invent max health")
a.player.properties.varHealthMain=65; core:refresh("simulated nonlethal custom route")
check(a.player.properties.varHealthMain==75 and core.recoveries==1, "bounded nonlethal recovery")
check(core.breached.player and not core.ready.player, "health leak makes HUD not-ready")
a.player.properties.varHealthMain=0; a.player.properties["Dead?"]=true
core:refresh("lethal custom route")
check(a.player.properties.varHealthMain==0 and a.player.properties["Dead?"]==true, "post observation cannot and must not pretend to undo death")

local b=fixture()
b.charles.properties["Damage to Player"]=50
core:set_actors(b); core:set_enabled("train",true); core:set_enabled("double",true); core:refresh()
check(a.charles.properties["Damage to Player"]==25, "old live actor restored during world switch")
check(b.charles.properties["Damage to Player"]==0, "new difficulty source patched")
check(not core.breached.player and core.ready.player, "new living actor has new status")
b.charles.properties["Body Damage Multiplier"]=1.5
core:refresh("phase reset")
check(b.charles.properties["Body Damage Multiplier"]==3, "phase baseline is recaptured once")
core:refresh(); core:refresh()
check(b.charles.properties["Body Damage Multiplier"]==3, "phase multiplier doesn't compound")
core:set_enabled("double",false)
check(b.charles.properties["Body Damage Multiplier"]==1.5, "phase baseline restored")
b.charles.properties["Damage to Player"]=35
core:set_enabled("player",false)
check(b.charles.properties["Damage to Player"]==35, "disable preserves game changes not made by mod")

local c=fixture(); c.player.properties.varHealthMain=0
core:set_actors(c); core:set_enabled("player",true); core:refresh()
check(not core.breached.player and not core.ready.player,"spawn init zero waits without permanent false breach")
c.player.properties.varHealthMain=100; core:refresh()
check(core.ready.player, "initialized health is adopted")
c.charles.fail="Damage to Train"
c.charles.properties["Damage to Train"]=30; core:refresh()
check(not core.ready.train, "readback/write failure clears readiness")
c.player.properties.varHealthMain=nil; core:refresh()
check(not core.ready.player and c.player.properties.varHealth==0, "no fallback to wrong varHealth")
core:close()
check(not core.enabled.player and not core.enabled.train and not core.enabled.double,"close disables all")
local d=fixture(); core:set_actors(d)
core:set_enabled("player",true); core:set_enabled("double",true)
d.charles.fail="Body Damage Multiplier"; core:set_enabled("double",false)
check(d.charles.properties["Body Damage Multiplier"]==2 and core:view().double.restoring,"failed restoration stays pending")
d.charles.fail=nil; core:refresh()
check(d.charles.properties["Body Damage Multiplier"]==1 and not core:view().double.restoring,"pending baseline restored after transient write failure")
d.player.fail="bCanBeDamaged"; core:set_enabled("player",false)
check(d.player.properties.bCanBeDamaged==false and core:view().player.restoring,"native failed restoration retained")
d.player.fail=nil; core:refresh()
check(d.player.properties.bCanBeDamaged==true and not core:view().player.restoring,"native pending restoration retried")
local e=fixture(); e.charles.fail="Body Damage Multiplier"
core:set_actors(e); core:set_enabled("double",true)
e.charles.properties["Body Damage Multiplier"]=1.5; e.charles.fail=nil; core:refresh()
check(e.charles.properties["Body Damage Multiplier"]==3,"first successful write captures post-initialization baseline")
core:set_enabled("double",false)
check(e.charles.properties["Body Damage Multiplier"]==1.5,"failed initial write never freezes a stale restore baseline")
print("PASS core: " .. checks .. " checks; actual field fixtures, restoration, death limit, phase resets")
