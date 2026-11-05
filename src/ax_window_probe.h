#ifndef AX_WINDOW_PROBE_H
#define AX_WINDOW_PROBE_H

// Returns an owned matching window, or releases the rejected probe. The caller
// transfers a successful result to window_manager_create_and_add_window.
static AXUIElementRef ax_window_probe_copy_match(CFDataRef token,
                                                const uint32_t *window_ids,
                                                int window_count,
                                                int *matched_index)
{
    AXUIElementRef element = _AXUIElementCreateWithRemoteToken(token);
    if (!element) return NULL;

    CFTypeRef role = NULL;
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role);
    if (role) {
        if (CFEqual(role, kAXWindowRole)) {
            uint32_t wid = 0;
            _AXUIElementGetWindow(element, &wid);
            if (wid) {
                for (int i = 0; i < window_count; ++i) {
                    if (window_ids[i] == wid) {
                        CFRelease(role);
                        *matched_index = i;
                        return element;
                    }
                }
            }
        }
        CFRelease(role);
    }

    CFRelease(element);
    return NULL;
}

#endif
