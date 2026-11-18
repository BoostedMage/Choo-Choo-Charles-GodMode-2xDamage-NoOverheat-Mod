/* Portable regression tests for the real, shared guard_patch.h implementation.
 *
 * No game, UE4SS, Windows ABI, or full Unreal VM is emulated here. The final
 * test is a deliberately small execution-order model: an ordinary entry runs
 * an opaque damage body, an EventGraphFunction link bypasses that entry, and a
 * Return/Nothing entry returns before that body. The body models the report's
 * ten 15-damage calls and a separate health store. It is not claimed to be a
 * disassembly of Choo-Choo Charles or proof of in-game compatibility.
 *
 * With CCC_BUILD_LUA_FIXTURE, this same source builds a real Lua C callback
 * library which intentionally imports NO Lua C API. The accompanying Lua test
 * supplies sixteen sentinels and verifies the actual result-count protocol.
 */
#ifdef CCC_BUILD_LUA_FIXTURE
#define STATUS_FN(n) int ccc_status_##n(void *lua_state) { (void)lua_state; return n; }
STATUS_FN(0) STATUS_FN(1) STATUS_FN(2) STATUS_FN(3)
STATUS_FN(4) STATUS_FN(5) STATUS_FN(6) STATUS_FN(7)
STATUS_FN(8) STATUS_FN(9) STATUS_FN(10) STATUS_FN(11)
STATUS_FN(12) STATUS_FN(13) STATUS_FN(14) STATUS_FN(15)
STATUS_FN(16)
#else
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <setjmp.h>

static jmp_buf write_fault;
static int fault_after=-1, skip_write=-1, write_count;
static void before_write(void) {
    if (fault_after==0 && write_count==0) longjmp(write_fault,1);
}
static void after_write(void) {
    write_count++;
    if (fault_after>0 && write_count==fault_after) longjmp(write_fault,1);
}
static void faultable_byte_write(uint8_t *address,uint8_t value) {
    before_write();
    if (write_count!=skip_write) *address=value;
    after_write();
}
static void faultable_event_write(void **address,void *value) {
    before_write();
    if (write_count!=skip_write) *address=value;
    after_write();
}
#define CCC_GUARD_WRITE_BYTE(address,value) faultable_byte_write((address),(value))
#define CCC_GUARD_WRITE_EVENT(address,value) faultable_event_write((address),(value))
#include "../NativeSource/guard_patch.h"

static unsigned checks;
#define CHECK(condition) do { \
    ++checks; \
    if (!(condition)) { \
        fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,#condition); \
        exit(1); \
    } \
} while (0)

typedef struct {
    int function_token, graph_token, other_graph_token;
    uint8_t bytes[9];
    void *graph;
    int32_t offset;
    CCC_Target target;
} Fixture;

/* The opaque body bytes are structural test data, not a complete UE program. */
static const uint8_t original_body[9]={0x64,0x21,0x31,0x41,0x51,0x61,0x04,0x0B,0x53};

static void fixture_init(Fixture *f,int fastcall) {
    memset(f,0,sizeof(*f));
    memcpy(f->bytes,original_body,sizeof(original_body));
    f->graph=fastcall ? &f->graph_token : NULL;
    f->offset=731;
    f->target=(CCC_Target){&f->function_token,f->bytes,9,9,&f->graph,&f->offset};
}

static void test_toggle_and_idempotence(void) {
    Fixture f;
    CCC_Patch state={0};
    fixture_init(&f,1);
    CHECK(ccc_patch(&state,&f.target,CCC_CHECK)==CCC_NOT_ARMED);
    CHECK(ccc_patch(&state,&f.target,CCC_DISABLE)==CCC_OK);
    for (int i=0;i<25;i++) {
        CHECK(ccc_patch(&state,&f.target,CCC_ENABLE)==CCC_OK);
        CHECK(state.owned==1);
        CHECK(state.pending==0);
        CHECK(f.bytes[0]==0x04 && f.bytes[1]==0x0B);
        CHECK(memcmp(f.bytes+2,original_body+2,7)==0);
        CHECK(f.graph==NULL);
        CHECK(f.offset==731);
        CHECK(f.target.count==9 && f.target.capacity==9);
        CHECK(ccc_patch(&state,&f.target,CCC_CHECK)==CCC_OK);
        CHECK(ccc_patch(&state,&f.target,CCC_ENABLE)==CCC_OK);
        CHECK(ccc_patch(&state,&f.target,CCC_DISABLE)==CCC_OK);
        CHECK(state.owned==0);
        CHECK(state.pending==0);
        CHECK(memcmp(f.bytes,original_body,sizeof(f.bytes))==0);
        CHECK(f.graph==&f.graph_token);
        CHECK(f.offset==731);
        CHECK(ccc_patch(&state,&f.target,CCC_CHECK)==CCC_NOT_ARMED);
        CHECK(ccc_patch(&state,&f.target,CCC_DISABLE)==CCC_OK);
    }

    fixture_init(&f,0);
    CHECK(ccc_patch(&state,&f.target,CCC_ENABLE)==CCC_OK);
    CHECK(ccc_patch(&state,&f.target,CCC_DISABLE)==CCC_OK);
    CHECK(f.graph==NULL);
}

static void test_rejections_do_not_write(void) {
    Fixture f;
    CCC_Patch state={0};
    CCC_Target bad;
    fixture_init(&f,1);
    CHECK(ccc_patch(&state,NULL,CCC_ENABLE)==CCC_SCRIPT);
    bad=f.target; bad.function=NULL;
    CHECK(ccc_patch(&state,&bad,CCC_ENABLE)==CCC_SCRIPT);
    bad=f.target; bad.bytes=NULL;
    CHECK(ccc_patch(&state,&bad,CCC_ENABLE)==CCC_SCRIPT);
    bad=f.target; bad.event_slot=NULL;
    CHECK(ccc_patch(&state,&bad,CCC_ENABLE)==CCC_SCRIPT);
    bad=f.target; bad.event_offset=NULL;
    CHECK(ccc_patch(&state,&bad,CCC_ENABLE)==CCC_SCRIPT);
    bad=f.target; bad.count=3;
    CHECK(ccc_patch(&state,&bad,CCC_ENABLE)==CCC_SCRIPT);
    bad=f.target; bad.count=65537; bad.capacity=65537;
    CHECK(ccc_patch(&state,&bad,CCC_ENABLE)==CCC_SCRIPT);
    bad=f.target; bad.capacity=8;
    CHECK(ccc_patch(&state,&bad,CCC_ENABLE)==CCC_SCRIPT);
    bad=f.target; bad.capacity=1048577;
    CHECK(ccc_patch(&state,&bad,CCC_ENABLE)==CCC_SCRIPT);
    CHECK(ccc_patch(&state,&f.target,999)==CCC_SIGNATURE);
    CHECK(memcmp(f.bytes,original_body,sizeof(f.bytes))==0);
    CHECK(f.graph==&f.graph_token && state.owned==0);

    /* A four-byte body overlaps the two-byte patch and required return tail. */
    uint8_t tiny[4]={0x0B,0x04,0x0B,0x53};
    bad=f.target; bad.bytes=tiny; bad.count=4; bad.capacity=4;
    CHECK(ccc_patch(&state,&bad,CCC_ENABLE)==CCC_SCRIPT);
    CHECK(tiny[0]==0x0B && tiny[1]==0x04);

    for (int i=6;i<9;i++) {
        uint8_t saved=f.bytes[i];
        f.bytes[i]=0x19;
        CHECK(ccc_patch(&state,&f.target,CCC_ENABLE)==CCC_SCRIPT);
        CHECK(state.owned==0 && f.bytes[0]==original_body[0]);
        f.bytes[i]=saved;
    }
    f.bytes[0]=0x04; f.bytes[1]=0x0B;
    CHECK(ccc_patch(&state,&f.target,CCC_ENABLE)==CCC_CONFLICT);
    CHECK(!state.owned); /* Never claim another mod's existing suppression. */
    CHECK(ccc_patch(&state,&f.target,CCC_DISABLE)==CCC_OK);
    CHECK(f.bytes[0]==0x04 && f.bytes[1]==0x0B);
}

static void assert_conflict_preserved(CCC_Patch *state,Fixture *f) {
    uint8_t before[sizeof(f->bytes)];
    void *graph=f->graph;
    int32_t offset=f->offset;
    memcpy(before,f->bytes,sizeof(before));
    CHECK(ccc_patch(state,&f->target,CCC_CHECK)==CCC_NOT_ARMED);
    CHECK(ccc_patch(state,&f->target,CCC_ENABLE)==CCC_CONFLICT);
    CHECK(ccc_patch(state,&f->target,CCC_DISABLE)==CCC_CONFLICT);
    CHECK(state->owned==1);
    CHECK(memcmp(before,f->bytes,sizeof(before))==0);
    CHECK(f->graph==graph && f->offset==offset);
}

static void test_conflict_ownership(void) {
    Fixture f;
    CCC_Patch state={0};
    fixture_init(&f,1);
    CHECK(ccc_patch(&state,&f.target,CCC_ENABLE)==CCC_OK);

    f.bytes[0]=0x0B;
    assert_conflict_preserved(&state,&f);
    f.bytes[0]=0x04;
    f.bytes[1]=0x25;
    assert_conflict_preserved(&state,&f);
    f.bytes[1]=0x0B;
    f.bytes[4]^=0x10; /* Other mod changed an unrelated body byte. */
    assert_conflict_preserved(&state,&f);
    f.bytes[4]^=0x10;
    f.graph=&f.other_graph_token;
    assert_conflict_preserved(&state,&f);
    f.graph=NULL;
    f.offset++;
    assert_conflict_preserved(&state,&f);
    f.offset--;

    CHECK(ccc_patch(&state,&f.target,CCC_CHECK)==CCC_OK);
    CHECK(ccc_patch(&state,&f.target,CCC_DISABLE)==CCC_OK);
    CHECK(memcmp(f.bytes,original_body,sizeof(f.bytes))==0);
    CHECK(f.graph==&f.graph_token && f.offset==731);
}

static void test_retired_pointer_and_changed_buffer(void) {
    Fixture old,newer;
    CCC_Patch state={0};
    fixture_init(&old,1); fixture_init(&newer,1);
    CHECK(ccc_patch(&state,&old.target,CCC_ENABLE)==CCC_OK);
    /* A current different function supersedes an unloaded one. Saved pointers
     * deliberately become unreadable; correct code only compares their values. */
    state.function=(void *)(uintptr_t)1;
    state.bytes=(uint8_t *)(uintptr_t)1;
    state.event_slot=(void **)(uintptr_t)1;
    CHECK(ccc_patch(&state,&newer.target,CCC_CHECK)==CCC_NOT_ARMED);
    CHECK(state.owned==0);
    CHECK(memcmp(newer.bytes,original_body,sizeof(newer.bytes))==0);
    CHECK(ccc_patch(&state,&newer.target,CCC_ENABLE)==CCC_OK);
    CHECK(ccc_patch(&state,&newer.target,CCC_DISABLE)==CCC_OK);

    fixture_init(&old,1);
    memset(&state,0,sizeof(state));
    CHECK(ccc_patch(&state,&old.target,CCC_ENABLE)==CCC_OK);
    uint8_t replacement[9];
    memcpy(replacement,old.bytes,sizeof(replacement));
    CCC_Target moved=old.target;
    moved.bytes=replacement; /* Same function; somebody replaced its buffer. */
    CHECK(ccc_patch(&state,&moved,CCC_ENABLE)==CCC_CONFLICT);
    CHECK(ccc_patch(&state,&moved,CCC_DISABLE)==CCC_CONFLICT);
    CHECK(state.owned==1);
    CHECK(replacement[0]==0x04 && replacement[1]==0x0B);
    CHECK(ccc_patch(&state,&old.target,CCC_DISABLE)==CCC_OK);
    CHECK(memcmp(old.bytes,original_body,sizeof(old.bytes))==0);
}

static void test_interrupted_apply_and_restore(void) {
    /* Heap records survive longjmp without C's indeterminate automatic-local
     * issue. The fault models an abrupt exit between stores, not Windows SEH. */
    Fixture *f=malloc(sizeof(*f));
    CCC_Patch *state=malloc(sizeof(*state));
    CHECK(f!=NULL && state!=NULL);
    for (int after=0;after<=3;after++) {
        fixture_init(f,1); memset(state,0,sizeof(*state));
        fault_after=after; write_count=0;
        if (setjmp(write_fault)==0) {
            (void)ccc_patch(state,&f->target,CCC_ENABLE);
            CHECK(0 && "apply fault must interrupt the transaction");
        }
        fault_after=-1;
        CHECK(state->owned==1 && state->pending==1);
        CHECK(ccc_patch(state,&f->target,CCC_CHECK)==CCC_NOT_ARMED);
        CHECK(ccc_patch(state,&f->target,CCC_DISABLE)==CCC_OK);
        CHECK(state->owned==0 && state->pending==0);
        CHECK(memcmp(f->bytes,original_body,sizeof(f->bytes))==0);
        CHECK(f->graph==&f->graph_token && f->offset==731);

        /* The same interrupted apply may instead finish after another ON. */
        fixture_init(f,1); memset(state,0,sizeof(*state));
        fault_after=after; write_count=0;
        if (setjmp(write_fault)==0) {
            (void)ccc_patch(state,&f->target,CCC_ENABLE);
            CHECK(0 && "second apply fault must interrupt");
        }
        fault_after=-1;
        CHECK(ccc_patch(state,&f->target,CCC_ENABLE)==CCC_OK);
        CHECK(ccc_patch(state,&f->target,CCC_CHECK)==CCC_OK);
        CHECK(state->pending==0 && state->owned==1);

        fault_after=after; write_count=0;
        if (setjmp(write_fault)==0) {
            (void)ccc_patch(state,&f->target,CCC_DISABLE);
            CHECK(0 && "restore fault must interrupt the transaction");
        }
        fault_after=-1;
        CHECK(state->owned==1 && state->pending==1);
        CHECK(ccc_patch(state,&f->target,CCC_CHECK)==CCC_NOT_ARMED);
        CHECK(ccc_patch(state,&f->target,CCC_DISABLE)==CCC_OK);
        CHECK(state->owned==0 && state->pending==0);
        CHECK(memcmp(f->bytes,original_body,sizeof(f->bytes))==0);
        CHECK(f->graph==&f->graph_token && f->offset==731);
    }

    /* A failed store without an exception must retain rollback intent too. */
    fixture_init(f,1); memset(state,0,sizeof(*state));
    skip_write=1; write_count=0;
    CHECK(ccc_patch(state,&f->target,CCC_ENABLE)==CCC_MEMORY);
    skip_write=-1;
    CHECK(state->owned==1 && state->pending==1);
    CHECK(ccc_patch(state,&f->target,CCC_DISABLE)==CCC_OK);
    CHECK(memcmp(f->bytes,original_body,sizeof(f->bytes))==0);

    CHECK(ccc_patch(state,&f->target,CCC_ENABLE)==CCC_OK);
    skip_write=2; write_count=0;
    CHECK(ccc_patch(state,&f->target,CCC_DISABLE)==CCC_MEMORY);
    skip_write=-1;
    CHECK(state->owned==1 && state->pending==1);
    CHECK(ccc_patch(state,&f->target,CCC_DISABLE)==CCC_OK);
    CHECK(f->graph==&f->graph_token);

    /* Interrupted ownership must not become permission to overwrite a third
     * byte value, another mod's graph link, changed suffix, or changed offset. */
    for (int conflict=0;conflict<4;conflict++) {
        fixture_init(f,1); memset(state,0,sizeof(*state));
        fault_after=1; write_count=0;
        if (setjmp(write_fault)==0) {
            (void)ccc_patch(state,&f->target,CCC_ENABLE);
            CHECK(0 && "conflict setup must interrupt");
        }
        fault_after=-1;
        if (conflict==0) f->bytes[0]=0x28;
        if (conflict==1) f->graph=&f->other_graph_token;
        if (conflict==2) f->bytes[3]^=1;
        if (conflict==3) f->offset++;
        assert_conflict_preserved(state,f);
        CHECK(state->pending==1);
    }
    free(state); free(f);
}

typedef struct {
    int nightmare, dead, actual_health, actual_damage_calls;
    int unrelated_varHealthMain;
} Model;

static void opaque_damage_body(Model *m) {
    m->actual_health-=15; /* Argument observed in the supplied NPC report. */
    m->actual_damage_calls++;
    if (m->actual_health<=0) m->dead=1;
}

static void dispatch_model(const Fixture *f,Model *m) {
    if (f->graph) { /* A native fastcall route can bypass the ordinary stub. */
        opaque_damage_body(m);
        return;
    }
    if (f->bytes[0]==0x04 && f->bytes[1]==0x0B) return;
    opaque_damage_body(m);
}

static void legacy_observer_model(Model *m) {
    /* Polling/restoring the constant report field cannot protect another store
     * or undo a death that the body has already selected. */
    m->unrelated_varHealthMain=100;
}

static void test_report_execution_order_regression(void) {
    for (int nightmare=0;nightmare<=1;nightmare++) {
        Fixture f;
        CCC_Patch state={0};
        Model old={nightmare,0,100,0,100},protected={nightmare,0,100,0,100};
        fixture_init(&f,1);
        for (int hit=0;hit<10;hit++) {
            dispatch_model(&f,&old);
            legacy_observer_model(&old);
        }
        CHECK(old.actual_health==-50 && old.dead==1);
        CHECK(old.unrelated_varHealthMain==100);
        CHECK(old.actual_damage_calls==10);

        /* Demonstrate why patching only the script bytes misses fastcall. */
        f.bytes[0]=0x04; f.bytes[1]=0x0B;
        Model bypass={nightmare,0,100,0,100};
        dispatch_model(&f,&bypass);
        CHECK(bypass.actual_health==85 && bypass.actual_damage_calls==1);
        fixture_init(&f,1);

        CHECK(ccc_patch(&state,&f.target,CCC_ENABLE)==CCC_OK);
        for (int hit=0;hit<10;hit++) dispatch_model(&f,&protected);
        CHECK(protected.actual_health==100 && protected.dead==0);
        CHECK(protected.unrelated_varHealthMain==100);
        CHECK(protected.actual_damage_calls==0);
        CHECK(protected.nightmare==nightmare);

        CHECK(ccc_patch(&state,&f.target,CCC_DISABLE)==CCC_OK);
        for (int hit=0;hit<10;hit++) dispatch_model(&f,&protected);
        CHECK(protected.actual_health==-50 && protected.dead==1);
        CHECK(protected.actual_damage_calls==10);
    }
}

int main(void) {
    test_toggle_and_idempotence();
    test_rejections_do_not_write();
    test_conflict_ownership();
    test_retired_pointer_and_changed_buffer();
    test_interrupted_apply_and_restore();
    test_report_execution_order_regression();
    printf("PASS native guard core: %u assertions; reversible entry/fastcall guard, ownership, retired pointers, NPC execution-order model\n",checks);
    return 0;
}
#endif
