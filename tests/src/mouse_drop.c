// Native tree regressions: no real windows are registered, so no AX or
// WindowServer mutations occur when the production drag handlers flush tiles.
TEST_FUNC(directional_sibling_drop_is_idempotent,
{
    table_init(&g_window_manager.window, 8, hash_wm, compare_wm);
    for (int axis = SPLIT_Y; axis <= SPLIT_X; ++axis) {
        for (int source_first = 0; source_first <= 1; ++source_first) {
            for (int requested_first = 0; requested_first <= 1; ++requested_first) {
                struct window_node parent = { .split = axis };
                struct window_node left = { .parent = &parent, .window_count = 1 };
                struct window_node right = { .parent = &parent, .window_count = 1 };
                parent.left = &left;
                parent.right = &right;
                left.window_list[0] = left.window_order[0] = source_first ? 100 : 200;
                right.window_list[0] = right.window_order[0] = source_first ? 200 : 100;
                struct window source = { .id = 100 }, target = { .id = 200 };
                struct view view = { .sid = 1, .root = &parent, .insertion_point = 100 };
                for (int repeat = 0; repeat < 5; ++repeat) {
                    struct window_node *src = left.window_list[0] == 100 ? &left : &right;
                    struct window_node *dst = src == &left ? &right : &left;
                    mouse_drop_action_warp(&g_window_manager, &view, src, &source,
                                          &view, dst, &target, axis,
                                          requested_first ? CHILD_FIRST : CHILD_SECOND);
                    bool placed_first = left.window_list[0] == 100;
                    TEST_CHECK(placed_first, (bool) requested_first);
                    TEST_CHECK(parent.split, axis);
                    TEST_CHECK(left.window_count, 1);
                    TEST_CHECK(right.window_count, 1);
                }
            }
        }
    }
    table_free(&g_window_manager.window);
});

TEST_FUNC(center_drop_still_swaps_siblings,
{
    table_init(&g_window_manager.window, 8, hash_wm, compare_wm);
    struct window_node parent = { .split = SPLIT_Y };
    struct window_node left = { .parent = &parent, .window_count = 1 };
    struct window_node right = { .parent = &parent, .window_count = 1 };
    parent.left = &left;
    parent.right = &right;
    left.window_list[0] = left.window_order[0] = 100;
    right.window_list[0] = right.window_order[0] = 200;
    struct window source = { .id = 100 }, target = { .id = 200 };
    struct view view = { .sid = 1, .root = &parent };
    mouse_drop_action_swap(&g_window_manager, &view, &left, &source,
                          &view, &right, &target);
    TEST_CHECK(left.window_list[0], 200);
    TEST_CHECK(right.window_list[0], 100);
    table_free(&g_window_manager.window);
});

TEST_FUNC(drop_zones_follow_pointer_on_each_display,
{
    struct mouse_state state = { .drop_action = MOUSE_MODE_SWAP };
    struct window_node source = { .window_count = 1 };
    for (int offset = 0; offset < 2; ++offset) {
        struct window target = { .frame = {{ offset ? -2560 : 10, offset ? -430 : 40 }, {800, 600}} };
        CGPoint origin = target.frame.origin;
        enum mouse_drop_action center = mouse_determine_drop_action(&state, &source, &target, CGPointMake(origin.x+400, origin.y+300));
        enum mouse_drop_action left = mouse_determine_drop_action(&state, &source, &target, CGPointMake(origin.x+80, origin.y+300));
        enum mouse_drop_action right = mouse_determine_drop_action(&state, &source, &target, CGPointMake(origin.x+720, origin.y+300));
        enum mouse_drop_action top = mouse_determine_drop_action(&state, &source, &target, CGPointMake(origin.x+400, origin.y+60));
        enum mouse_drop_action bottom = mouse_determine_drop_action(&state, &source, &target, CGPointMake(origin.x+400, origin.y+540));
        TEST_CHECK(center, MOUSE_DROP_ACTION_SWAP);
        TEST_CHECK(left, MOUSE_DROP_ACTION_WARP_LEFT);
        TEST_CHECK(right, MOUSE_DROP_ACTION_WARP_RIGHT);
        TEST_CHECK(top, MOUSE_DROP_ACTION_WARP_TOP);
        TEST_CHECK(bottom, MOUSE_DROP_ACTION_WARP_BOTTOM);
    }
});
