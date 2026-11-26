
package actors

import "core:testing"
import "core:math"

@(test)
test_noise_is_strongest_at_source :: proc(t: ^testing.T) {
    noise := Noise_Event{
        position = {10, 20},
        radius = 10,
        intensity = 0.8,
    }

    intensity := noise_intensity_at(noise, {10, 20})
    testing.expect(t, math.abs(intensity - 0.8) < 0.0001)
}

@(test)
test_noise_fades_linearly_with_distance :: proc(t: ^testing.T) {
    noise := Noise_Event{
        position = {0, 0},
        radius = 10,
        intensity = 1,
    }

    intensity := noise_intensity_at(noise, {5, 0})
    testing.expect(t, math.abs(intensity - 0.5) < 0.0001)
}

@(test)
test_noise_has_no_intensity_at_or_beyond_radius :: proc(t: ^testing.T) {
    noise := Noise_Event{
        position = {0, 0},
        radius = 10,
        intensity = 1,
    }

    testing.expect(t, noise_intensity_at(noise, {10, 0}) == 0)
    testing.expect(t, noise_intensity_at(noise, {12, 0}) == 0)
}

@(test)
test_guard_hears_noise_above_threshold :: proc(t: ^testing.T) {
    noise := Noise_Event{
        position = {0, 0},
        radius = 10,
        intensity = 1,
    }

    testing.expect(t, guard_can_hear({2, 0}, noise, 0.5))
}

@(test)
test_guard_does_not_hear_noise_below_threshold :: proc(t: ^testing.T) {
    noise := Noise_Event{
        position = {0, 0},
        radius = 10,
        intensity = 1,
    }

    testing.expect(t, !guard_can_hear({6, 0}, noise, 0.5))
}

@(test)
test_guard_does_not_hear_invalid_noise :: proc(t: ^testing.T) {
    zero_radius := Noise_Event{
        position = {0, 0},
        radius = 0,
        intensity = 1,
    }
    zero_intensity := Noise_Event{
        position = {0, 0},
        radius = 10,
        intensity = 0,
    }

    testing.expect(t, !guard_can_hear({0, 0}, zero_radius, 0.1))
    testing.expect(t, !guard_can_hear({0, 0}, zero_intensity, 0.1))
    testing.expect(t, !guard_can_hear({0, 0}, zero_intensity, 0))
}
