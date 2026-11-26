
package actors

import "../geom"

Guard_Awareness_State :: enum u8 {
    UNAWARE,
    SUSPICIOUS,
    ALERTED,
    RECOVERING,
}

Last_Known_Source :: enum u8 {
    NONE,
    SIGHT,
    SOUND,
}

Guard_Awareness :: struct {
    state: Guard_Awareness_State,
    suspicion: f32,
    last_known_position: geom.Point,
    last_known_source: Last_Known_Source,
}

Awareness_Config :: struct {
    build_duration: f32,
    decay_duration: f32,
}

AWARENESS_DEFAULT :: Awareness_Config{
    build_duration = 1.25,
    decay_duration = 2.0,
}

guard_awareness_init :: proc() -> Guard_Awareness {
    return Guard_Awareness{
        state = .UNAWARE,
        suspicion = 0,
    }
}

// A heard noise creates suspicion, but never alerts the guard.
// Call this before guard_awareness_update so visual detection can
// override the sound-derived position during the same frame.
guard_awareness_hear_noise :: proc(
    awareness: ^Guard_Awareness,
    noise_position: geom.Point,
) {
    if awareness.state == .ALERTED || awareness.last_known_source == .SIGHT {
        return
    }

    awareness.state = .SUSPICIOUS
    awareness.suspicion = 0
    awareness.last_known_position = noise_position
    awareness.last_known_source = .SOUND
}

// Updates one guard's awareness state.
//
// Suspicion builds while the player is visible and decays while hidden.
// ALERTED is persistent in this iteration.
guard_awareness_update :: proc(
    awareness: ^Guard_Awareness,
    sees_player: bool,
    player_position: geom.Point,
    dt: f32,
    config: Awareness_Config,
) {
    if dt <= 0 {
        return
    }

    // Alerted guards retain their alert state, but continue updating
    // the target whenever they see the player again.
    if awareness.state == .ALERTED {
        if sees_player {
            awareness.last_known_position = player_position
            awareness.last_known_source = .SIGHT
        }
        return
    }

    if sees_player {
        awareness.last_known_position = player_position
        awareness.last_known_source = .SIGHT

        if config.build_duration <= 0 {
            awareness.suspicion = 1
        } else {
            awareness.suspicion += dt / config.build_duration
        }

        if awareness.suspicion >= 1 {
            awareness.suspicion = 1
            awareness.state = .ALERTED
        } else {
            awareness.state = .SUSPICIOUS
        }
    } else {
        // A noise investigation remains active until the guard reaches
        // the reported location and completes its search.
        if awareness.last_known_source == .SOUND {
            awareness.state = .SUSPICIOUS
            return
        }

        if config.decay_duration <= 0 {
            awareness.suspicion = 0
        } else {
            awareness.suspicion -= dt / config.decay_duration
        }

        if awareness.suspicion <= 0 {
            awareness.suspicion = 0
            awareness.state = .UNAWARE
            awareness.last_known_source = .NONE
        } else {
            awareness.state = .SUSPICIOUS
        }
    }
}
