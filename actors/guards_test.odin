
package actors

import "core:testing"
import "core:fmt"

import "../mission"
import "../nav"
import "../geom"

// Central test builder for Guard values. Keep all default field values
// here so future Guard struct changes only need updating in one place.
test_guard :: proc(
    position: geom.Point = {0, 0},
    facing: geom.Point = {1, 0},
    awareness: Guard_Awareness = {},
    speed: f32 = 2,
    radius: f32 = GUARD_RADIUS,
    patrol: []geom.Point = nil,
    target_index: int = 0,
    pause_duration: f32 = GUARD_DEFAULT_PAUSE,
    hearing_threshold: f32 = GUARD_DEFAULT_HEARING_THRESHOLD,
    player_visible: bool = false,
    searching: bool = false,
    search_pause_remaining: f32 = 0,
) -> Guard {
    a := awareness
    if a == {} {
        a = guard_awareness_init()
    }
    behaviour := Guard_Behaviour.PATROL
    if a.state == .ALERTED ||
       (a.state == .SUSPICIOUS && a.last_known_source == .SOUND) {
        behaviour = .INVESTIGATE
    } else if a.state == .RECOVERING {
        behaviour = .RECOVER
    }
    if searching {
        behaviour = .SEARCH
    }
    return Guard{
        position = position,
        facing = facing,
        awareness = a,
        behaviour = behaviour,
        speed = speed,
        radius = radius,
        hearing_threshold = hearing_threshold,
        player_visible = player_visible,
        patrol = Guard_Patrol{
            points = patrol,
            target_index = target_index,
            pause_duration = pause_duration,
        },
        search = Guard_Search{
            active = searching,
            pause_remaining = search_pause_remaining,
        },
    }
}


@(test)
test_guard_hears_footstep_and_becomes_suspicious :: proc(t: ^testing.T) {
    guard := test_guard(position = {2, 0})
    footstep := Noise_Event{
        position = {0, 0},
        radius = 10,
        intensity = 1,
    }

    guard_hear_noise(&guard, footstep)

    testing.expect(t, guard.awareness.state == .SUSPICIOUS)
    testing.expect(t, guard.awareness.last_known_source == .SOUND)
    testing.expect(t, guard.awareness.last_known_position.x == 0)
    testing.expect(t, guard.awareness.last_known_position.y == 0)
}

@(test)
test_guard_does_not_hear_distant_footstep :: proc(t: ^testing.T) {
    guard := test_guard(position = {20, 0})
    footstep := Noise_Event{
        position = {0, 0},
        radius = 10,
        intensity = 1,
    }

    guard_hear_noise(&guard, footstep)

    testing.expect(t, guard.awareness.state == .UNAWARE)
    testing.expect(t, guard.awareness.last_known_source == .NONE)
}

@(test)
test_guard_does_not_let_noise_override_visual_position :: proc(t: ^testing.T) {
    guard := test_guard(position = {2, 0}, awareness = Guard_Awareness{
            state = .SUSPICIOUS,
            last_known_position = {4, 5},
            last_known_source = .SIGHT,
        })
    footstep := Noise_Event{
        position = {0, 0},
        radius = 10,
        intensity = 1,
    }

    guard_hear_noise(&guard, footstep)

    testing.expect(t, guard.awareness.last_known_source == .SIGHT)
    testing.expect(t, guard.awareness.last_known_position.x == 4)
    testing.expect(t, guard.awareness.last_known_position.y == 5)
    testing.expect(t, guard.facing.x == 1)
    testing.expect(t, guard.facing.y == 0)
}


@(test)
test_guard_turns_toward_heard_noise :: proc(t: ^testing.T) {
    guard := test_guard(position = {2, 2})

    noise := Noise_Event{
        position = {2, 8},
        radius = 10,
        intensity = 1,
    }

    guard_hear_noise(&guard, noise)

    testing.expect(t, guard.awareness.state == .SUSPICIOUS)
    testing.expect(t, guard.awareness.last_known_source == .SOUND)
    testing.expect(t, guard.facing.x == 0)
    testing.expect(t, guard.facing.y == 1)
}
