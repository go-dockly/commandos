package actors

import "core:testing"

import "../mission"
import "../geom"

@(test)
test_guard_recovery_routes_around_building :: proc(t: ^testing.T) {
    level := mission.Mission{
        buildings = {
            geom.Rect{
                x = 12,
                y = 10,
                w = 5,
                h = 5,
            },
        },
    }
    defer mission.destroy(&level)

    guard := test_guard(
        position = {10.5, 12.5},
        awareness = Guard_Awareness{
            state = .RECOVERING,
            suspicion = 1,
            last_known_source = .SIGHT,
        },
        patrol = []geom.Point{
            {10.5, 12.5},
            {18.5, 12.5},
        },
        target_index = 1,
        speed = 3.5,
        pause_duration = 1,
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

        if guards[0].awareness.state == .UNAWARE {
            reached_waypoint = true
            break
        }
    }

    testing.expect(t, reached_waypoint)
    testing.expect(t, guards[0].position.x == 18.5)
    testing.expect(t, guards[0].position.y == 12.5)
    testing.expect(t, guards[0].awareness.suspicion == 0)
    testing.expect(t, guards[0].awareness.last_known_source == .NONE)
}


@(test)
test_guard_recovery_does_not_reset_when_path_unreachable :: proc(t: ^testing.T) {
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

    guard := test_guard(
        position = {10.5, 10.5},
        awareness = Guard_Awareness{
            state = .RECOVERING,
            suspicion = 1,
            last_known_source = .SIGHT,
        },
        patrol = []geom.Point{
            {10.5, 10.5},
            {30.5, 10.5},
        },
        target_index = 1,
        speed = 3.5,
        pause_duration = 1,
    )

    guards := []Guard{guard}
    defer delete(guards[0].investigation.path)
    defer delete(guards[0].patrol.route.path)

    for _ in 0..<100 {
        guard_update(guards, &level, 0.1)
    }

    testing.expect(t, guards[0].awareness.state == .RECOVERING)
    testing.expect(t, guards[0].awareness.suspicion == 1)
    testing.expect(t, guards[0].awareness.last_known_source == .SIGHT)
    testing.expect(t, guards[0].position.x < 20)
}
