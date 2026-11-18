/* Choo-Choo Charles 0.5.0: reversible guard for one reflected void function.
 * This is the platform-independent part, also compiled by the native tests.
 * It never changes a file, allocator, array size, global damage flag, or health.
 */
#ifndef CCC_GUARD_PATCH_H
#define CCC_GUARD_PATCH_H
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>

/* Overridden only by the portable tests to interrupt a real update between
 * writes. Production performs ordinary stores, with a journal established
 * before the first store so the Windows SEH boundary cannot lose cleanup. */
#ifndef CCC_GUARD_WRITE_BYTE
#define CCC_GUARD_WRITE_BYTE(address,value) (*(address)=(value))
#endif
#ifndef CCC_GUARD_WRITE_EVENT
#define CCC_GUARD_WRITE_EVENT(address,value) (*(address)=(value))
#endif

enum { CCC_OK=0, CCC_NOT_LOADED=1, CCC_EXPORTS=2, CCC_SIGNATURE=3,
       CCC_SCRIPT=4, CCC_MEMORY=5, CCC_CONFLICT=6, CCC_THREAD=7,
       CCC_EXCEPTION=8, CCC_NOT_ARMED=9 };
enum { CCC_CHECK=0, CCC_ENABLE=1, CCC_DISABLE=2 };
typedef struct {
    void *function;
    uint8_t *bytes;
    int32_t count, capacity;
    void **event_slot;
    int32_t *event_offset;
} CCC_Target;
typedef struct {
    void *function;
    uint8_t *bytes;
    int32_t count;
    void **event_slot;
    int32_t *event_offset;
    void *original_event;
    int32_t original_offset;
    uint8_t original[2];
    uint64_t tail_hash;
    int owned;
    int pending;
} CCC_Patch;

static uint64_t ccc_tail_hash(const CCC_Target *t) {
    uint64_t h=UINT64_C(14695981039346656037);
    int32_t i;
    for (i=2;i<t->count;i++) { h^=t->bytes[i]; h*=UINT64_C(1099511628211); }
    return h;
}
static int ccc_target_valid(const CCC_Target *t) {
    return t && t->function && t->bytes && t->event_slot && t->event_offset &&
        t->count>=5 && t->count<=65536 && t->capacity>=t->count &&
        t->capacity<=1048576 && t->bytes[t->count-3]==0x04 &&
        t->bytes[t->count-2]==0x0B && t->bytes[t->count-1]==0x53;
}
static int ccc_same(const CCC_Patch *s,const CCC_Target *t) {
    return s->function==t->function && s->bytes==t->bytes &&
        s->count==t->count && s->event_slot==t->event_slot && s->event_offset==t->event_offset;
}
static int ccc_is_owned(const CCC_Patch *s,const CCC_Target *t) {
    return ccc_same(s,t) && t->bytes[0]==0x04 && t->bytes[1]==0x0B &&
        *t->event_slot==NULL && *t->event_offset==s->original_offset &&
        s->tail_hash==ccc_tail_hash(t);
}
static int ccc_is_pending_owned(const CCC_Patch *s,const CCC_Target *t) {
    /* This allowance is ONLY for a transaction which our journal says was
     * interrupted. A previously completed guard still requires exact bytes.
     * Never overwrite a third value, a changed suffix/offset, or a new slot. */
    return s->pending && ccc_same(s,t) &&
        (t->bytes[0]==s->original[0] || t->bytes[0]==0x04) &&
        (t->bytes[1]==s->original[1] || t->bytes[1]==0x0B) &&
        (*t->event_slot==s->original_event || *t->event_slot==NULL) &&
        *t->event_offset==s->original_offset && s->tail_hash==ccc_tail_hash(t);
}
static int ccc_is_restored(const CCC_Patch *s,const CCC_Target *t) {
    return ccc_same(s,t) && t->bytes[0]==s->original[0] &&
        t->bytes[1]==s->original[1] && *t->event_slot==s->original_event &&
        *t->event_offset==s->original_offset && s->tail_hash==ccc_tail_hash(t);
}
static int ccc_patch(CCC_Patch *s,const CCC_Target *t,int action) {
    if (!ccc_target_valid(t)) return CCC_SCRIPT;
    if (s->owned && !ccc_same(s,t)) {
        if (s->function==t->function) return CCC_CONFLICT;
        /* Class was unloaded/replaced. Never dereference the retired pointers.
         * The adapter always resolves the exact currently registered function. */
        s->owned=0;
        s->pending=0;
    }
    if (action==CCC_CHECK) return s->owned && !s->pending && ccc_is_owned(s,t) ? CCC_OK : CCC_NOT_ARMED;
    if (action==CCC_DISABLE) {
        if (!s->owned) return CCC_OK;
        if (s->pending ? !ccc_is_pending_owned(s,t) : !ccc_is_owned(s,t)) return CCC_CONFLICT;
        s->pending=1;
        atomic_signal_fence(memory_order_seq_cst);
        CCC_GUARD_WRITE_BYTE(&t->bytes[0],s->original[0]);
        CCC_GUARD_WRITE_BYTE(&t->bytes[1],s->original[1]);
        CCC_GUARD_WRITE_EVENT(t->event_slot,s->original_event);
        atomic_signal_fence(memory_order_seq_cst);
        if (!ccc_is_restored(s,t)) return CCC_MEMORY;
        s->owned=0;
        s->pending=0;
        return CCC_OK;
    }
    if (action!=CCC_ENABLE) return CCC_SIGNATURE;
    if (s->owned) {
        if (!s->pending) return ccc_is_owned(s,t) ? CCC_OK : CCC_CONFLICT;
        if (!ccc_is_pending_owned(s,t)) return CCC_CONFLICT;
    } else {
        /* Do not adopt another mod's suppression, or an already empty function. */
        if (t->bytes[0]==0x04) return CCC_CONFLICT;
        s->function=t->function; s->bytes=t->bytes; s->count=t->count;
        s->event_slot=t->event_slot; s->original_event=*t->event_slot;
        s->event_offset=t->event_offset;
        s->original_offset=*t->event_offset;
        s->original[0]=t->bytes[0]; s->original[1]=t->bytes[1];
        s->tail_hash=ccc_tail_hash(t);
        s->owned=1;
        s->pending=1;
    }
    /* Return a void value before executing the Blueprint body. Also remove
     * this function's optional fastcall link into its shared event graph,
     * which could otherwise bypass the two-byte entry guard. The shared
     * graph and the entry offset itself are never modified. */
    atomic_signal_fence(memory_order_seq_cst);
    CCC_GUARD_WRITE_BYTE(&t->bytes[0],0x04); /* EX_Return */
    CCC_GUARD_WRITE_BYTE(&t->bytes[1],0x0B); /* EX_Nothing */
    CCC_GUARD_WRITE_EVENT(t->event_slot,NULL);
    atomic_signal_fence(memory_order_seq_cst);
    if (!ccc_is_owned(s,t)) return CCC_MEMORY;
    s->pending=0;
    return CCC_OK;
}
#endif
