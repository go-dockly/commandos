
package actors

import "core:math"

import "../geom"

Noise_Event :: struct {
    position: geom.Point,
    radius: f32,
    intensity: f32,
}

noise_intensity_at :: proc(noise: Noise_Event, listener: geom.Point) -> f32 {
    if noise.radius <= 0 || noise.intensity <= 0 {
        return 0
    }

    dx := listener.x - noise.position.x
    dy := listener.y - noise.position.y
    distance := math.sqrt(dx*dx + dy*dy)

    if distance >= noise.radius {
        return 0
    }

    attenuation := 1 - distance / noise.radius
    return noise.intensity * attenuation
}

guard_can_hear :: proc(
    guard_position: geom.Point,
    noise: Noise_Event,
    hearing_threshold: f32,
) -> bool {
    if hearing_threshold <= 0 {
        return false
    }

    return noise_intensity_at(noise, guard_position) >= hearing_threshold
}
