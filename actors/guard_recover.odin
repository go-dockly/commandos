package actors

import "../mission"
import "../geom"

// ---------------------------------------------------------------------------
// Recovery: return to nearest patrol waypoint after alert ends
// ---------------------------------------------------------------------------

guard_recovery_begin :: proc(guard: ^Guard) {
    path_follower_clear(&guard.investigation)

    if len(guard.patrol.points) == 0 {
        guard.awareness.state = .UNAWARE
        guard.awareness.suspicion = 0
        guard.awareness.last_known_source = .NONE
        guard.search.complete = false
        guard.behaviour = .PATROL
        return
    }

    dx := guard.patrol.points[0].x - guard.position.x
    dy := guard.patrol.points[0].y - guard.position.y
    nearest_distance := dx*dx + dy*dy
    nearest_index := 0

    for i in 1..<len(guard.patrol.points) {
        dx = guard.patrol.points[i].x - guard.position.x
        dy = guard.patrol.points[i].y - guard.position.y
        distance := dx*dx + dy*dy
        if distance < nearest_distance {
            nearest_distance = distance
            nearest_index = i
        }
    }

    guard.patrol.target_index = nearest_index
    path_follower_clear(&guard.patrol.route)
    guard.search.complete = false
    guard.behaviour = .RECOVER
}

guard_recover_update :: proc(
    guard: ^Guard,
    lvl: ^mission.Mission,
    dt: f32,
) {
    if dt <= 0 || guard.speed <= 0 {
        return
    }

    if len(guard.patrol.points) == 0 {
        guard.awareness.state = .UNAWARE
        guard.awareness.suspicion = 0
        guard.awareness.last_known_source = .NONE
        path_follower_clear(&guard.patrol.route)
        guard.behaviour = .PATROL
        return
    }

    guard_patrol_path_prepare(guard, lvl)

    if !guard.patrol.route.found {
        return
    }

    remaining_time := dt

    for remaining_time > 0 {
        if guard.patrol.route.index >= len(guard.patrol.route.path) {
            // Snap onto the patrol point (preserves previous behaviour).
            target := guard.patrol.points[guard.patrol.target_index]
            guard.position = target
            guard.patrol.target_index =
                (guard.patrol.target_index + 1) % len(guard.patrol.points)
            guard.patrol.pause_remaining = guard.patrol.pause_duration

            guard.awareness.state = .UNAWARE
            guard.awareness.suspicion = 0
            guard.awareness.last_known_source = .NONE

            path_follower_clear(&guard.patrol.route)
            guard.behaviour = .PATROL
            return
        }

        left, _ := follow_path(
            guard,
            &guard.patrol.route,
            lvl,
            remaining_time,
        )
        remaining_time = left

        if !guard.patrol.route.ready {
            return
        }
    }
}
