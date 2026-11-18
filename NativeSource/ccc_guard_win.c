/* Choo-Choo Charles 0.5.0 - Windows x64 in-process Lua companion.
 * Uses only accessors exported by the user's installed UE4SS 4.0.0.
 * No hard-coded UObject offsets, memory scanning, external process access,
 * network, persistent game-file writes, bundled Lua, or C++ STL ABI.
 *
 * Private Lua bridge: EACH call must receive 16 false sentinel arguments.
 * A C Lua callback may return existing stack arguments as its results.
 * We return a result COUNT (0=success, 1..9=status), decoded with select('#').
 * The sentinels avoid importing an incompatible second Lua implementation.
 * No lua_State internals or Lua C API symbols are used.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include "guard_patch.h"

/* Exact Win64 TArray<uint8,TSizedDefaultAllocator<32>> layout confirmed in
 * the official UE4SS 4.0.0 PDB: size16, Data@0, ArrayNum@8, ArrayMax@12. */
typedef struct { uint8_t *data; int32_t num,max; } ByteArray;
_Static_assert(sizeof(ByteArray)==16,"requires Win64 TArray ABI");
typedef void *(*FindFn)(void *,void *,const wchar_t *,unsigned char);
typedef ByteArray *(*ScriptFn)(void *);
typedef void **(*PtrRefFn)(void *);
typedef uint32_t *(*FlagsFn)(void *);
typedef uint8_t *(*NumFn)(void *);
typedef uint16_t *(*ReturnFn)(void *);
typedef int32_t *(*OffsetFn)(void *);
typedef unsigned char (*GameThreadFn)(void);
static FindFn find_object;
static ScriptFn get_script;
static PtrRefFn get_class,get_outer,get_event;
static FlagsFn get_flags;
static NumFn get_num;
static ReturnFn get_return;
static OffsetFn get_offset;
static GameThreadFn in_game_thread;
static int exports_ready;
static CCC_Patch patch_state;
static DWORD owner_thread;
static const wchar_t *damage_path=L"/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C:Damage";
static const wchar_t *owner_path=L"/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C";

static int range_ok(const void *address,SIZE_T n,int writable) {
    MEMORY_BASIC_INFORMATION m;
    uintptr_t start=(uintptr_t)address,end=start+n,at=start;
    if (!start || end<start) return 0;
    while (at<end) {
        if (!VirtualQuery((LPCVOID)at,&m,sizeof(m)) || m.State!=MEM_COMMIT ||
            (m.Protect&(PAGE_NOACCESS|PAGE_GUARD))) return 0;
        DWORD prot=m.Protect&0xff;
        if (writable && prot!=PAGE_READWRITE && prot!=PAGE_WRITECOPY &&
            prot!=PAGE_EXECUTE_READWRITE && prot!=PAGE_EXECUTE_WRITECOPY) return 0;
        uintptr_t next=(uintptr_t)m.BaseAddress+m.RegionSize;
        if (next<=at) return 0;
        at=next;
    }
    return 1;
}
static int init_exports(void) {
    HMODULE mod=GetModuleHandleW(L"UE4SS.dll");
    if (!mod) return CCC_EXPORTS;
    #define RESOLVE(field,type,symbol) field=(type)GetProcAddress(mod,symbol); if (!field) return CCC_EXPORTS
    RESOLVE(find_object,FindFn,"?StaticFindObject_InternalSlow@UObjectGlobals@Unreal@RC@@YAPEAVUObject@23@PEAVUClass@23@PEAV423@PEB_W_N@Z");
    RESOLVE(get_script,ScriptFn,"?GetScript@UStruct@Unreal@RC@@QEAAAEAV?$TArray@EV?$TSizedDefaultAllocator@$0CA@@Unreal@RC@@@23@XZ");
    RESOLVE(get_class,PtrRefFn,"?GetClassPrivate@UObjectBase@Unreal@RC@@QEAAAEAPEAVUClass@23@XZ");
    RESOLVE(get_outer,PtrRefFn,"?GetOuterPrivate@UObjectBase@Unreal@RC@@QEAAAEAPEAVUObject@23@XZ");
    RESOLVE(get_event,PtrRefFn,"?GetEventGraphFunction@UFunction@Unreal@RC@@QEAAAEAPEAV123@XZ");
    RESOLVE(get_flags,FlagsFn,"?GetFunctionFlags@UFunction@Unreal@RC@@QEAAAEAIXZ");
    RESOLVE(get_num,NumFn,"?GetNumParms@UFunction@Unreal@RC@@QEAAAEAEXZ");
    RESOLVE(get_return,ReturnFn,"?GetReturnValueOffset@UFunction@Unreal@RC@@QEAAAEAGXZ");
    RESOLVE(get_offset,OffsetFn,"?GetEventGraphCallOffset@UFunction@Unreal@RC@@QEAAAEAHXZ");
    RESOLVE(in_game_thread,GameThreadFn,"?IsInGameThread@Unreal@RC@@YA_NXZ");
    #undef RESOLVE
    exports_ready=1;
    return CCC_OK;
}
static int perform(int action) {
    int status;
    DWORD thread=GetCurrentThreadId();
    if (owner_thread && thread!=owner_thread) return CCC_THREAD;
    if (!exports_ready && (status=init_exports())!=CCC_OK) return status;
    if (!in_game_thread()) return CCC_THREAD;
    void *function=find_object(NULL,NULL,damage_path,0);
    if (!function) {
        /* The exact class is no longer registered. Retired memory is never
         * read or written, and a subsequently loaded function is bound anew. */
        patch_state.owned=0;
        patch_state.pending=0;
        return action==CCC_DISABLE ? CCC_OK : CCC_NOT_LOADED;
    }
    if (!range_ok(function,sizeof(void *),0)) return CCC_MEMORY;
    void *function_class=find_object(NULL,NULL,L"/Script/CoreUObject.Function",0);
    void *owner=find_object(NULL,NULL,owner_path,0);
    void **class_ref=get_class(function),**outer_ref=get_outer(function);
    if (!function_class || !owner || !range_ok(class_ref,sizeof(void *),0) ||
        !range_ok(outer_ref,sizeof(void *),0) || *class_ref!=function_class ||
        *outer_ref!=owner) return CCC_SIGNATURE;
    uint32_t *flags=get_flags(function);
    uint8_t *count=get_num(function);
    uint16_t *ret=get_return(function);
    if (!range_ok(flags,4,0) || !range_ok(count,1,0) || !range_ok(ret,2,0)) return CCC_MEMORY;
    if ((*flags&0x00400400)!=0 || *count!=3 || *ret!=0xffff) return CCC_SIGNATURE;
    ByteArray *script=get_script(function);
    void **event_slot=get_event(function);
    int32_t *event_offset=get_offset(function);
    if (!range_ok(script,sizeof(ByteArray),0) || !range_ok(event_slot,sizeof(void *),1) ||
        !range_ok(event_offset,sizeof(int32_t),0)) return CCC_MEMORY;
    if (script->num<5 || script->num>65536 || script->max<script->num || script->max>1048576) return CCC_SCRIPT;
    if (!range_ok(script->data,(SIZE_T)script->num,1)) return CCC_MEMORY;
    CCC_Target target={function,script->data,script->num,script->max,event_slot,event_offset};
    owner_thread=thread;
    return ccc_patch(&patch_state,&target,action);
}
static int safe_perform(int action) {
    __try { return perform(action); }
    __except(EXCEPTION_EXECUTE_HANDLER) { return CCC_EXCEPTION; }
}
__declspec(dllexport) int ccc_guard_enable(void *lua_state) { (void)lua_state; return safe_perform(CCC_ENABLE); }
__declspec(dllexport) int ccc_guard_disable(void *lua_state) { (void)lua_state; return safe_perform(CCC_DISABLE); }
__declspec(dllexport) int ccc_guard_check(void *lua_state) { (void)lua_state; return safe_perform(CCC_CHECK); }
