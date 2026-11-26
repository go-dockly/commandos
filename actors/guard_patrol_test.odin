package actors

import "core:testing"
import "core:fmt"

import "../mission"
import "../geom"

@(test)
test_guard_patrol_routes_around_adjacent_crates :: proc(t: ^testing.T) {
    level := mission.Mission{
        cover = {
            geom.Cover{
                kind = "crate",
                x = 33,
                y = 42,
                w = 4,
                h = 3,
            },
            geom.Cover{
                kind = "crate",
                x = 38,
                y = 45,
                w = 4,
                h = 3,
            },
        },
    }
    defer mission.destroy(&level)

    guard := test_guard(
        position = {25, 48},
        patrol = []geom.Point{
            {25, 48},
            {43.5, 49.5},
        },
        target_index = 1,
        speed = 3.2,
        pause_duration = 1.0,
    )

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)

    reached_waypoint := false

    for _ in 0..<1000 {
        guard_update(guards, &level, 0.05)

        testing.expect(
            t,
            !mission.point_collides(
                &level,
                guards[0].position,
                guards[0].radius,
            ),
        )

        if guards[0].patrol.target_index == 0 {
            reached_waypoint = true
            break
        }
    }

    if guards[0].patrol.route.index < len(guards[0].patrol.route.path) {
        next := guards[0].patrol.route.path[guards[0].patrol.route.index]
        fmt.printfln("  next node: %.2f, %.2f", next.x, next.y)
        fmt.printfln("  next node blocked: %v",
            mission.point_collides(&level, next, guards[0].radius),
        )
    }
    testing.expect(t, reached_waypoint)
}
