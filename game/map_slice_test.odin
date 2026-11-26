package game

// The first slice on the gameplay map (sandtable's docs/map_spec.md), through
// game.update with synthetic input: a guard patrols the street, sees over a
// low wall but not someone crouching behind it, a guard on a roof sees over
// it, and the player climbs a ladder onto a roof. Plus a mission that names
// its map file, through mission.load.
//
//   y
//   0  +------------------------------------------------------------+
//      |                          [ building 30..45 x 5..15, 6 m ]  |
//   10 |                    ladder > at x 29.5..30.5, y 10.5        |
//      |                                                            |
//   20 |          |                                                 |
//      |  guard   | low wall x 20..21, y 18..40, 1.2 m              |
//   30 |  5 -> 15 |                                                 |
//   40 +------------------------------------------------------------+ x 60

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../actors"
import "../gamemap"
import "../geom"
import "../mission"

@(private = "file")
rect :: proc(x0, y0, x1, y1: f32) -> [][][2]f32 {
    ring := make([][2]f32, 4, context.temp_allocator)
    ring[0], ring[1], ring[2], ring[3] = {x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}
    rings := make([][][2]f32, 1, context.temp_allocator)
    rings[0] = ring
    return rings
}

// The street as a map, as sandtable's export makes it (features, then edits).
@(private = "file")
street_map :: proc(t: ^testing.T) -> gamemap.Map {
    m := gamemap.make_map({size = {60, 40}, world_scale = 1}, 1, 60, 40)
    for y in 0 ..< m.h {
        for x in 0 ..< m.w do gamemap.set_cell(&m, 0, x, y, 0, .Road)
    }
    append(&m.features, gamemap.Feature{id = "b:37,10", kind = .Building, footprint = rect(30, 5, 45, 15), height = 6})
    append(&m.features, gamemap.Feature{id = "w:20,29", kind = .Wall, footprint = rect(20, 18, 21, 40), height = 1.2})
    problems := gamemap.apply_edits(&m, []gamemap.Edit{
        {id = "e1", kind = .Building, target = "b:37,10", walkable_roof = true},
        {id = "e2", kind = .Link, link = .Ladder, a = {29.5, 10.5, 0}, b = {30.5, 10.5, 6}},
    }, context.temp_allocator)
    for p in problems do testing.expectf(t, false, "%s: %s", p.edit, p.message)
    return m
}

@(private = "file")
street_world :: proc(t: ^testing.T, spawn: geom.Point, guards: []mission.Guard_Def) -> World {
    lvl := mission.Mission{
        player_spawn = spawn,
        guards = guards,
        game_map = street_map(t),
        has_map = true,
    }
    return world_init(lvl)
}

@(private = "file")
run :: proc(w: ^World, input: Input, seconds: f32) {
    DT :: f32(1.0 / 60)
    for _ in 0 ..< int(seconds / DT) do update(w, input, DT)
}

@(private = "file")
dist :: proc(a, b: geom.Point) -> f32 {
    dx, dy := a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
}

@(private = "file")
toward :: proc(from, to: geom.Point) -> geom.Point {
    d := dist(from, to)
    return {(to.x - from.x) / d, (to.y - from.y) / d}
}

@(test)
map_guard_patrols_the_street :: proc(t: ^testing.T) {
    route := []geom.Point{{5.5, 30.5}, {15.5, 30.5}, {15.5, 24.5}}
    w := street_world(t, {55.5, 35.5}, []mission.Guard_Def{{id = "g1", speed = 3, patrol = route}})
    defer world_destroy(&w)

    closest := [3]f32{max(f32), max(f32), max(f32)}
    DT :: f32(1.0 / 60)
    for _ in 0 ..< 60 * 30 {
        update(&w, {}, DT)
        g := w.guards[0]
        for p, i in route do closest[i] = min(closest[i], dist(g.position, p))
        testing.expect(t, g.h == 0, "on the street")
        testing.expect(t, g.position.x < 20, "never through the wall")
    }
    for c, i in closest do testing.expectf(t, c < 0.3, "reached waypoint %d: %.2f m", i, c)
    testing.expect_value(t, w.outcome, mission.Outcome.PLAYING)
}

@(test)
map_guard_sees_over_a_low_wall :: proc(t: ^testing.T) {
    // a guard standing still, looking east at the wall from 8 m
    guard := []mission.Guard_Def{{id = "g1", speed = 0, patrol = []geom.Point{{12.5, 30.5}}}}

    standing := street_world(t, {22.5, 30.5}, guard) // right behind the wall
    defer world_destroy(&standing)
    run(&standing, {}, 0.1)
    testing.expect(t, standing.guards[0].player_visible, "a man standing shows over a 1.2 m wall")

    crouching := street_world(t, {22.5, 30.5}, guard)
    defer world_destroy(&crouching)
    run(&crouching, {sneak = true}, 0.5)
    testing.expect(t, !crouching.guards[0].player_visible, "crouching behind it hides him")
    testing.expect(t, crouching.guards[0].awareness.suspicion == 0, "and nothing builds up")

    // the same without the wall in the way: seen crouching
    open := street_world(t, {17.5, 30.5}, guard)
    defer world_destroy(&open)
    run(&open, {sneak = true}, 0.1)
    testing.expect(t, open.guards[0].player_visible, "crouching in the open is seen")
}

@(test)
map_tower_guard_sees_behind_the_wall :: proc(t: ^testing.T) {
    // a guard on the roof (6 m), at its west edge, looking south-west
    roof_guard := []mission.Guard_Def{{id = "tower", speed = 0, height = 6, patrol = []geom.Point{{30.5, 14.5}}}}
    w := street_world(t, {24.5, 30.5}, roof_guard)
    defer world_destroy(&w)
    testing.expect(t, w.guards[0].h == 6, "the route is on the roof")
    w.guards[0].facing = toward({30.5, 14.5}, {24.5, 30.5})
    run(&w, {sneak = true}, 0.1)
    testing.expect(t, w.guards[0].player_visible, "from the roof, over the wall onto a crouching man")

    ground := []mission.Guard_Def{{id = "g", speed = 0, patrol = []geom.Point{{12.5, 30.5}}}}
    w2 := street_world(t, {24.5, 30.5}, ground)
    defer world_destroy(&w2)
    run(&w2, {sneak = true}, 0.1)
    testing.expect(t, !w2.guards[0].player_visible, "from the street he is hidden")
}

@(test)
map_player_climbs_a_ladder :: proc(t: ^testing.T) {
    w := street_world(t, {24.5, 10.5}, nil)
    defer world_destroy(&w)
    testing.expect(t, w.player.h == 0, "spawned on the street")

    // walk east to the ladder's foot, against the wall
    run(&w, {move = {1, 0}}, 1.5)
    testing.expectf(t, w.player.position.x > 28.5 && w.player.position.x < 30, "at the wall: %v", w.player.position)

    // the wall is a ledge: walking on gets nowhere
    run(&w, {move = {1, 0}}, 0.5)
    testing.expect(t, w.player.h == 0 && w.player.position.x < 30, "6 m is not a step")

    // interact: up the ladder
    update(&w, {interact = true}, 1.0 / 60)
    testing.expect(t, w.player.climb.active, "on the ladder")
    run(&w, {move = {-1, 0}}, 4.5) // input is ignored while climbing
    testing.expect(t, !w.player.climb.active, "off the ladder")
    testing.expectf(t, w.player.h == 6, "on the roof: %.2f m", w.player.h)

    // and walks across the roof, not off it
    run(&w, {move = {1, 0}}, 2)
    testing.expectf(t, w.player.position.x > 33 && w.player.h == 6, "across the roof: %v at %.1f m", w.player.position, w.player.h)
    run(&w, {move = {1, 0}}, 3)
    testing.expectf(t, w.player.position.x < 45, "the roof's edge is a ledge too: %v", w.player.position)

    // back to the ladder's top, and down
    run(&w, {move = {-1, 0}}, 3)
    update(&w, {interact = true}, 1.0 / 60)
    testing.expect(t, w.player.climb.active, "down the ladder")
    run(&w, {}, 4.5)
    testing.expectf(t, w.player.h == 0 && w.player.position.x < 30, "back on the street: %v at %.1f m", w.player.position, w.player.h)

    // far from any ladder, interact does nothing of the sort
    run(&w, {move = {-1, 0}}, 1)
    update(&w, {interact = true}, 1.0 / 60)
    testing.expect(t, !w.player.climb.active, "no ladder here")
}

@(test)
map_guard_climbs_after_the_player :: proc(t: ^testing.T) {
    // an alerted guard follows the player's last known position onto the
    // roof, the only floor there, up the ladder
    guard := []mission.Guard_Def{{id = "g1", speed = 3, patrol = []geom.Point{{25.5, 10.5}}}}
    w := street_world(t, {50.5, 35.5}, guard)
    defer world_destroy(&w)
    g := &w.guards[0]
    g.awareness.state = .ALERTED
    g.awareness.last_known_position = {38.5, 10.5}
    g.awareness.last_known_source = .SIGHT
    run(&w, {}, 12)
    testing.expectf(t, g.h == 6, "the guard is on the roof: %.2f m at %v", g.h, g.position)
}

@(test)
map_mission_from_files :: proc(t: ^testing.T) {
    m := street_map(t)
    defer gamemap.destroy(&m)
    dir := os.get_env("TMPDIR", context.temp_allocator)
    if dir == "" do dir = "/tmp"
    map_path, _ := filepath.join({dir, "slice.map.json"}, context.temp_allocator)
    mission_path, _ := filepath.join({dir, "slice.mission.json"}, context.temp_allocator)
    testing.expect_value(t, gamemap.save(m, map_path), gamemap.Error.None)
    defer os.remove(map_path)
    defer os.remove(gamemap.bin_path(map_path, context.temp_allocator))
    text := `{"id": "slice", "map": "slice.map.json", "playerSpawn": {"x": 24.5, "y": 10.5},
        "guards": [{"id": "tower", "height": 6, "patrol": [{"x": 31.5, "y": 6.5}, {"x": 43.5, "y": 6.5}]}],
        "buildings": [], "walls": [], "cover": []}`
    testing.expect(t, os.write_entire_file(mission_path, transmute([]byte)text) == nil)
    defer os.remove(mission_path)

    lvl, ok := mission.load(mission_path)
    testing.expect(t, ok, "loads")
    if !ok do return
    testing.expect(t, lvl.has_map, "with its map")
    testing.expect_value(t, mission.bounds(&lvl), geom.Bounds{60, 40})
    w := world_init(lvl)
    defer world_destroy(&w)
    testing.expect_value(t, w.guards[0].h, f32(6))

    // the roof guard patrols his roof
    far := f32(0)
    for _ in 0 ..< 60 * 8 {
        update(&w, {}, 1.0 / 60)
        far = max(far, w.guards[0].position.x)
    }
    testing.expect(t, w.guards[0].h == 6, "still on the roof")
    testing.expectf(t, far > 43, "he walks it end to end: %.1f", far)

    // a mission naming a missing map does not load
    bad := strings.concatenate({mission_path, ".bad.json"}, context.temp_allocator)
    _ = os.write_entire_file(bad, transmute([]byte)string(`{"map": "nowhere.map.json"}`))
    defer os.remove(bad)
    _, bad_ok := mission.load(bad)
    testing.expect(t, !bad_ok, "a missing map is an error")
    _ = actors.LINK_REACH
}
