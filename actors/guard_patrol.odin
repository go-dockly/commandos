package actors

import "../mission"
import "../nav"
import "../geom"

// ---------------------------------------------------------------------------
// Patrol path preparation and update
// ---------------------------------------------------------------------------

guard_patrol_path_prepare :: proc(
    guard: ^Guard,
    level: ^mission.Mission,
) {
    if guard.patrol.route.ready &&
       guard.patrol.route.goal_x == guard.patrol.target_index {
        // We reuse goal_x to store the target_index we planned for.
        return
    }

    path_follower_clear(&guard.patrol.route)

    if guard.patrol.target_index < 0 ||
       guard.patrol.target_index >= len(guard.patrol.points) {
        return
    }

    path := nav.find_path(
        level,
        guard.position,
        guard.patrol.points[guard.patrol.target_index],
        guard.radius,
    )

    guard.patrol.route.path = path.points
    guard.patrol.route.index = 0
    guard.patrol.route.goal_x = guard.patrol.target_index
    guard.patrol.route.ready = true
    guard.patrol.route.found = path.found
}

guard_arrive :: proc(guard: ^Guard) {
    if len(guard.patrol.points) == 0 {
        return
    }
    path_follower_clear(&guard.patrol.route)
    guard.patrol.target_index =
        (guard.patrol.target_index + 1) % len(guard.patrol.points)
    guard.patrol.pause_remaining = guard.patrol.pause_duration
}

guard_patrol_update :: proc(
    guard: ^Guard,
    lvl: ^mission.Mission,
    dt: f32,
) {
    if dt <= 0 || guard.speed <= 0 {
        return
    }

    remaining_time := dt

    for remaining_time > 0 {
        if guard.patrol.pause_remaining > 0 {
            consumed := min(remaining_time, guard.patrol.pause_remaining)
            guard.patrol.pause_remaining -= consumed
            remaining_time -= consumed
            if remaining_time <= 0 {
                break
            }
        }

        guard_patrol_path_prepare(guard, lvl)

        if !guard.patrol.route.found {
            return
        }

        left, arrived := follow_path(
            guard,
            &guard.patrol.route,
            lvl,
            remaining_time,
        )
        remaining_time = left

        if arrived {
            guard_arrive(guard)
            // continue the loop so any leftover time is spent on the
            // next leg / pause
        } else if !guard.patrol.route.ready {
            // path was cleared by a collision
            return
        }
    }
}
