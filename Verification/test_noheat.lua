-- The exact names/types in this fixture come from report_104224,
-- CCC_Reflection.log 1317-1329. The simulated state transitions below verify
-- adapter behavior and isolation; they do not execute the game's Blueprint.
local scripts = os.getenv('CCC_MOD_SCRIPTS') or './Mod/ChooChooCharles_GodMode/Scripts'
local NoHeat = dofile(scripts .. '/noheat.lua')
local assertions, next_id = 0, 0
local function check(value, message) assert(value, message); assertions=assertions+1 end
local function named(name)
    return {GetFName=function() return {ToString=function() return name end} end}
end
local function observed_fields()
    return {
        {'Machine Gun Jamming','FloatProperty',7.5841679573059},
        {'Machine Gun Jammed','BoolProperty',true},
        {'Machine Gun Jam THRESHHOLD','FloatProperty',38.5},
        {'Range Gun Jamming','FloatProperty',0},
        {'Range Gun Jammed','BoolProperty',false},
        {'Range Gun Jam THRESHHOLD','FloatProperty',10.8000001907},
        {'Flamethrower Jamming','FloatProperty',0},
        {'Flamethrower Jammed','BoolProperty',false},
        {'Flamethrower Jam THRESHHOLD','FloatProperty',15},
    }
end
local writable = {
    ['Machine Gun Jamming']=0, ['Machine Gun Jammed']=false,
    ['Range Gun Jamming']=0, ['Range Gun Jammed']=false,
    ['Flamethrower Jamming']=0, ['Flamethrower Jammed']=false,
}
local function fixture(descriptors, class_path)
    next_id=next_id+1
    local train={id=next_id, live=true, values={}}
    local props, control={},{}
    for _, item in ipairs(descriptors) do
        local raw_name, kind, value=item[1],item[2],item[3]
        train.values[raw_name]=value
        local p=named(raw_name)
        function p:GetClass() return named(kind) end
        props[#props+1]=p
    end
    local path=class_path or '/Game/_GAME/Blueprints/TrainBlueprints/PlayerTrain.PlayerTrain_C'
    local class=named(path:match('%.([^%.]+)$'))
    class.live=true
    function class:GetFullName() return 'BlueprintGeneratedClass '..path end
    function class:ForEachProperty(callback)
        for i, p in ipairs(props) do
            local result=callback(p)
            assert(result~=false, 'UE4SS iterator continuation must be nil, never false')
            if result==true then return end
            if control.fail_enumeration==i then error('simulated metadata failure') end
        end
    end
    function class:GetSuperStruct() return nil end
    function train:GetClass() return class end
    local writes, logs={},{}
    local module=NoHeat.new({
        valid=function(o) return o~=nil and o.live==true end,
        identity=function(o) return o.id end,
        read=function(o,n)
            if control.fail_read==n then error('simulated read failure') end
            return o.values[n]
        end,
        write=function(o,n,v)
            writes[#writes+1]={object=o,name=n,value=v}
            assert(o.values[n]~=nil, 'never write an unreflected/missing field')
            if control.fail_write==n then return false end
            if control.false_success~=n then o.values[n]=v end
            return true
        end,
        log=function(line) logs[#logs+1]=line end,
    })
    module:set_train(train)
    return module,train,writes,logs,control
end
local function entry(fields, name)
    for _, field in ipairs(fields) do if field.name==name then return field end end
end
local function alter(fields, name, kind, value)
    for _, field in ipairs(fields) do
        if field[1]==name then field[2],field[3]=kind,value; return end
    end
    error('unknown fixture field '..name)
end
local function without(fields, name)
    local result={}
    for _, field in ipairs(fields) do if field[1]~=name then result[#result+1]=field end end
    return result
end

local fields={}
for i=1,300 do fields[#fields+1]={'Component '..i,'ObjectProperty',{}} end
for _, field in ipairs(observed_fields()) do fields[#fields+1]=field end
local protected={
    {'Shooting Machine Gun','BoolProperty',true},
    {'Shooting Range Gun','BoolProperty',false},
    {'Shooting Flamethrower','BoolProperty',true},
    {'Fire Gun Pressed','MulticastInlineDelegateProperty',{}},
    {'Machine Gun Damage','FloatProperty',2},
    {'Range Gun Damage','FloatProperty',7},
    {'Damage Level Multiplier','FloatProperty',2},
    {'Gun Lock?','BoolProperty',false},
    {'Overheat Rate','FloatProperty',0.12},
    {'Overheat Threshold','FloatProperty',0.9},
    {'HeatDistortion','ObjectProperty',{visual=true}},
    {'Machine GunOverheat Decal','ObjectProperty',{visual=true}},
    {'OverheatingSound','ObjectProperty',{audio=true}},
    {'Gun Overheat','FloatProperty',0.72},
    {'Jam Amount','IntProperty',4},
    {'Rocket Heat','FloatProperty',0.4},
    {'FireRate_11_GUID','FloatProperty',0.075},
    {'Health','FloatProperty',75},
}
for _, field in ipairs(protected) do fields[#fields+1]=field end
local m,t,w,logs=fixture(fields)
check(m.enabled and not m.ready,'default ON request does not claim readiness before binding')
check(m:refresh() and m.ready,'all exact typed pairs bind beyond property250')
check(#w==6,'only the three counters and three latches are initially written')
for name,value in pairs(writable) do check(t.values[name]==value,'exact observed state clears: '..name) end
for _, field in ipairs(protected) do check(t.values[field[1]]==field[3],'unrelated gameplay/visual state untouched: '..field[1]) end
check(t.values['Machine Gun Jam THRESHHOLD']==38.5 and t.values['Range Gun Jam THRESHHOLD']==10.8000001907
    and t.values['Flamethrower Jam THRESHHOLD']==15,'actual misspelled thresholds remain unchanged')
for _, write in ipairs(w) do check(writable[write.name]~=nil,'no generic alias/configuration writes') end
local snap=m:snapshot()
check(#snap.counters==3 and #snap.latches==3 and #snap.thresholds==3,'snapshot separates exact bound state and read-only thresholds')
local machine=entry(snap.counters,'Machine Gun Jamming')
check(machine.type=='FloatProperty' and machine.initial_value==7.5841679573059
    and machine.last_read==7.5841679573059 and machine.value==0,'exact pre-clear and current counter values retained')
check(entry(snap.latches,'Range Gun Jammed').initial_value==false
    and entry(snap.latches,'Range Gun Jammed').value==false,'false survives initial and live snapshots')
check(entry(snap.candidates,'Gun Overheat').role=='ignored','old guessed names remain read-only diagnostics')
check(table.concat(logs,'\n'):find('NO HEAT BOUND counter "Machine Gun Jamming"',1,true)~=nil,'bound raw name/type logged')
check(snap.schema=='PlayerTrain.Jamming.v1','report identifies exact schema')
check(snap.heat_events==1 and snap.jam_events==1,'positive heat and jam interventions are counted separately from initial zero writes')
local before=#w
for _=1,100 do m:refresh() end
check(#w==before,'stable cool state produces no redundant writes')
for _, name in ipairs({'Machine Gun','Range Gun','Flamethrower'}) do
    t.values[name..' Jamming']=2.5; t.values[name..' Jammed']=true
end
check(m:refresh(),'refresh succeeds as heat accumulates during play')
for name,value in pairs(writable) do check(t.values[name]==value,'new heat/jam state clears: '..name) end
t.values['Machine Gun Jamming']=-0.06873694062233
check(m:refresh() and t.values['Machine Gun Jamming']==0,'observed negative cooling overshoot is cleared, not rejected')
check(m:snapshot().heat_events==4 and m:snapshot().jam_events==4,'negative cooling normalization is not counted as a positive heat event')
m:set_enabled(false)
check(not m.enabled and not m.ready and t.values['Machine Gun Jamming']==0,'OFF never restores historical heat')
t.values['Machine Gun Jamming']=11.0009851456; t.values['Machine Gun Jammed']=true
before=#w; m:refresh()
check(#w==before and t.values['Machine Gun Jamming']==11.0009851456 and t.values['Machine Gun Jammed']==true,'OFF leaves game cooling/jamming state alone')
m:set_enabled(true)
check(m.enabled and m.ready and t.values['Machine Gun Jamming']==0 and not t.values['Machine Gun Jammed'],'reenabling rebinds and clears actual state')

local unknown,ut,uw=fixture({{'Gun Overheat','FloatProperty',0.4},{'Jammed','BoolProperty',true}})
check(not unknown:refresh() and #uw==0 and ut.values.Jammed==true,'generic names alone cannot claim this game is supported')
local missing,mt,mw=fixture(without(observed_fields(),'Range Gun Jammed'))
check(not missing:refresh() and #mw==0 and missing.status:find('Range Gun Jammed',1,true),'missing one real latch blocks all writes and reports its name')
local case_fields=observed_fields(); case_fields[1][1]='Machine gun Jamming'
local casing,ct,cw=fixture(case_fields)
check(not casing:refresh() and #cw==0,'matching requires the exact raw field spelling')
for _, wrong_kind in ipairs({'IntProperty','DoubleProperty','ObjectProperty','<unknown property type>'}) do
    local typed_fields=observed_fields(); alter(typed_fields,'Machine Gun Jamming',wrong_kind,7)
    local typed,tt,tw=fixture(typed_fields)
    check(not typed:refresh() and #tw==0,'wrong/unknown declared counter type cannot enable: '..wrong_kind)
end
local wrong_bool_fields=observed_fields(); alter(wrong_bool_fields,'Range Gun Jammed','FloatProperty',0)
local wrong_bool,wbt,wbw=fixture(wrong_bool_fields)
check(not wrong_bool:refresh() and #wbw==0,'latch metadata must actually be BoolProperty')
local minimal_fields=observed_fields()
for _, name in ipairs({'Machine Gun','Range Gun','Flamethrower'}) do minimal_fields=without(minimal_fields,name..' Jam THRESHHOLD') end
local minimal,min_t,min_w=fixture(minimal_fields)
check(minimal:refresh() and #min_w==6 and #minimal:snapshot().thresholds==0,'read-only threshold diagnostics are not required for the six verified state writes')

local failed,ft,fw,fl,fc=fixture(observed_fields())
fc.fail_write='Machine Gun Jamming'
check(not failed:refresh() and not failed.ready,'write failure cannot report ready')
check(failed.status:find('Machine Gun Jamming',1,true),'failed state write is named in diagnostics')
check(ft.values['Machine Gun Jammed']==true,'failed counter clear never proceeds to latch clearing')
fc.fail_write=nil
check(failed:refresh(),'a transient write failure can recover on a later refresh')
local lied,lt,lw,ll,lc=fixture(observed_fields())
lc.false_success='Machine Gun Jamming'
check(not lied:refresh() and lt.values['Machine Gun Jamming']==7.5841679573059,'returning success without actual readback is rejected')
local cold_fields=observed_fields(); alter(cold_fields,'Machine Gun Jamming','FloatProperty',0)
local cold,cold_t,cold_w,cold_l,cold_c=fixture(cold_fields)
cold_c.fail_write='Machine Gun Jamming'
check(not cold:refresh(),'an initially zero counter still requires an initial verified write')
local latch_failed,lft,lfw,lfl,lfc=fixture(observed_fields())
lfc.fail_write='Machine Gun Jammed'
check(not latch_failed:refresh() and not latch_failed.ready and lft.values['Machine Gun Jammed']==true,'latch write failure also prevents readiness')
local invalid,it,iw,il,ic=fixture(observed_fields())
it.values['Machine Gun Jamming']=0/0
check(not invalid:refresh() and #iw==0,'NaN fails preflight before any state is changed')
it.values['Machine Gun Jamming']=math.huge
check(not invalid:refresh() and #iw==0,'infinity fails preflight before any state is changed')
it.values['Machine Gun Jamming']= '11'
check(not invalid:refresh() and #iw==0,'nonnumeric runtime counter fails even with correct reflection type')
it.values['Machine Gun Jamming']=11; it.values['Range Gun Jammed']=0
check(not invalid:refresh() and #iw==0,'nonnumeric boolean sentinel is not accepted as false')
it.values['Range Gun Jammed']=false; ic.fail_read='Machine Gun Jamming'
check(not invalid:refresh() and #iw==0,'read error cannot enable noheat')
ic.fail_read=nil
check(invalid:refresh(),'initial invalid values can recover without a level reload')

local wrong,wt,ww=fixture(observed_fields(),'/Game/OtherActor.OtherActor_C')
check(not wrong:refresh() and #ww==0,'an unrelated actor with matching properties is rejected')
local impersonator,ipt,ipw=fixture(observed_fields(),'/Game/Test/PlayerTrain.PlayerTrain_C')
check(not impersonator:refresh() and #ipw==0,'class short name alone is insufficient')
local incomplete,inc_t,inc_w,inc_l,inc_c=fixture(observed_fields())
inc_c.fail_enumeration=8
check(not incomplete:refresh() and #inc_w==0,'partial reflection cannot enable even if several exact fields were found')
inc_c.fail_enumeration=nil
for _=1,60 do incomplete:refresh() end
check(incomplete.ready,'metadata failure retries at the bounded interval')
local enormous_fields=observed_fields()
for i=1,4096 do enormous_fields[#enormous_fields+1]={'Unrelated '..i,'ObjectProperty',{}} end
local enormous,et,ew=fixture(enormous_fields)
check(not enormous:refresh() and #ew==0,'truncated reflection is explicitly not ready')

local replacement,rt=fixture(observed_fields())
local old_train=t
m:set_train(rt); m:refresh()
check(m.train==rt and m.ready and rt.values['Machine Gun Jamming']==0,'actor replacement rebinds the actual schema')
check(old_train.values['Machine Gun Jamming']==0,'rebinding does not restore old heat')
rt.live=false; before=#w
check(not m:refresh() and not m.ready and #w==before,'invalid actors cannot be written')
m:set_train(nil)
check(m:snapshot().train=='none' and not m:view().ready,'missing train is reported honestly')
print('PASS noheat: '..assertions..' exact-schema/readback/isolation checks; game execution still requires a live run')
