// Isolated ownership regressions for the production fallback probe helper.
// No real Accessibility requests, windows or desktop events are used.
#import <ApplicationServices/ApplicationServices.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>

static int created, released, role_released;
static bool fail_create;
static CFStringRef reported_role;
static uint32_t reported_wid;
static CFTypeRef last_element;

static AXUIElementRef fake_create(CFDataRef token)
{
    if (fail_create) return NULL;
    UInt8 bytes[32] = {0};
    last_element = CFDataCreate(NULL, bytes, sizeof(bytes));
    created++;
    return (AXUIElementRef)last_element;
}

static AXError fake_role(AXUIElementRef element, CFStringRef attribute, CFTypeRef *role)
{
    assert((CFTypeRef)element == last_element);
    assert(CFEqual(attribute, kAXRoleAttribute));
    *role = reported_role ? CFRetain(reported_role) : NULL;
    return reported_role ? kAXErrorSuccess : kAXErrorAttributeUnsupported;
}

static AXError fake_window(AXUIElementRef element, uint32_t *wid)
{
    assert((CFTypeRef)element == last_element);
    *wid = reported_wid;
    return kAXErrorSuccess;
}

static void counted_release(CFTypeRef object)
{
    if (object == last_element) released++;
    else { assert(object == reported_role); role_released++; }
    CFRelease(object);
}

#define _AXUIElementCreateWithRemoteToken fake_create
#define AXUIElementCopyAttributeValue fake_role
#define _AXUIElementGetWindow fake_window
#define CFRelease counted_release
#include "../../src/ax_window_probe.h"
#undef CFRelease
#undef _AXUIElementGetWindow
#undef AXUIElementCopyAttributeValue
#undef _AXUIElementCreateWithRemoteToken

int main(void)
{
    uint32_t targets[] = {100, 200};
    int index = -1;
    fail_create = true;
    assert(!ax_window_probe_copy_match(NULL, targets, 2, &index));
    assert(created == 0 && released == 0 && index == -1);
    fail_create = false;

    // A maximum-length scan with absent roles must retain no candidate refs.
    for (int i = 0; i < 0x7fff; ++i) {
        assert(!ax_window_probe_copy_match(NULL, targets, 2, &index));
        assert(created == released && index == -1);
    }
    reported_role = kAXButtonRole;
    assert(!ax_window_probe_copy_match(NULL, targets, 2, &index));
    assert(created == released && role_released == 1);

    reported_role = kAXWindowRole;
    reported_wid = 0;
    assert(!ax_window_probe_copy_match(NULL, targets, 2, &index));
    assert(created == released && role_released == 2);
    reported_wid = 300;
    assert(!ax_window_probe_copy_match(NULL, targets, 2, &index));
    assert(created == released && role_released == 3);

    reported_wid = 200;
    AXUIElementRef match = ax_window_probe_copy_match(NULL, targets, 2, &index);
    assert(match == (AXUIElementRef)last_element && index == 1);
    assert(created == released + 1 && role_released == 4);
    counted_release(match); // Model the adopting window owner's release.
    assert(created == released);
    printf("PASS: %d probes, zero retained after owner cleanup; null/absent/non-window/unmatched/matched paths\n", created);
}
