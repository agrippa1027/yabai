// Production resize writer, BSP tree/flush, signals and AX notification handlers.
// Only AX and display/Space API boundaries are modeled; no desktop events are posted.
#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdint.h>

static AXError fixture_copy(AXUIElementRef, CFStringRef, CFTypeRef *);
static AXError fixture_set(AXUIElementRef, CFStringRef, CFTypeRef);
void fixture_release(CFTypeRef);

unsigned char __src_osax_payload[1], __src_osax_loader[1];
unsigned int __src_osax_payload_len, __src_osax_loader_len;
#define AXUIElementCopyAttributeValue fixture_copy
#define AXUIElementSetAttributeValue fixture_set
#define CFRelease fixture_release
#include "../../src/manifest.m"
#undef CFRelease
#undef AXUIElementSetAttributeValue
#undef AXUIElementCopyAttributeValue

enum read_mode {
    READ_OK, READ_POSITION_ERROR, READ_SIZE_ERROR, READ_POSITION_MISSING,
    READ_SIZE_MISSING, READ_WRONG_TYPE, READ_WRONG_VALUE, READ_EMPTY_SIZE
};

static struct application application;
static struct window windows[2];
static struct window_node root, left, right;
static struct view view;
static CGRect actual[2];
static CGSize minimum;
static CGPoint anchor;
static enum read_mode read_mode;
static enum read_mode read_sequence[8];
static unsigned read_sequence_count, read_sequence_index;
static int reads, size_writes[2], position_writes[2], copied, released;
static CFMutableSetRef owned_values;

// The production display/Space path is deterministic and never reaches WindowServer.
CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid)
{
    assert(sid == 1);
    return CFRetain(CFSTR("00000000-0000-0000-0000-000000000001"));
}
CGDirectDisplayID CGDisplayGetDisplayIDFromUUID(CFUUIDRef uuid) { assert(uuid); return 1; }
CFUUIDRef CGDisplayCreateUUIDFromDisplayID(uint32_t did)
{
    assert(did == 1);
    return CFUUIDCreateFromString(NULL, CFSTR("00000000-0000-0000-0000-000000000001"));
}
uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef uuid) { assert(uuid); return 1; }
CGRect CGDisplayBounds(CGDirectDisplayID did) { assert(did == 1); return CGRectMake(-2000, -401, 1600, 601); }
CGError SLSGetMenuBarAutohideEnabled(int cid, int *enabled) { *enabled = 0; return kCGErrorSuccess; }
CGError SLSGetDisplayMenubarHeight(uint32_t did, uint32_t *height) { *height = 0; return kCGErrorSuccess; }
CGError SLSGetRevealedMenuBarBounds(CGRect *rect, int cid, uint64_t sid) { *rect = CGRectZero; return kCGErrorSuccess; }
Boolean CoreDockGetAutoHideEnabled(void) { return true; }

static int window_index(AXUIElementRef ref)
{
    for (int i = 0; i < 2; ++i) if (ref == windows[i].ref) return i;
    assert(!"unexpected AX element");
    return -1;
}

static AXError fixture_copy(AXUIElementRef ref, CFStringRef attribute, CFTypeRef *value)
{
    *value = NULL;
    if (ref == application.ref) {
        assert(CFEqual(attribute, kAXEnhancedUserInterface));
        *value = CFRetain(kCFBooleanFalse);
        return kAXErrorSuccess;
    }
    int i = window_index(ref);
    if (CFEqual(attribute, kAXFullscreenAttribute)) {
        *value = CFRetain(kCFBooleanFalse);
        return kAXErrorSuccess;
    }
    bool position = CFEqual(attribute, kAXPositionAttribute);
    assert(position || CFEqual(attribute, kAXSizeAttribute));
    reads++;
    enum read_mode mode = i == 0 ? read_mode : READ_OK;
    // Script complete position/size pairs to model transient feedback failures.
    if (i == 0 && read_sequence_index < read_sequence_count) {
        mode = read_sequence[read_sequence_index];
        if (!position) read_sequence_index++;
    }
    if ((position && mode == READ_POSITION_MISSING) ||
        (!position && mode == READ_SIZE_MISSING)) return kAXErrorSuccess;
    if (position && mode == READ_WRONG_TYPE) {
        *value = CFRetain(CFSTR("not an AXValue"));
    } else if (position && mode != READ_WRONG_VALUE) {
        *value = AXValueCreate(kAXValueTypeCGPoint, &actual[i].origin);
    } else {
        CGSize size = mode == READ_EMPTY_SIZE ? CGSizeZero : actual[i].size;
        *value = AXValueCreate(kAXValueTypeCGSize, &size);
    }
    assert(*value);
    CFSetAddValue(owned_values, *value);
    copied++;
    if ((position && mode == READ_POSITION_ERROR) ||
        (!position && mode == READ_SIZE_ERROR)) return kAXErrorCannotComplete;
    return kAXErrorSuccess;
}

void fixture_release(CFTypeRef value)
{
    if (owned_values && CFSetContainsValue(owned_values, value)) {
        CFSetRemoveValue(owned_values, value);
        released++;
    }
    CFRelease(value);
}

static AXError fixture_set(AXUIElementRef ref, CFStringRef attribute, CFTypeRef value)
{
    int i = window_index(ref);
    if (CFEqual(attribute, kAXPositionAttribute)) {
        assert(AXValueGetValue(value, kAXValueTypeCGPoint, &actual[i].origin));
        position_writes[i]++;
    } else {
        assert(CFEqual(attribute, kAXSizeAttribute));
        CGSize requested;
        assert(AXValueGetValue(value, kAXValueTypeCGSize, &requested));
        // App minimum-size feedback, rather than an unconditional accepted-frame override.
        actual[i].size.width = max(requested.width, i == 0 ? minimum.width : 1);
        actual[i].size.height = max(requested.height, i == 0 ? minimum.height : 1);
        size_writes[i]++;
    }
    // Deliberately leave window->frame stale: only production code may update it.
    return kAXErrorSuccess;
}

static void reset(bool managed)
{
    assert(copied == released && CFSetGetCount(owned_values) == 0);
    table_free(&g_window_manager.window);
    table_free(&g_window_manager.managed_window);
    g_window_manager = (struct window_manager){0};
    table_init(&g_window_manager.window, 8, hash_wm, compare_wm);
    table_init(&g_window_manager.managed_window, 8, hash_wm, compare_wm);
    g_signal_storage.used = 0;
    ts_reset();
    reads = copied = released = 0;
    memset(size_writes, 0, sizeof(size_writes));
    memset(position_writes, 0, sizeof(position_writes));
    read_mode = READ_OK;
    read_sequence_count = read_sequence_index = 0;
    minimum = CGSizeMake(1, 1);
    application = (struct application){ .name = "resize-fixture", .pid = 123 };
    application.ref = (AXUIElementRef)&application;
    left = (struct window_node){ .parent = &root, .window_count = 1 };
    right = (struct window_node){ .parent = &root, .window_count = 1 };
    root = (struct window_node){ .left = &left, .right = &right, .split = SPLIT_Y, .ratio = 0.5f };
    left.window_list[0] = left.window_order[0] = 100;
    right.window_list[0] = right.window_order[0] = 200;
    view = (struct view){ .sid = 1, .root = &root, .layout = VIEW_BSP };
    view_update(&view);
    for (int i = 0; i < 2; ++i) {
        struct area a = i == 0 ? left.area : right.area;
        actual[i] = CGRectMake(a.x, a.y, a.w, a.h);
        windows[i] = (struct window){ .id = i == 0 ? 100 : 200, .application = &application, .frame = actual[i] };
        windows[i].id_ptr = &windows[i].id;
        windows[i].ref = (AXUIElementRef)&windows[i];
        table_add(&g_window_manager.window, &windows[i].id, &windows[i]);
        if (managed) table_add(&g_window_manager.managed_window, &windows[i].id, &view);
    }
    assert(actual[0].size.width == 800 && actual[0].size.height == 600);
    anchor = CGPointMake(-1600, -100);
    g_mouse_state = (struct mouse_state){
        .window = &windows[0], .window_frame = windows[0].frame, .down_location = anchor,
        .current_action = MOUSE_MODE_RESIZE, .direction = HANDLE_RIGHT | HANDLE_BOTTOM
    };
}

static CGPoint point(CGFloat dx, CGFloat dy) { return CGPointMake(anchor.x+dx, anchor.y+dy); }

static void sequence(const enum read_mode *modes, unsigned count)
{
    assert(count <= array_count(read_sequence));
    memcpy(read_sequence, modes, count*sizeof(*modes));
    read_sequence_count = count;
    read_sequence_index = 0;
}

static int signals(enum signal_type type)
{
    int count = 0;
    struct event_signal *events = g_signal_storage.memory;
    for (unsigned i = 0; i < g_signal_storage.used/sizeof(*events); ++i) {
        if (events[i].type != type) continue;
        assert(strcmp(events[i].arg_value[0], "100") == 0);
        count++;
    }
    return count;
}

static void replay_notifications(bool resized_first)
{
    g_mouse_state.window = NULL;
    g_mouse_state.current_action = MOUSE_MODE_NONE;
    for (int repeat = 0; repeat < 2; ++repeat) {
        if (resized_first) EVENT_HANDLER_WINDOW_RESIZED((void *)(intptr_t)100, 0);
        EVENT_HANDLER_WINDOW_MOVED((void *)(intptr_t)100, 0);
        if (!resized_first) EVENT_HANDLER_WINDOW_RESIZED((void *)(intptr_t)100, 0);
    }
}

static void assert_tiles_match_tree(void)
{
    struct area a = left.area, b = right.area;
    assert(CGRectEqualToRect(actual[0], CGRectMake(a.x, a.y, a.w, a.h)));
    assert(CGRectEqualToRect(actual[1], CGRectMake(b.x, b.y, b.w, b.h)));
    CGFloat gap = CGRectGetMinX(actual[1])-CGRectGetMaxX(actual[0]);
    assert(gap >= 0 && gap <= 1); // Existing BSP integer pixel rounding.
}

static void pacing_uses_integer_nanoseconds(void)
{
    uint64_t bases[] = {1, UINT64_C(604800000000000), UINT64_C(8640000000000000), UINT64_C(1)<<60};
    for (unsigned i = 0; i < array_count(bases); ++i) {
        reset(false);
        mouse_resize_begin(&g_mouse_state);
        assert(mouse_resize_apply(&g_mouse_state, point(10, 0), bases[i], false));
        assert(!mouse_resize_apply(&g_mouse_state, point(20, 0), bases[i]+15999999, false));
        assert(g_mouse_state.last_moved_time == bases[i] && size_writes[0] == 1 && reads == 4);
        assert(mouse_resize_apply(&g_mouse_state, point(20, 0), bases[i]+16000000, false));
        assert(size_writes[0] == 2 && actual[0].size.width == 820 && reads == 6);
    }
}

static void new_gesture_resets_pacing_and_geometry(void)
{
    reset(false);
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_apply(&g_mouse_state, point(10, 0), 1000000000, false));
    anchor = g_mouse_state.down_location = point(10, 0);
    mouse_resize_begin(&g_mouse_state);
    assert(g_mouse_state.last_moved_time == 0 && g_mouse_state.window_frame.size.width == 810);
    assert(mouse_resize_apply(&g_mouse_state, point(5, 0), 1000000001, false));
    assert(actual[0].size.width == 815);
}

static void fractional_motion_ignores_stale_async_cache(void)
{
    reset(false);
    mouse_resize_begin(&g_mouse_state);
    CGRect initial = g_mouse_state.window_frame;
    assert(mouse_resize_apply(&g_mouse_state, point(10.25, -4.5), 1000000000, false));
    windows[0].frame = CGRectMake(999, 999, 1, 1);
    assert(mouse_resize_apply(&g_mouse_state, point(20.5, -8.25), 1016000000, false));
    assert(actual[0].size.width == 820.5 && actual[0].size.height == 591.75);
    assert(CGRectEqualToRect(g_mouse_state.window_frame, initial));
    assert(CGRectEqualToRect(g_mouse_state.resize_frame, actual[0]));
    assert(CGPointEqualToPoint(g_mouse_state.down_location, anchor));
    assert(reads == 6); // One two-attribute feedback read per applied sample.
}

static void release_flushes_throttled_endpoint(void)
{
    reset(false);
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_apply(&g_mouse_state, point(10, 0), 1000000000, false));
    assert(!mouse_resize_apply(&g_mouse_state, point(20, 0), 1001000000, false));
    assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, point(25.5, 0), 1002000000));
    assert(size_writes[0] == 2 && windows[0].frame.size.width == 825.5 && reads == 8);
    assert(signals(SIGNAL_WINDOW_RESIZED) == 1);
}

static void release_without_drag_uses_endpoint(void)
{
    reset(false);
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, point(12, -6), 1));
    assert(size_writes[0] == 1 && windows[0].frame.size.width == 812 && windows[0].frame.size.height == 594);
}

static void minimum_size_small_reversal_is_immediate(void)
{
    reset(false);
    minimum = CGSizeMake(400, 200);
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_apply(&g_mouse_state, point(-600, -500), 1000000000, false));
    assert(actual[0].size.width == 400 && actual[0].size.height == 200);
    assert(mouse_resize_apply(&g_mouse_state, point(-580, -480), 1016000000, false));
    assert(actual[0].size.width == 420 && actual[0].size.height == 220);
    assert(windows[0].frame.size.width == 800 && g_mouse_state.window_frame.size.width == 800);
}

static void release_small_reversal_uses_constraint_feedback(void)
{
    reset(false);
    minimum.width = 400;
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_apply(&g_mouse_state, point(-600, 0), 1000000000, false));
    assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, point(-580, 0), 1000000001));
    assert(windows[0].frame.size.width == 420 && size_writes[0] == 2);
}

static void repeated_overshoot_does_not_accumulate_dead_zone(void)
{
    reset(false);
    minimum.width = 400;
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_apply(&g_mouse_state, point(-600, 0), 1000000000, false));
    assert(mouse_resize_apply(&g_mouse_state, point(-900, 0), 1016000000, false));
    assert(actual[0].size.width == 400);
    assert(mouse_resize_apply(&g_mouse_state, point(-880, 0), 1032000000, false));
    assert(actual[0].size.width == 420);
}

static void failed_feedback_blocks_stale_writes_until_recovered(void)
{
    reset(false);
    minimum.width = 400;
    mouse_resize_begin(&g_mouse_state);
    read_mode = READ_SIZE_ERROR;
    assert(mouse_resize_apply(&g_mouse_state, point(-600, 0), 1000000000, false));
    assert(!g_mouse_state.resize_frame_valid && actual[0].size.width == 400);
    assert(!mouse_resize_apply(&g_mouse_state, point(-590, 0), 1016000000, false));
    assert(size_writes[0] == 1 && CGPointEqualToPoint(g_mouse_state.resize_location, point(-600, 0)));
    read_mode = READ_OK;
    assert(mouse_resize_apply(&g_mouse_state, point(-580, 0), 1032000000, false));
    assert(actual[0].size.width == 420 && g_mouse_state.resize_frame_valid);
}

static void release_retries_pending_endpoint_after_transient_read_failures(void)
{
    for (int managed = 0; managed <= 1; ++managed) {
        reset(managed);
        minimum.width = 400;
        mouse_resize_begin(&g_mouse_state);
        enum read_mode modes[] = {READ_SIZE_ERROR, READ_POSITION_ERROR, READ_OK, READ_OK};
        sequence(modes, array_count(modes));
        assert(mouse_resize_apply(&g_mouse_state, point(-600, 0), 1000000000, false));
        assert(!g_mouse_state.resize_frame_valid && actual[0].size.width == 400);
        assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, point(-580, 0), 1000000001));
        assert(CGPointEqualToPoint(g_mouse_state.resize_location, point(-580, 0)));
        assert(windows[0].frame.size.width == 420 && g_mouse_state.resize_frame_valid);
        assert(read_sequence_index == 4 && reads == 10);
        assert(signals(SIGNAL_WINDOW_RESIZED) == 1 && signals(SIGNAL_WINDOW_MOVED) == 0);
        if (managed) {
            assert(fabsf(root.ratio-420.0f/1600.0f) < 0.000001f);
            assert_tiles_match_tree();
            assert(size_writes[0] == 4 && size_writes[1] == 2);
        } else {
            assert(actual[0].size.width == 420 && size_writes[0] == 2 && size_writes[1] == 0);
            replay_notifications(true);
            assert(signals(SIGNAL_WINDOW_RESIZED) == 1);
        }
    }
}

static void release_retry_failed_feedback_restores_or_reports_failure(void)
{
    for (int managed = 0; managed <= 1; ++managed) {
        reset(managed);
        mouse_resize_begin(&g_mouse_state);
        enum read_mode modes[] = {READ_SIZE_ERROR, READ_POSITION_ERROR, READ_OK, READ_SIZE_ERROR};
        sequence(modes, array_count(modes));
        assert(mouse_resize_apply(&g_mouse_state, point(200, 0), 1000000000, false));
        assert(!mouse_resize_finish(&g_mouse_state, &g_window_manager, point(220, 0), 1000000001));
        assert(read_sequence_index == 4 && reads == 10);
        assert(CGPointEqualToPoint(g_mouse_state.resize_location, point(220, 0)));
        assert(!g_mouse_state.resize_frame_valid && windows[0].frame.size.width == 800);
        assert(root.ratio == 0.5f && g_signal_storage.used == 0);
        if (managed) {
            assert_tiles_match_tree();
            assert(actual[0].size.width == 800 && size_writes[0] == 4);
        } else {
            assert(actual[0].size.width == 1020 && size_writes[0] == 2);
        }
        assert(size_writes[1] == 0);
    }
}

static void release_without_recovered_geometry_fails_bounded(void)
{
    for (int managed = 0; managed <= 1; ++managed) {
        reset(managed);
        mouse_resize_begin(&g_mouse_state);
        enum read_mode modes[] = {READ_SIZE_ERROR, READ_POSITION_ERROR, READ_SIZE_ERROR};
        sequence(modes, array_count(modes));
        assert(mouse_resize_apply(&g_mouse_state, point(200, 0), 1000000000, false));
        assert(!mouse_resize_finish(&g_mouse_state, &g_window_manager, point(220, 0), 1000000001));
        assert(read_sequence_index == 3 && reads == 8);
        assert(CGPointEqualToPoint(g_mouse_state.resize_location, point(200, 0)));
        assert(root.ratio == 0.5f && g_signal_storage.used == 0 && size_writes[1] == 0);
        if (managed) {
            assert_tiles_match_tree();
            assert(actual[0].size.width == 800 && size_writes[0] == 3);
        } else {
            assert(actual[0].size.width == 1000 && size_writes[0] == 1);
        }
    }
}

static void unchanged_release_recovers_feedback_without_retrying_write(void)
{
    for (int managed = 0; managed <= 1; ++managed) {
        reset(managed);
        mouse_resize_begin(&g_mouse_state);
        enum read_mode modes[] = {READ_SIZE_ERROR, READ_OK};
        sequence(modes, array_count(modes));
        assert(mouse_resize_apply(&g_mouse_state, point(100, 0), 1000000000, false));
        assert(!g_mouse_state.resize_frame_valid);
        assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, point(100, 0), 1000000001));
        assert(read_sequence_index == 2 && reads == 6 && windows[0].frame.size.width == 900);
        assert(signals(SIGNAL_WINDOW_RESIZED) == 1);
        if (managed) {
            assert_tiles_match_tree();
            assert(size_writes[0] == 3 && size_writes[1] == 2);
        } else {
            assert(size_writes[0] == 1 && size_writes[1] == 0);
        }
    }
}

static void bsp_release_updates_physical_neighbor(void)
{
    reset(true);
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_apply(&g_mouse_state, point(100, 0), 1000000000, false));
    assert(CGRectGetMaxX(actual[0]) > CGRectGetMinX(actual[1]));
    assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, point(100, 0), 1000000001));
    assert(actual[0].size.width == 900 && actual[1].size.width == 700);
    assert(size_writes[1] == 2 && fabsf(root.ratio-0.5625f) < 0.000001f);
    assert_tiles_match_tree();
    assert(signals(SIGNAL_WINDOW_RESIZED) == 1);
    replay_notifications(false);
    assert(signals(SIGNAL_WINDOW_RESIZED) == 1 && signals(SIGNAL_WINDOW_MOVED) == 0);
}

static void bsp_uses_initial_to_accepted_delta_after_reversal(void)
{
    reset(true);
    minimum.width = 400;
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_apply(&g_mouse_state, point(-600, 0), 1000000000, false));
    assert(mouse_resize_apply(&g_mouse_state, point(-580, 0), 1016000000, false));
    assert(actual[0].size.width == 420 && g_mouse_state.window_frame.size.width == 800);
    assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, point(-580, 0), 1016000001));
    assert(fabsf(root.ratio-420.0f/1600.0f) < 0.000001f);
    assert(fabs(actual[0].size.width-420) <= 1 && size_writes[1] == 2);
    assert_tiles_match_tree();
}

static void failed_release_restores_original_physical_bsp_tile(void)
{
    for (int mode = READ_POSITION_ERROR; mode <= READ_EMPTY_SIZE; ++mode) {
        reset(true);
        mouse_resize_begin(&g_mouse_state);
        CGRect original = actual[0], neighbor = actual[1], cache = windows[0].frame;
        assert(mouse_resize_apply(&g_mouse_state, point(200, 0), 1000000000, false));
        assert(CGRectGetMaxX(actual[0]) > CGRectGetMinX(actual[1]));
        read_mode = mode;
        assert(!mouse_resize_finish(&g_mouse_state, &g_window_manager, point(200, 0), 1000000001));
        assert(CGRectEqualToRect(actual[0], original) && CGRectEqualToRect(actual[1], neighbor));
        assert(CGRectEqualToRect(windows[0].frame, cache) && root.ratio == 0.5f);
        assert(size_writes[0] == 3 && size_writes[1] == 0);
        assert(signals(SIGNAL_WINDOW_MOVED) == 0 && signals(SIGNAL_WINDOW_RESIZED) == 0);
        assert_tiles_match_tree();
        assert(copied == released);
    }
}

static void failed_floating_release_preserves_cache_for_notification(void)
{
    reset(false);
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_apply(&g_mouse_state, point(100, 0), 1000000000, false));
    read_mode = READ_SIZE_ERROR;
    assert(!mouse_resize_finish(&g_mouse_state, &g_window_manager, point(100, 0), 1000000001));
    assert(actual[0].size.width == 900 && windows[0].frame.size.width == 800 && size_writes[0] == 1);
    read_mode = READ_OK;
    replay_notifications(false);
    assert(windows[0].frame.size.width == 900 && signals(SIGNAL_WINDOW_RESIZED) == 1);
}

static void cache_delta_signals_once_with_both_notification_orders(void)
{
    for (int order = 0; order < 2; ++order) {
        for (int change = 0; change < 4; ++change) {
            reset(false);
            if (change >= 2) g_mouse_state.direction = HANDLE_LEFT;
            if (change == 2) minimum.width = 800;
            mouse_resize_begin(&g_mouse_state);
            CGPoint end = change == 0 ? anchor : point(20, 0);
            assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, end, 1));
            int moved = change >= 2, resized = change == 1 || change == 3;
            assert(signals(SIGNAL_WINDOW_MOVED) == moved && signals(SIGNAL_WINDOW_RESIZED) == resized);
            assert(CGRectEqualToRect(windows[0].frame, actual[0]));
            replay_notifications(order);
            assert(signals(SIGNAL_WINDOW_MOVED) == moved && signals(SIGNAL_WINDOW_RESIZED) == resized);
        }
    }
}

static void already_observed_move_is_not_signaled_twice(void)
{
    reset(false);
    g_mouse_state.direction = HANDLE_LEFT;
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_apply(&g_mouse_state, point(20, 0), 1000000000, false));
    EVENT_HANDLER_WINDOW_MOVED((void *)(intptr_t)100, 0);
    assert(signals(SIGNAL_WINDOW_MOVED) == 1 && signals(SIGNAL_WINDOW_RESIZED) == 0);
    assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, point(20, 0), 1000000001));
    replay_notifications(true);
    assert(signals(SIGNAL_WINDOW_MOVED) == 1 && signals(SIGNAL_WINDOW_RESIZED) == 1);
}

static void already_observed_resize_is_not_signaled_twice(void)
{
    reset(false);
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_apply(&g_mouse_state, point(20, 0), 1000000000, false));
    EVENT_HANDLER_WINDOW_RESIZED((void *)(intptr_t)100, 0);
    assert(signals(SIGNAL_WINDOW_RESIZED) == 1);
    assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, point(20, 0), 1000000001));
    replay_notifications(false);
    assert(signals(SIGNAL_WINDOW_RESIZED) == 1 && signals(SIGNAL_WINDOW_MOVED) == 0);
}

static void unchanged_release_does_not_repeat_writes(void)
{
    reset(false);
    mouse_resize_begin(&g_mouse_state);
    assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, anchor, 1));
    assert(size_writes[0] == 0 && signals(SIGNAL_WINDOW_RESIZED) == 0);
    assert(mouse_resize_apply(&g_mouse_state, point(10, 0), 1000000000, false));
    assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, point(10, 0), 1000000001));
    assert(size_writes[0] == 1 && signals(SIGNAL_WINDOW_RESIZED) == 1);
}

static void initial_read_failure_requires_refresh_before_writing(void)
{
    reset(false);
    actual[0].size.width = 900;
    read_mode = READ_POSITION_ERROR;
    mouse_resize_begin(&g_mouse_state);
    assert(!g_mouse_state.resize_frame_valid && g_mouse_state.window_frame.size.width == 800);
    assert(!mouse_resize_apply(&g_mouse_state, point(10, 0), 1, false) && size_writes[0] == 0);
    read_mode = READ_OK;
    assert(mouse_resize_apply(&g_mouse_state, point(10, 0), 2, false));
    assert(actual[0].size.width == 910);
}

static void unconstrained_corners_reverse_to_initial_frame(void)
{
    int corners[] = {HANDLE_LEFT|HANDLE_TOP, HANDLE_RIGHT|HANDLE_TOP,
                     HANDLE_LEFT|HANDLE_BOTTOM, HANDLE_RIGHT|HANDLE_BOTTOM};
    for (unsigned i = 0; i < array_count(corners); ++i) {
        reset(false);
        g_mouse_state.direction = corners[i];
        mouse_resize_begin(&g_mouse_state);
        CGRect initial = actual[0];
        assert(mouse_resize_apply(&g_mouse_state, point(10.5, -20.25), 1000000000, false));
        assert(CGRectEqualToRect(g_mouse_state.resize_frame, actual[0]));
        assert(mouse_resize_finish(&g_mouse_state, &g_window_manager, anchor, 1000000001));
        assert(CGRectEqualToRect(actual[0], initial) && CGRectEqualToRect(g_mouse_state.window_frame, initial));
    }
}

static void invalid_fullscreen_and_nonresize_windows_are_ignored(void)
{
    for (int reason = 0; reason < 4; ++reason) {
        reset(false);
        mouse_resize_begin(&g_mouse_state);
        if (reason == 0) windows[0].id_ptr = NULL;
        if (reason == 1) windows[0].flags |= WINDOW_FULLSCREEN;
        if (reason == 2) g_mouse_state.current_action = MOUSE_MODE_MOVE;
        if (reason == 3) g_mouse_state.window = NULL;
        assert(!mouse_resize_apply(&g_mouse_state, point(10, 0), 1, false));
        assert(!mouse_resize_finish(&g_mouse_state, &g_window_manager, point(10, 0), 2));
        assert(size_writes[0] == 0 && reads == 2 && g_signal_storage.used == 0);
    }
}

#define TEST(name) { #name, name }
int main(void)
{
    assert(ts_init(MEGABYTES(8)));
    assert(memory_pool_init(&g_signal_storage, KILOBYTES(256)));
    owned_values = CFSetCreateMutable(NULL, 0, NULL);
    // Inspect the production signal queue without flushing/running subscriber commands.
    struct signal subscriber = {0};
    buf_push(g_signal_event[SIGNAL_WINDOW_MOVED], subscriber);
    buf_push(g_signal_event[SIGNAL_WINDOW_RESIZED], subscriber);
    struct { const char *name; void (*run)(void); } tests[] = {
        TEST(pacing_uses_integer_nanoseconds),
        TEST(new_gesture_resets_pacing_and_geometry),
        TEST(fractional_motion_ignores_stale_async_cache),
        TEST(release_flushes_throttled_endpoint),
        TEST(release_without_drag_uses_endpoint),
        TEST(minimum_size_small_reversal_is_immediate),
        TEST(release_small_reversal_uses_constraint_feedback),
        TEST(repeated_overshoot_does_not_accumulate_dead_zone),
        TEST(failed_feedback_blocks_stale_writes_until_recovered),
        TEST(release_retries_pending_endpoint_after_transient_read_failures),
        TEST(release_retry_failed_feedback_restores_or_reports_failure),
        TEST(release_without_recovered_geometry_fails_bounded),
        TEST(unchanged_release_recovers_feedback_without_retrying_write),
        TEST(bsp_release_updates_physical_neighbor),
        TEST(bsp_uses_initial_to_accepted_delta_after_reversal),
        TEST(failed_release_restores_original_physical_bsp_tile),
        TEST(failed_floating_release_preserves_cache_for_notification),
        TEST(cache_delta_signals_once_with_both_notification_orders),
        TEST(already_observed_move_is_not_signaled_twice),
        TEST(already_observed_resize_is_not_signaled_twice),
        TEST(unchanged_release_does_not_repeat_writes),
        TEST(initial_read_failure_requires_refresh_before_writing),
        TEST(unconstrained_corners_reverse_to_initial_frame),
        TEST(invalid_fullscreen_and_nonresize_windows_are_ignored)
    };
    for (unsigned i = 0; i < array_count(tests); ++i) {
        tests[i].run();
        assert(copied == released && CFSetGetCount(owned_values) == 0);
        printf("PASS: %s\n", tests[i].name);
    }
    printf("PASS: %d production resize/BSP/signal regressions; modeled AX/display APIs only\n", (int)array_count(tests));
    table_free(&g_window_manager.window);
    table_free(&g_window_manager.managed_window);
    buf_free(g_signal_event[SIGNAL_WINDOW_MOVED]);
    buf_free(g_signal_event[SIGNAL_WINDOW_RESIZED]);
    CFRelease(owned_values);
    munmap(g_temp_storage.memory, g_temp_storage.size+getpagesize());
    munmap(g_signal_storage.memory, g_signal_storage.size+getpagesize());
    return 0;
}
