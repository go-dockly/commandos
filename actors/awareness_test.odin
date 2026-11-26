
package actors

import "core:testing"

@(test)
test_awareness_starts_unaware :: proc(t: ^testing.T) {
    awareness := guard_awareness_init()

    testing.expect(t, awareness.state == .UNAWARE)
    testing.expect(t, awareness.suspicion == 0)
}

@(test)
test_awareness_builds_suspicion :: proc(t: ^testing.T) {
    awareness := guard_awareness_init()

    guard_awareness_update(
        &awareness,
        true,
        {10, 20},
        0.5,
        AWARENESS_DEFAULT,
    )

    testing.expect(t, awareness.state == .SUSPICIOUS)
    testing.expect(t, awareness.suspicion > 0)
    testing.expect(t, awareness.suspicion < 1)
    testing.expect(t, awareness.last_known_position.x == 10)
    testing.expect(t, awareness.last_known_position.y == 20)
    testing.expect(t, awareness.last_known_source == .SIGHT)
}

@(test)
test_awareness_becomes_alerted :: proc(t: ^testing.T) {
    awareness := guard_awareness_init()

    guard_awareness_update(
        &awareness,
        true,
        {15, 25},
        1.25,
        AWARENESS_DEFAULT,
    )

    testing.expect(t, awareness.state == .ALERTED)
    testing.expect(t, awareness.suspicion == 1)
}

@(test)
test_awareness_decays_to_unaware :: proc(t: ^testing.T) {
    awareness := guard_awareness_init()

    guard_awareness_update(
        &awareness,
        true,
        {10, 20},
        0.5,
        AWARENESS_DEFAULT,
    )

    guard_awareness_update(
        &awareness,
        false,
        {},
        1.0,
        AWARENESS_DEFAULT,
    )

    testing.expect(t, awareness.state == .UNAWARE)
    testing.expect(t, awareness.suspicion == 0)
}

@(test)
test_awareness_alert_persists :: proc(t: ^testing.T) {
    awareness := guard_awareness_init()

    guard_awareness_update(
        &awareness,
        true,
        {15, 25},
        1.25,
        AWARENESS_DEFAULT,
    )

    guard_awareness_update(
        &awareness,
        false,
        {0, 0},
        10.0,
        AWARENESS_DEFAULT,
    )

    testing.expect(t, awareness.state == .ALERTED)
    testing.expect(t, awareness.suspicion == 1)
    testing.expect(t, awareness.last_known_position.x == 15)
    testing.expect(t, awareness.last_known_position.y == 25)
    testing.expect(t, awareness.last_known_source == .SIGHT)
}

@(test)
test_hearing_makes_guard_suspicious_without_alerting :: proc(t: ^testing.T) {
    awareness := guard_awareness_init()

    guard_awareness_hear_noise(&awareness, {30, 40})

    testing.expect(t, awareness.state == .SUSPICIOUS)
    testing.expect(t, awareness.suspicion == 0)
    testing.expect(t, awareness.last_known_position.x == 30)
    testing.expect(t, awareness.last_known_position.y == 40)
    testing.expect(t, awareness.last_known_source == .SOUND)
}

@(test)
test_visual_detection_overrides_heard_noise :: proc(t: ^testing.T) {
    awareness := guard_awareness_init()

    guard_awareness_hear_noise(&awareness, {30, 40})
    guard_awareness_update(
        &awareness,
        true,
        {12, 14},
        0.25,
        AWARENESS_DEFAULT,
    )

    testing.expect(t, awareness.state == .SUSPICIOUS)
    testing.expect(t, awareness.last_known_position.x == 12)
    testing.expect(t, awareness.last_known_position.y == 14)
    testing.expect(t, awareness.last_known_source == .SIGHT)
}

@(test)
test_sound_suspicion_does_not_decay_before_investigation :: proc(t: ^testing.T) {
    awareness := guard_awareness_init()

    guard_awareness_hear_noise(&awareness, {30, 40})
    guard_awareness_update(
        &awareness,
        false,
        {},
        10.0,
        AWARENESS_DEFAULT,
    )

    testing.expect(t, awareness.state == .SUSPICIOUS)
    testing.expect(t, awareness.last_known_source == .SOUND)
    testing.expect(t, awareness.last_known_position.x == 30)
    testing.expect(t, awareness.last_known_position.y == 40)
}
