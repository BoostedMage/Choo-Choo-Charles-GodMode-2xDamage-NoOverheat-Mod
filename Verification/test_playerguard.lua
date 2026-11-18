-- Exercise the real Lua guard adapter with a simulated DLL boundary. These
-- tests validate readiness, schema checks and restoration control, not native
-- memory safety or actual execution of Unreal Blueprint bytecode.
local scripts=os.getenv('CCC_MOD_SCRIPTS') or './Mod/ChooChooCharles_GodMode/Scripts'
local PlayerGuard=dofile(scripts..'/playerguard.lua')
local TARGET='/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C:Damage'
local PLAYER='/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter_Player.BP_NMCharacter_Player_C'
local assertions=0
local function check(value,message) assert(value,message); assertions=assertions+1 end
local function fixture(options)
    local state=options or {}
    state.version=state.version or {4,0,0}
    state.engine=state.engine or {4,26}
    state.codes=state.codes or {}
    state.calls={}; state.loads={}; state.logs={}; state.active=false
    state.lookups=0; state.reflections=0; state.class_checks=0
    state.address=100
    state.player_address=800
    state.fields=state.fields or {
        {'Damage Applied','FloatProperty'},
        {'Slowing Multiplier','FloatProperty'},
        {'Hit Component','ObjectProperty'},
    }
    local fn={valid=true}
    function fn:GetAddress() return state.address end
    function fn:GetFullName() return state.function_path or 'Function '..TARGET end
    function fn:GetFunctionFlags() return state.flags or 0xC020000 end
    function fn:ForEachProperty(callback)
        state.reflections=state.reflections+1
        for i, field in ipairs(state.fields) do
            if state.reflection_error==i then error('simulated reflection failure') end
            local property={}
            function property:GetFName() return {ToString=function() return field[1] end} end
            function property:GetClass() return {GetFName=function() return {ToString=function() return field[2] end} end} end
            local result=callback(property)
            assert(result~=false,'UE4SS iterator must continue with nil')
            if result==true then return end
        end
    end
    local player={valid=true,varHealthMain=100,['Dead?']=false}
    function player:GetAddress()
        if state.address_error then error('simulated address failure') end
        return state.player_address
    end
    function player:IsA(path)
        state.class_checks=state.class_checks+1
        assert(path==PLAYER,'guard must check the exact observed player class')
        return not state.wrong_player
    end
    UE4SS={GetVersion=function() return table.unpack(state.version) end}
    UnrealVersion={IsEqual=function(major,minor) return major==state.engine[1] and minor==state.engine[2] end}
    StaticFindObject=function(path)
        state.lookups=state.lookups+1
        assert(path==TARGET,'guard must resolve only the observed player Damage function')
        if state.missing_function then return nil end
        return fn
    end
    package.loadlib=function(path,symbol)
        state.loads[#state.loads+1]={path=path,symbol=symbol}
        assert(path=='/mock/Scripts/native/ccc_guard.dll','only the packaged companion may be loaded')
        local action=symbol:match('^ccc_guard_(%a+)$')
        assert(action=='enable' or action=='disable' or action=='check','unexpected native export')
        if state.load_throw==action then error('simulated loader exception') end
        if state.load_fail==action then return nil,'simulated missing companion export' end
        return function(...)
            local sentinels=table.pack(...)
            assert(sentinels.n==16,'native bridge must receive sixteen sentinels')
            for i=1,16 do assert(sentinels[i]==false,'sentinel must be false') end
            state.calls[#state.calls+1]=action
            -- A native call may have changed owned state before it reports an
            -- error or throws. This must still be cleaned up by the adapter.
            if action=='enable' and state.partial_enable then state.active=true end
            if state.call_throw==action then error('simulated native boundary failure') end
            local code=state.codes[action] or 0
            if code==0 then
                if action=='enable' then state.active=true
                elseif action=='disable' then state.active=false
                elseif not state.active then code=9 end
            end
            return table.unpack(sentinels,1,code)
        end
    end
    local guard=PlayerGuard.new({script_dir='/mock/Scripts',
        valid=function(o) return o~=nil and o.valid==true end,
        log=function(line) state.logs[#state.logs+1]=line end})
    return guard,player,state,fn
end

local guard,player,state,fn=fixture()
check(not guard.ready and not guard.armed,'a new guard does not claim protection before activation')
guard:refresh(player,true)
check(guard.ready and guard.armed and state.active,'exact schema and zero native return count activate the guard')
check(#state.loads==3 and table.concat(state.calls,',')=='enable,check','all three exports are loaded before activation and readback')
check(guard:view().ready and not guard:view().restoring,'view reports verified readiness')
local snap=guard:snapshot()
check(snap.target==TARGET and snap.native_code==0 and snap.schema_verified,'snapshot identifies the target, native result and schema check')
check(player.varHealthMain==100 and player['Dead?']==false,'guard adapter never changes player health or revives a death')
guard:refresh(player,true)
check(#state.loads==3 and #state.calls==2 and state.lookups==1 and state.class_checks==1,
    'ordinary refresh reuses an active guard without another DLL, reflection or native call')
check(guard.ready and guard.armed and state.active and guard:snapshot().cached_refreshes==1,
    'skipping redundant readback leaves the native guard continuously active and ready')
guard:refresh(player,false)
check(not guard.ready and not guard.armed and not guard.restoring and not state.active,'OFF restores the owned original body')
local calls=#state.calls
guard:refresh(player,false)
check(#state.calls==calls,'repeated OFF does not restore an unowned body')
guard:refresh(player,true)
check(guard.ready and state.active,'ON can activate again after a successful restore')

local off,op,os=fixture()
off:refresh(op,false)
check(#os.loads==0 and #os.calls==0 and not off.armed,'starting OFF does not load or change the function')
local stale,sp,ss=fixture()
stale:refresh(sp,true); sp.valid=false; stale:refresh(sp,true)
check(not stale.ready and not stale.armed and not ss.active and stale.status:find('waiting',1,true),'a stale gameplay player restores the owned function and waits')
local absent,ap,aps=fixture()
absent:refresh(nil,true)
check(not absent.ready and #aps.loads==0,'missing player cannot activate the native helper')
local wrong,wp,ws=fixture({wrong_player=true})
wrong:refresh(wp,true)
check(not wrong.ready and #ws.loads==0 and #ws.calls==0,'an unrelated player class is rejected before loading')

for _, version in ipairs({{3,0,0},{4,0,1},{4,1,0}}) do
    local abi,p,s=fixture({version=version})
    abi:refresh(p,true)
    check(not abi.ready and #s.loads==0 and abi.status:find('ABI',1,true),'unverified UE4SS ABI is rejected before DLL loading')
end
local engine,ep,es=fixture({engine={4,27}})
engine:refresh(ep,true)
check(not engine.ready and #es.loads==0 and engine.status:find('4.26',1,true),'unverified Unreal version is rejected')
local missing_version,mvp,mvs=fixture()
UE4SS=nil; missing_version:refresh(mvp,true)
check(not missing_version.ready and #mvs.loads==0,'missing version API is handled without an exception')
local loader,lp,ls=fixture({load_fail='check'})
loader:refresh(lp,true)
check(not loader.ready and #ls.loads==3 and #ls.calls==0,'partial export loading cannot activate the guard')
loader:refresh(lp,true)
check(#ls.loads==3,'an unavailable DLL is not reloaded every protection tick')
local loader_throw,ltp,lts=fixture({load_throw='enable'})
loader_throw:refresh(ltp,true)
check(not loader_throw.ready and #lts.calls==0,'loader exceptions are contained')

local missing_function,mfp,mfs=fixture({missing_function=true})
missing_function:refresh(mfp,true)
check(not missing_function.ready and #mfs.calls==0,'unloaded Damage function remains waiting')
mfs.missing_function=false; missing_function:refresh(mfp,true)
check(missing_function.ready,'a later loaded function can activate without recreating the adapter')
local cases={
    {flags=0x00400000},
    {function_path='Function /Game/Other:Damage'},
    {flags=0x400},
    {fields={{'Damage Applied','IntProperty'},{'Slowing Multiplier','FloatProperty'},{'Hit Component','ObjectProperty'}}},
    {fields={{'Damage Applied','FloatProperty'},{'Slowing Multiplier','FloatProperty'}}},
    {fields={{'Damage Applied','FloatProperty'},{'Slowing Multiplier','FloatProperty'},{'Hit Component','ObjectProperty'},{'Extra','FloatProperty'}}},
    {fields={{'Damage Applied','FloatProperty'},{'Damage Applied','FloatProperty'},{'Hit Component','ObjectProperty'}}},
    {reflection_error=2},
}
for i, bad in ipairs(cases) do
    local rejected,p,s=fixture(bad)
    rejected:refresh(p,true)
    check(not rejected.ready and not rejected.armed and #s.calls==0,'unexpected Damage schema cannot activate case '..i)
end

for code=1,9 do
    local failed,p,s=fixture({codes={enable=code}})
    failed:refresh(p,true)
    check(not failed.ready and failed.armed and #s.calls==1 and failed:snapshot().native_code==code,
        'native status count '..code..' is not ready and preserves cleanup intent')
end
for _, code in ipairs({5,8}) do
    local partial,p,s=fixture({partial_enable=true,codes={enable=code}})
    partial:refresh(p,true)
    check(not partial.ready and partial.armed and s.active and partial:snapshot().native_code==code,
        'partial native mutation followed by error '..code..' retains cleanup intent')
    s.codes.disable=6; partial:refresh(p,false)
    check(s.calls[#s.calls]=='disable' and not partial.ready and partial.armed and partial.restoring and s.active,
        'OFF attempts cleanup after error '..code..' and retains ownership when restoration conflicts')
    s.codes.disable=0; partial:refresh(p,false)
    check(not partial.armed and not partial.restoring and not s.active and s.calls[#s.calls]=='disable',
        'OFF retries and restores a partial native mutation after error '..code)
end
local partial_missing,pmp,pms=fixture({partial_enable=true,codes={enable=8}})
partial_missing:refresh(pmp,true); pms.codes.disable=6; partial_missing:refresh(nil,true)
check(not partial_missing.ready and partial_missing.armed and partial_missing.restoring and pms.active
    and pms.calls[#pms.calls]=='disable','missing player still attempts cleanup after a partial activation and preserves a failed restore')
pms.codes.disable=0; partial_missing:refresh(nil,true)
check(not partial_missing.armed and not partial_missing.restoring and not pms.active,
    'partial activation can finish restoration while the gameplay player remains absent')
local partial_throw,ptp,pts=fixture({partial_enable=true,call_throw='enable'})
partial_throw:refresh(ptp,true)
check(not partial_throw.ready and partial_throw.armed and pts.active and partial_throw:snapshot().native_code==-1,
    'a native boundary exception after mutation also preserves cleanup intent')
partial_throw:refresh(ptp,false)
check(not partial_throw.armed and not pts.active and pts.calls[#pts.calls]=='disable',
    'OFF restores a partial activation even when enable threw instead of returning a status')
local readback,rp,rs=fixture({codes={check=9}})
readback:refresh(rp,true)
check(not readback.ready and readback.armed and rs.active,'failed readback retains restoration ownership without claiming ready')
readback:refresh(rp,false)
check(not readback.armed and not rs.active,'an activation with failed readback can still be restored on OFF')
local thrown,tp,ts=fixture({call_throw='enable'})
thrown:refresh(tp,true)
check(not thrown.ready and thrown:snapshot().native_code==-1,'native boundary exception cannot claim protection')
local unknown_code,ucp,ucs=fixture({codes={enable=16}})
unknown_code:refresh(ucp,true)
check(not unknown_code.ready and unknown_code:snapshot().native_code==-1,'unknown result counts are bridge failures')

local restore,rp2,rs2=fixture()
restore:refresh(rp2,true); rs2.codes.disable=6; restore:refresh(rp2,false)
check(not restore.ready and restore.armed and restore.restoring and rs2.active,'failed OFF retains guard ownership for a retry')
check(restore.status:find('RESTORING',1,true) and restore:view().restoring,'failed OFF exposes pending restoration')
rs2.codes.disable=0; restore:refresh(rp2,false)
check(not restore.armed and not restore.restoring and not rs2.active,'a later OFF refresh completes restoration')
local changed,cp,cs=fixture()
changed:refresh(cp,true); cs.address=101; cs.fields[1][2]='IntProperty'; changed:refresh(cp,true,true)
check(not changed.ready and not changed.armed and not cs.active,'a replacement function must pass schema validation and otherwise restores the old guard')
local stale_failure,sfp,sfs=fixture()
stale_failure:refresh(sfp,true); sfs.codes.disable=5; sfp.valid=false; stale_failure:refresh(sfp,true)
check(stale_failure.restoring and stale_failure.armed and not stale_failure.ready,'stale actors do not discard a failed restoration')
sfs.codes.disable=0; stale_failure:refresh(nil,true)
check(not stale_failure.restoring and not stale_failure.armed,'restoration can finish even while no gameplay player exists')

local periodic,pp,ps=fixture()
periodic:refresh(pp,true)
for _=1,19 do periodic:refresh(pp,true) end
check(#ps.calls==2 and ps.lookups==1 and ps.reflections==1 and ps.class_checks==1,
    'nineteen routine refreshes after activation do no native or reflection work')
periodic:refresh(pp,true)
check(table.concat(ps.calls,',')=='enable,check,check' and ps.lookups==2 and ps.reflections==1,
    'twentieth routine refresh performs one ownership check without reenabling or reenumerating the schema')
check(periodic.ready and periodic.armed and ps.active,'periodic readback preserves the working guard')
local performance=periodic:snapshot()
check(performance.verification_interval_refreshes==20 and performance.refreshes==21
    and performance.cached_refreshes==19 and performance.schema_lookups==2
    and performance.native_enable_calls==1 and performance.native_check_calls==2
    and performance.native_disable_calls==0 and performance.native_failures==0,
    'snapshot exposes exact bounded verification and native-call counters')
periodic:refresh(pp,true,true)
check(#ps.calls==4 and ps.calls[4]=='check' and ps.lookups==3,
    'an explicit forced verification checks immediately without reapplying an owned guard')
periodic:refresh(pp,false)
check(ps.calls[#ps.calls]=='disable' and not periodic.ready and not ps.active,
    'OFF restores immediately during the otherwise cached interval')
local disabled_calls,disabled_lookups=#ps.calls,ps.lookups
for _=1,40 do periodic:refresh(pp,false,true) end
check(#ps.calls==disabled_calls and ps.lookups==disabled_lookups,
    'repeated OFF including force never performs unnecessary checks or schema lookups')
periodic:refresh(pp,true)
check(periodic.ready and ps.active and ps.calls[#ps.calls-1]=='enable' and ps.calls[#ps.calls]=='check',
    'ON after OFF activates and verifies immediately regardless of the old countdown')

local rebind,bp,bs=fixture()
rebind:refresh(bp,true); bs.player_address=801; rebind:refresh(bp,true)
check(rebind.ready and #bs.calls==3 and bs.calls[3]=='check' and bs.lookups==2 and bs.reflections==2,
    'a new player identity validates immediately while retaining the same working function patch')
bp.valid=false; rebind:refresh(bp,true)
local prior_reflections=bs.reflections
bp.valid=true; rebind:refresh(bp,true)
check(rebind.ready and bs.active and bs.reflections==prior_reflections+1
    and bs.calls[#bs.calls-1]=='enable' and bs.calls[#bs.calls]=='check',
    'invalidating and returning at the same actor address cannot reuse the retired readiness/schema cache')

local uncertain,up,us=fixture({address_error=true})
uncertain:refresh(up,true); uncertain:refresh(up,true)
check(uncertain.ready and #us.calls==3 and us.lookups==2 and uncertain:snapshot().cached_refreshes==0,
    'an unreadable actor identity falls back to verified work instead of trusting a cached result')

local vanished,vp,vs=fixture()
vanished:refresh(vp,true); vs.missing_function=true
vanished:refresh(vp,true,true)
check(not vanished.ready and not vanished.armed and not vs.active and vs.calls[#vs.calls]=='disable',
    'a forced check of an unloaded function immediately retires readiness and restores owned state')
vs.missing_function=false; vanished:refresh(vp,true)
check(vanished.ready and vs.active,'the same actor can reactivate after its function becomes available again')

local check_fail,cfp,cfs=fixture()
check_fail:refresh(cfp,true); cfs.codes.check=9
for _=1,19 do check_fail:refresh(cfp,true) end
check(check_fail.ready and #cfs.calls==2,'a stable active patch is not continuously rechecked')
check_fail:refresh(cfp,true)
check(not check_fail.ready and check_fail.armed and cfs.active
    and table.concat(cfs.calls,',')=='enable,check,check,enable,check',
    'a failed scheduled readback retries activation/readback but never claims readiness on failure')
cfs.codes.check=0; check_fail:refresh(cfp,true)
check(check_fail.ready and cfs.active and cfs.calls[#cfs.calls]=='check',
    'a failed readback is retried on the next refresh without waiting another cache interval')

local lost,lop,los=fixture()
lost:refresh(lop,true); los.active=false
lost:refresh(lop,true,true)
check(lost.ready and los.active and table.concat(los.calls,',')=='enable,check,check,enable,check',
    'an unarmed readback recovers immediately through the existing validated enable/check sequence')

local budget,bup,bus=fixture()
budget:refresh(bup,true)
for _=1,1200 do budget:refresh(bup,true) end
local totals=budget:snapshot()
check(totals.native_enable_calls==1 and totals.native_check_calls==61
    and totals.schema_lookups==61 and totals.cached_refreshes==1140,
    'sixty seconds of simulated routine polling needs one activation and sixty periodic native checks')
check(budget.ready and budget.armed and bus.active,'the call reduction never disables the sticky guard between checks')
print('PASS playerguard: '..assertions..' Lua schema/ABI/readiness/restoration checks; native execution is not mocked as proven')
