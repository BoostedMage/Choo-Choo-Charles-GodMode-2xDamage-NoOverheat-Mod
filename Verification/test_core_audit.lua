-- Independent semantic regression tests for actual damage-property behavior.
local scripts = os.getenv('CCC_MOD_SCRIPTS') or './Mod/ChooChooCharles_GodMode/Scripts'
local Core = dofile(scripts .. '/core.lua')
local function fixture(initial_hp)
    local player = {name='player', fields={varHealthMain=initial_hp or 100, varHealth=0, ['Dead?']=false, bCanBeDamaged=true}}
    local train = {name='train', fields={bCanBeDamaged=true, Health=77}}
    local charles = {name='charles', fields={
        ['Damage to Player']=25, ['Damage to Player on Train']=20, ['Damage to Train']=15,
        ['Face Damage Multiplier']=2, ['Body Damage Multiplier']=1, ['Legs Damage Multiplier']=0.5,
        ['Can Damage']=true, NightmareMode=true,
    }}
    local writes, events = {}, {}
    local fail
    local c = Core.new({
        valid=function(o) return o ~= nil and o.live ~= false end,
        identity=function(o) return o.name end,
        read=function(o,k) return o and o.fields[k] end,
        write=function(o,k,v)
            if fail and fail(o,k,v) then return false end
            writes[#writes+1] = {o.name,k,v}
            o.fields[k] = v
            return true
        end,
        event=function(e) events[#events+1]=e end,
    })
    c:set_actors({player=player,train=train,charles=charles})
    return c,player,train,charles,writes,events,function(fn) fail=fn end
end

local c,p,t,b,w,e = fixture()
c:refresh('bind')
assert(c.ready.player and c.ready.train and c.ready.double)
assert(b.fields['Damage to Player']==0 and b.fields['Damage to Player on Train']==0 and b.fields['Damage to Train']==0)
assert(b.fields['Face Damage Multiplier']==4 and b.fields['Body Damage Multiplier']==2 and b.fields['Legs Damage Multiplier']==1)
assert(p.fields.bCanBeDamaged==false and t.fields.bCanBeDamaged==false)
assert(p.fields.varHealth==0 and p.fields.varHealthMain==100 and t.fields.Health==77)
for i=1,100 do c:refresh('poll') end
assert(b.fields['Face Damage Multiplier']==4, 'polling must never compound 2x damage')
c:set_enabled('player',false)
assert(b.fields['Damage to Player']==25 and b.fields['Damage to Player on Train']==20)
assert(b.fields['Damage to Train']==0 and b.fields['Face Damage Multiplier']==4, 'F6 must not turn off F7 or F8')
assert(p.fields.bCanBeDamaged==true and t.fields.bCanBeDamaged==false)
p.fields.varHealthMain=65; c:refresh('damage while off')
assert(p.fields.varHealthMain==65, 'F6 OFF must stop health recovery')
c:set_enabled('train',false)
assert(b.fields['Damage to Train']==15 and t.fields.bCanBeDamaged==true)
c:set_enabled('double',false)
assert(b.fields['Face Damage Multiplier']==2 and b.fields['Body Damage Multiplier']==1 and b.fields['Legs Damage Multiplier']==0.5)
for i=1,5 do c:set_enabled('double',true); c:set_enabled('double',false) end
assert(b.fields['Face Damage Multiplier']==2, 'toggle cycles must restore exact baselines')
assert(b.fields['Can Damage']==true and b.fields.NightmareMode==true, 'independent modes must not disable global attacks or change difficulty')
for _,write in ipairs(w) do
    assert(not (write[1]=='train' and write[2]~='bCanBeDamaged'), 'no guessed train health or stat writes')
end

-- Difficulty/boss data reset supplies a fresh observed value; restore that value.
c:set_enabled('double',true)
b.fields['Face Damage Multiplier']=3
c:refresh('phase data reset')
assert(b.fields['Face Damage Multiplier']==6)
c:set_enabled('double',false)
assert(b.fields['Face Damage Multiplier']==3)

-- Recover nonlethal damage but report that a protection route was bypassed.
local gap, gp, gt, gb, gw, ge = fixture()
gap:refresh('bind')
gp.fields.varHealthMain=72
gap:refresh('custom hit')
assert(gp.fields.varHealthMain==100 and gap.recoveries==1)
assert(gap.breached.player and not gap.ready.player and #ge==1)
gp.fields.varHealthMain=0; gp.fields['Dead?']=true
local before=#gw
gap:refresh('lethal branch')
assert(gp.fields.varHealthMain==0 and gp.fields['Dead?']==true, 'never claim to undo an executed lethal branch')
for i=before+1,#gw do assert(gw[i][2]~='varHealthMain' and gw[i][2]~='Dead?') end

-- A class default observed before initialization must not count as a death.
local init, ip = fixture(0)
init:refresh('before initialization')
assert(not init.ready.player and not init.breached.player)
ip.fields.varHealthMain=100
init:refresh('after initialization')
assert(init.ready.player and not init.breached.player)

-- Failed readback never marks the mode ready.
local failcore, fp, ft, fb, fw, fe, set_failure = fixture()
set_failure(function(object,name,value) return object==fb and name=='Body Damage Multiplier' and value==2 end)
failcore:refresh('injected write failure')
assert(not failcore.ready.double and fb.fields['Body Damage Multiplier']==1)

-- Rebinding restores the old actor and does not transfer its baseline to the new actor.
local rebound, rp, rt, rb = fixture()
rebound:refresh('first actor')
local fresh={name='charles-next',fields={
    ['Damage to Player']=35,['Damage to Player on Train']=22,['Damage to Train']=18,
    ['Face Damage Multiplier']=3,['Body Damage Multiplier']=2,['Legs Damage Multiplier']=1,
}}
rebound:set_actors({player=rp,train=rt,charles=fresh})
assert(rb.fields['Damage to Player']==25 and rb.fields['Face Damage Multiplier']==2)
rebound:refresh('replacement actor')
assert(fresh.fields['Damage to Player']==0 and fresh.fields['Face Damage Multiplier']==6)
print('independent core damage semantics passed')
