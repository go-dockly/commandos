package actors

import "core:testing"
import "core:fmt"

import "../mission"
import "../nav"
import "../geom"

@(test)
test_alerted_guard_moves_to_last_known_position :: proc(t: ^testing.T) {
    guard := test_guard(awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {10, 0},
        })

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)
    level := mission.Mission{}
    defer mission.destroy(&level)

    guard_update(guards, &level, 1.0)

    testing.expect(t, guards[0].position.x > 0)
    testing.expect(t, guards[0].position.y >= 0)
    testing.expect(
        t,
        !mission.point_collides(
            &level,
            guards[0].position,
            guards[0].radius,
        ),
    )
}

@(test)
test_alerted_guard_stops_at_last_known_position :: proc(t: ^testing.T) {
    guard := test_guard(awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {1, 0},
        }, speed = 3)

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)
    level := mission.Mission{}
    defer mission.destroy(&level)

    guard_update(guards, &level, 1.0)
    guard_update(guards, &level, 1.0)

    // The navigation endpoint is the centre of the target grid cell.
    testing.expect(t, guards[0].position.x >= 1)
    testing.expect(t, guards[0].position.x < 2)
    testing.expect(t, guards[0].position.y >= 0)
    testing.expect(t, guards[0].position.y < 1)
}

@(test)
test_alerted_guard_cannot_move_through_building :: proc(t: ^testing.T) {
    level := mission.Mission{
        buildings = {
            geom.Rect{
                x = 2,
                y = -1,
                w = 1,
                h = 2,
            },
        },
    }
    defer mission.destroy(&level)

    guard := test_guard(awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {5, 0},
        }, speed = 1)

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)

    for _ in 0..<20 {
        guard_update(guards, &level, 0.1)
    }

    testing.expect(t, guards[0].position.x < 2)
}


@(test)
test_alerted_guard_begins_search_at_last_known_position :: proc(t: ^testing.T) {
    guard := test_guard(awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {0, 0},
        })

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)
    level := mission.Mission{}
    defer mission.destroy(&level)

    guard_update(guards, &level, 0.1)

    testing.expect(t, guards[0].search.active)
    testing.expect(t, guards[0].search.pause_remaining > 0)
    testing.expect(t, guards[0].position.x == 0)
}

@(test)
test_alerted_guard_scans_left_and_right :: proc(t: ^testing.T) {
    guard := test_guard(awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {0, 0},
        })

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)
    level := mission.Mission{}
    defer mission.destroy(&level)

    guard_update(guards, &level, 0.1)
    guard_update(guards, &level, 0.75)
    guard_update(guards, &level, 0.5)

    testing.expect(t, guards[0].search.active)
    testing.expect(t, guards[0].facing.y < 0)
}

@(test)
test_alerted_guard_enters_recovering_after_search :: proc(t: ^testing.T) {
    guard := test_guard(awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {0, 0},
        }, patrol = []geom.Point{{5, 0}, {10, 0}})

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)
    lvl := mission.Mission{}
    defer mission.destroy(&lvl)

    for _ in 0..<70 {
        guard_update(guards, &lvl, 0.1)
    }

    testing.expect(t, !guards[0].search.active)
    testing.expect(t, guards[0].awareness.state == .RECOVERING)
    testing.expect(t, guards[0].position.x > 0)
    testing.expect(t, guards[0].position.x < 5)
}

@(test)
test_alerted_guard_returns_to_patrol_after_search :: proc(t: ^testing.T) {
    guard := test_guard(awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {0, 0},
            last_known_source = .SIGHT,
        }, patrol = []geom.Point{{5, 0}, {10, 0}})

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)
    level := mission.Mission{}
    defer mission.destroy(&level)

    // Advance until the search transitions into recovery.
    for _ in 0..<100 {
        guard_update(guards, &level, 0.1)
        if guards[0].awareness.state == .RECOVERING {
            break
        }
    }

    testing.expect(t, guards[0].awareness.state == .RECOVERING)

    // Allow recovery pathfinding to finish across multiple updates.
    for _ in 0..<100 {
        guard_update(guards, &level, 0.1)

        if guards[0].awareness.state == .UNAWARE {
            break
        }
    }

    testing.expect(t, guards[0].awareness.state == .UNAWARE)
    testing.expect(t, guards[0].awareness.suspicion == 0)
    testing.expect(t, guards[0].awareness.last_known_source == .NONE)
    testing.expect(t, guards[0].position.x == 5)
    testing.expect(t, guards[0].position.y == 0)
}

@(test)
test_alerted_guard_resumes_pursuit_after_reacquisition :: proc(t: ^testing.T) {
    guard := test_guard(
        awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {10, 0},
        },
        searching = true,
        search_pause_remaining = 0.5,
    )

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)
    level := mission.Mission{}
    defer mission.destroy(&level)

    guards[0].player_visible = true
    guard_update(guards, &level, 0.5)

    testing.expect(t, !guards[0].search.active)
    testing.expect(t, guards[0].position.x > 0)
}

@(test)
test_suspicious_guard_moves_to_heard_noise :: proc(t: ^testing.T) {
    guard := test_guard(awareness = Guard_Awareness{
            state = .SUSPICIOUS,
            last_known_position = {10, 0},
            last_known_source = .SOUND,
        })

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)
    level := mission.Mission{}
    defer mission.destroy(&level)

    guard_update(guards, &level, 1.0)

    testing.expect(t, guards[0].position.x > 0)
    testing.expect(t, guards[0].awareness.state == .SUSPICIOUS)
    testing.expect(
        t,
        !mission.point_collides(
            &level,
            guards[0].position,
            guards[0].radius,
        ),
    )
}

@(test)
test_suspicious_guard_finishes_noise_search_and_resets :: proc(t: ^testing.T) {
    guard := test_guard(awareness = Guard_Awareness{
            state = .SUSPICIOUS,
            last_known_position = {0, 0},
            last_known_source = .SOUND,
        })

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)
    level := mission.Mission{}
    defer mission.destroy(&level)

    for _ in 0..<100 {
        guard_update(guards, &level, 0.1)
    }

    testing.expect(t, guards[0].awareness.state == .UNAWARE)
    testing.expect(t, guards[0].awareness.last_known_source == .NONE)
    testing.expect(t, !guards[0].search.active)
}


@(test)
test_alerted_guard_routes_around_building :: proc(t: ^testing.T) {
    level := mission.Mission{
        buildings = {
            geom.Rect{
                x = 2,
                y = -1,
                w = 1,
                h = 2,
            },
        },
    }
    defer mission.destroy(&level)

    guard := test_guard(awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {5, 0},
        })

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)

    routed_around := false
    reached_destination_cell := false

    for _ in 0..<500 {
        guard_update(guards, &level, 0.05)

        testing.expect(
            t,
            !mission.point_collides(
                &level,
                guards[0].position,
                guards[0].radius,
            ),
        )

        if guards[0].position.y > 1.8 ||
           guards[0].position.y < -1.8 {
            routed_around = true
        }

        if guards[0].position.x >= 5 &&
           guards[0].position.x < 6 &&
           guards[0].position.y >= 0 &&
           guards[0].position.y < 1 {
            reached_destination_cell = true
            break
        }
    }

    testing.expect(t, routed_around)
    testing.expect(t, reached_destination_cell)
}

@(test)
test_alerted_guard_does_not_move_toward_unreachable_target :: proc(
    t: ^testing.T,
) {
    level := mission.Mission{
        buildings = {
            geom.Rect{
                x = 20,
                y = 0,
                w = 2,
                h = 100,
            },
        },
    }
    defer mission.destroy(&level)

    guard := test_guard(position = {10.5, 10.5}, awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {30.5, 10.5},
        })

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)

    for _ in 0..<10 {
        guard_update(guards, &level, 0.1)
    }

    testing.expect(t, guards[0].position.x == 10.5)
    testing.expect(t, guards[0].position.y == 10.5)
    testing.expect(t, guards[0].awareness.state == .ALERTED)
    testing.expect(t, !guards[0].search.active)
}


@(test)
test_guard_visible_pursuit_uses_direct_steering :: proc(t: ^testing.T) {
    guard := test_guard(
        position = {0.2, 0.2},
        awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {5.8, 0.2},
            last_known_source = .SIGHT,
        },
        player_visible = true,
    )

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)

    level := mission.Mission{}
    defer mission.destroy(&level)

    guard_update(guards, &level, 0.1)

    testing.expect(t, guards[0].position.x > 0.2)
    testing.expect(t, guards[0].position.y == 0.2)
    testing.expect(t, guards[0].facing.x > 0.99)
    testing.expect(t, !guards[0].investigation.ready)
}

@(test)
test_guard_visible_pursuit_does_not_jitter_when_target_moves :: proc(
    t: ^testing.T,
) {
    level := mission.Mission{
        buildings = {
            geom.Rect{
                x = 2,
                y = -1,
                w = 1,
                h = 2,
            },
        },
    }
    defer mission.destroy(&level)

    guard := test_guard(awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {5, 0},
            last_known_source = .SIGHT,
        }, player_visible = true)

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)

    previous_position := guards[0].position
    direction_changes := 0
    previous_direction := 0

    for i in 0..<400 {
        // Move the visible target periodically while the guard pursues.
        if i == 100 {
            guards[0].awareness.last_known_position = {5, 2}
        } else if i == 200 {
            guards[0].awareness.last_known_position = {5, -2}
        } else if i == 300 {
            guards[0].awareness.last_known_position = {7, 0}
        }

        guard_update(guards, &level, 0.05)

        current := guards[0].position

        testing.expect(
            t,
            !mission.point_collides(
                &level,
                current,
                guards[0].radius,
            ),
        )

        dx := current.x - previous_position.x
        dy := current.y - previous_position.y

        if dx*dx + dy*dy > 0.000001 {
            direction := 0
            if abs(dx) > abs(dy) {
                direction = 1 if dx > 0 else -1
            } else {
                direction = 2 if dy > 0 else -2
            }

            if previous_direction != 0 &&
               direction != previous_direction {
                direction_changes += 1
            }

            previous_direction = direction
        }

        previous_position = current
    }

    testing.expect(t, direction_changes < 80)
}

@(test)
test_navigation_path_preserves_exact_start_position :: proc(
    t: ^testing.T,
) {
    level := mission.Mission{}
    defer mission.destroy(&level)

    start := geom.Point{0.2, 0.2}
    goal := geom.Point{5.5, 0.5}

    path := nav.find_path(
        &level,
        start,
        goal,
        GUARD_RADIUS,
    )
    defer delete(path.points)

    testing.expect(t, path.found)
    testing.expect(t, len(path.points) > 0)

    testing.expect(t, path.points[0].x == start.x)
    testing.expect(t, path.points[0].y == start.y)
}

@(test)
test_guard_visible_pursuit_uses_navigation_around_obstacle :: proc(
    t: ^testing.T,
) {
    level := mission.Mission{
        buildings = {
            geom.Rect{
                x = 2,
                y = -1,
                w = 1,
                h = 2,
            },
        },
    }
    defer mission.destroy(&level)

    guard := test_guard(awareness = Guard_Awareness{
            state = .ALERTED,
            last_known_position = {5, 0},
            last_known_source = .SIGHT,
        }, player_visible = true)

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)

    routed_around := false

    for _ in 0..<500 {
        guard_update(guards, &level, 0.05)

        testing.expect(
            t,
            !mission.point_collides(
                &level,
                guards[0].position,
                guards[0].radius,
            ),
        )

        if abs(guards[0].position.y) > 1.5 {
            routed_around = true
            break
        }
    }

    testing.expect(t, routed_around)
}