#ifndef MOUSE_RESIZE_H
#define MOUSE_RESIZE_H

// Read both attributes successfully before replacing any cached geometry.
static bool mouse_resize_read_frame(struct window *window, CGRect *frame)
{
    CFTypeRef position = NULL, size = NULL;
    AXError position_error = AXUIElementCopyAttributeValue(window->ref, kAXPositionAttribute, &position);
    AXError size_error = AXUIElementCopyAttributeValue(window->ref, kAXSizeAttribute, &size);
    CGRect result = {0};
    bool success = position_error == kAXErrorSuccess && size_error == kAXErrorSuccess &&
                   position && size &&
                   CFGetTypeID(position) == AXValueGetTypeID() &&
                   CFGetTypeID(size) == AXValueGetTypeID() &&
                   AXValueGetValue(position, kAXValueTypeCGPoint, &result.origin) &&
                   AXValueGetValue(size, kAXValueTypeCGSize, &result.size) &&
                   result.size.width > 0 && result.size.height > 0;
    if (position) CFRelease(position);
    if (size) CFRelease(size);
    if (success) *frame = result;
    return success;
}

static void mouse_resize_begin(struct mouse_state *ms)
{
    ms->last_moved_time = 0;
    ms->resize_location = ms->down_location;
    ms->resize_frame_valid = mouse_resize_read_frame(ms->window, &ms->window_frame);
    ms->resize_frame = ms->window_frame;
}

static bool mouse_resize_window_is_valid(struct mouse_state *ms)
{
    return ms->window && ms->current_action == MOUSE_MODE_RESIZE &&
           !window_check_flag(ms->window, WINDOW_FULLSCREEN) &&
           __sync_bool_compare_and_swap(&ms->window->id_ptr, &ms->window->id, &ms->window->id);
}

static bool mouse_resize_apply(struct mouse_state *ms, CGPoint point, uint64_t now, bool force)
{
    if (!mouse_resize_window_is_valid(ms)) return false;
    if (CGPointEqualToPoint(point, ms->resize_location)) return false;
    if (!force && ms->last_moved_time && now - ms->last_moved_time < UINT64_C(16000000)) return false;

    // Keep accepted geometry separate from the asynchronous notification cache.
    // Rebase at each applied pointer so reversing at an app size limit is immediate.
    if (!ms->resize_frame_valid) {
        ms->resize_frame_valid = mouse_resize_read_frame(ms->window, &ms->resize_frame);
        if (!ms->resize_frame_valid) return false;
    }
    float dx = point.x - ms->resize_location.x;
    float dy = point.y - ms->resize_location.y;
    window_manager_resize_window_relative_internal(ms->window, ms->resize_frame, ms->direction, dx, dy, false);
    ms->resize_location = point;
    ms->last_moved_time = now;
    ms->resize_frame_valid = mouse_resize_read_frame(ms->window, &ms->resize_frame);
    return true;
}

static bool mouse_resize_finish(struct mouse_state *ms, struct window_manager *wm, CGPoint point, uint64_t now)
{
    if (!mouse_resize_window_is_valid(ms)) return false;

    // The release endpoint is not subject to pacing, including for floating windows.
    mouse_resize_apply(ms, point, now, true);
    struct view *view = window_manager_find_managed_window(wm, ms->window);
    CGRect frame;
    if (!mouse_resize_read_frame(ms->window, &frame)) goto restore;

    if (!CGPointEqualToPoint(point, ms->resize_location)) {
        // A failed preparatory read can leave the endpoint unapplied even though
        // this read recovered. Retry once from that accepted geometry, not the cache.
        ms->resize_frame = frame;
        ms->resize_frame_valid = true;
        if (!mouse_resize_apply(ms, point, now, true) || !ms->resize_frame_valid ||
            !CGPointEqualToPoint(point, ms->resize_location)) goto restore;
        frame = ms->resize_frame;
    }

    // Queued AX handlers will debounce against this cache. Account for changes
    // they have not observed before replacing it, including for floating windows.
    if (!CGPointEqualToPoint(ms->window->frame.origin, frame.origin)) {
        event_signal_push(SIGNAL_WINDOW_MOVED, ms->window);
    }
    if (!CGSizeEqualToSize(ms->window->frame.size, frame.size)) {
        event_signal_push(SIGNAL_WINDOW_RESIZED, ms->window);
    }
    ms->window->frame = frame;

    if (view) {
        struct mouse_window_info info;
        mouse_window_info_populate(ms, &info);
        if (info.changed_position || info.changed_size) {
            mouse_drop_try_adjust_bsp_grid(wm, view, ms->window, &info);
        }
    }
    return true;

restore:
    // No trustworthy completed endpoint: restore the original tile rather than
    // leaving a physically resized window overlapping its unchanged BSP neighbours.
    if (view) {
        struct window_node *node = view_find_window_node(view, ms->window->id);
        if (node) window_node_flush(node);
    }
    return false;
}

#endif
