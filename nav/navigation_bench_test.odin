
package nav

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"
import "core:time"
import "../mission"
import "../geom"

NAV_BENCH :: #config(NAV_BENCH, false)

// Matches the player radius in actors.player_init. nav cannot import actors
// (actors imports nav), so the value is repeated here.
BENCH_AGENT_RADIUS :: f32(0.8)

BENCH_BURST_FRAMES :: 20
BENCH_FRAME_BUDGET_MS :: 16.6

bench_path :: proc(
    t: ^testing.T,
    label: string,
    level: ^mission.Mission,
    start, goal: geom.Point,
    radius: f32,
    iterations: int,
) {
    warm := find_path(level, start, goal, radius)
    found := warm.found
    delete(warm.points)

    total_us: f64
    min_us: f64 = 1e18
    max_us: f64

    for _ in 0..<iterations {
        began := time.tick_now()
        path := find_path(level, start, goal, radius)
        us := time.duration_microseconds(time.tick_since(began))

        total_us += us
        min_us = min(min_us, us)
        max_us = max(max_us, us)
        delete(path.points)
    }

    fmt.printf(
        "nav bench | %s | found=%v | avg %.1f us | min %.1f us | max %.1f us | %d runs\n",
        label, found, total_us / f64(iterations), min_us, max_us, iterations,
    )
}

bench_burst :: proc(
    t: ^testing.T,
    label: string,
    level: ^mission.Mission,
    start, goal: geom.Point,
    radius: f32,
    paths_per_frame: int,
) {
    total_ms: f64
    worst_ms: f64

    for _ in 0..<BENCH_BURST_FRAMES {
        began := time.tick_now()

        for _ in 0..<paths_per_frame {
            path := find_path(level, start, goal, radius)
            delete(path.points)
        }

        ms := time.duration_milliseconds(time.tick_since(began))
        total_ms += ms
        worst_ms = max(worst_ms, ms)
    }

    average_ms := total_ms / f64(BENCH_BURST_FRAMES)
    budget_pct := average_ms / BENCH_FRAME_BUDGET_MS * 100.0

    fmt.printf(
        "nav bench | %s | %d paths/frame | avg %.2f ms | worst %.2f ms | %.1f%% of 16.6 ms budget\n",
        label, paths_per_frame, average_ms, worst_ms, budget_pct,
    )
}

bench_nearest_open_cell :: proc(
    level: ^mission.Mission,
    target: geom.Point,
    radius: f32,
) -> (geom.Point, bool) {
    grid_w, grid_h := nav_grid_dims(level)
    best := target
    best_dist_sq: f32 = 1e30
    found := false

    for y in 0..<grid_h {
        for x in 0..<grid_w {
            candidate := nav_cell_center(x, y)

            if mission.point_collides(level, candidate, radius) {
                continue
            }

            dx := candidate.x - target.x
            dy := candidate.y - target.y
            dist_sq := dx*dx + dy*dy

            if dist_sq < best_dist_sq {
                best_dist_sq = dist_sq
                best = candidate
                found = true
            }
        }
    }

    return best, found
}

@(test)
bench_navigation :: proc(t: ^testing.T) {
    if !NAV_BENCH {
        return
    }

    agent_radius := BENCH_AGENT_RADIUS

    outer := context.allocator
    backing := make([]byte, 8 * 1024 * 1024, outer)
    defer delete(backing, outer)

    arena: mem.Arena
    mem.arena_init(&arena, backing)
    context.allocator = mem.arena_allocator(&arena)

    level, loaded := mission.load("mission/eagle/mission.json")
    context.allocator = outer

    testing.expect(
        t,
        loaded,
        "could not load mission.json; run the tests from the repository root",
    )
    if !loaded {
        return
    }

    grid_w, grid_h := nav_grid_dims(&level)
    fmt.printf(
        "nav bench | mission.json | grid %dx%d = %d cells | %d solid rects | %d solid circles\n",
        grid_w, grid_h, grid_w * grid_h,
        len(level.geometry.solids), len(level.geometry.circles),
    )

    extraction_center := geom.Point{
        level.extraction.x,
        level.extraction.y,
    }

    extraction_target, target_valid := bench_nearest_open_cell(
        &level,
        extraction_center,
        agent_radius,
    )

    testing.expect(t, target_valid, "no open cell found near extraction")
    if !target_valid {
        return
    }

    target_dx := extraction_target.x - extraction_center.x
    target_dy := extraction_target.y - extraction_center.y
    target_distance := math.sqrt(target_dx*target_dx + target_dy*target_dy)

    fmt.printf(
        "nav bench | extraction centre=(%.1f, %.1f) | resolved target=(%.1f, %.1f) | offset=%.2f\n",
        extraction_center.x, extraction_center.y,
        extraction_target.x, extraction_target.y, target_distance,
    )

    bench_path(
        t, "mission.json spawn -> extraction (long route)",
        &level, level.player_spawn, extraction_target, agent_radius, 20,
    )

    for guard_def in level.guards {
        if len(guard_def.patrol) >= 2 {
            bench_path(
                t, "mission.json first guard patrol leg (short route)",
                &level, guard_def.patrol[0], guard_def.patrol[1], agent_radius, 50,
            )
            break
        }
    }

    // Baseline and scaling tests: 8, 32 and 64 simultaneous replans.
    bench_burst(
        t, "mission.json baseline",
        &level, level.player_spawn, extraction_target, agent_radius, 8,
    )
    bench_burst(
        t, "mission.json medium stress",
        &level, level.player_spawn, extraction_target, agent_radius, 32,
    )
    bench_burst(
        t, "mission.json high stress",
        &level, level.player_spawn, extraction_target, agent_radius, 64,
    )

    {
        empty := mission.Mission{}
        defer geom.destroy(&empty.geometry)

        bench_path(
            t, "empty map corner -> corner",
            &empty, {0.5, 0.5}, {99.5, 99.5}, agent_radius, 1,
        )
    }

    {
        sealed := mission.Mission{
            walls = {
                geom.Wall{x = 85, y = 85, w = 10, h = 1},
                geom.Wall{x = 85, y = 94, w = 10, h = 1},
                geom.Wall{x = 85, y = 85, w = 1, h = 10},
                geom.Wall{x = 94, y = 85, w = 1, h = 10},
            },
        }
        defer geom.destroy(&sealed.geometry)

        bench_path(
            t, "sealed goal (unreachable, full-grid expansion)",
            &sealed, {5.5, 5.5}, {90.5, 90.5}, agent_radius, 10,
        )
    }
}
