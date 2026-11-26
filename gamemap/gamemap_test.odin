package gamemap

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

// A flat street map, w x h metres at 1 m cells, ground everywhere at h = 0.
@(private = "file")
street :: proc(w, h: int, cell := f32(1)) -> Map {
    m := make_map(Frame{size = {f32(w), f32(h)}, world_scale = 1}, cell, int(f32(w) / cell), int(f32(h) / cell))
    for y in 0 ..< m.h {
        for x in 0 ..< m.w do set_cell(&m, 0, x, y, 0, .Road)
    }
    reindex(&m)
    return m
}

@(private = "file")
rect :: proc(x0, y0, x1, y1: f32) -> [][2]f32 {
    r := make([][2]f32, 4, context.temp_allocator)
    r[0], r[1], r[2], r[3] = {x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}
    return r
}

@(private = "file")
rings :: proc(r: [][2]f32) -> [][][2]f32 {
    out := make([][][2]f32, 1, context.temp_allocator)
    out[0] = r
    return out
}

@(private = "file")
node :: proc(m: ^Map, x, y: f32, h := f32(0)) -> Node {
    n, ok := node_at(m, {x, y, h})
    assert(ok, fmt.tprintf("no floor at %v, %v, %v", x, y, h))
    return n
}

@(private = "file")
WALKER :: Agent{radius = 0.4}

@(private = "file")
apply :: proc(t: ^testing.T, m: ^Map, edits: []Edit) {
    problems := apply_edits(m, edits, context.temp_allocator)
    for p in problems do testing.expectf(t, false, "edit %s: %s", p.edit, p.message)
}

// ---------------------------------------------------------------------------

@(test)
frame_round_trip :: proc(t: ^testing.T) {
    f := Frame{origin = {5, -3}, yaw = 17, world_scale = 0.005, ground = 0.01}
    w := [3]f32{5.2, 0.03, -2.7}
    p := world_to_map(f, w)
    back := map_to_world(f, p)
    for k in 0 ..< 3 do testing.expectf(t, abs(back[k] - w[k]) < 1e-5, "axis %d: %v -> %v -> %v", k, w, p, back)
    testing.expect(t, abs(p.z - 4) < 1e-3, "heights in metres from the ground reference")

    // yaw 90: world +z is map -x... map +x points along world +z
    q := world_to_map(Frame{yaw = 90, world_scale = 1}, {0, 0, 2})
    testing.expectf(t, abs(q.x - 2) < 1e-5 && abs(q.y) < 1e-5, "yaw 90: %v", q)
}

@(test)
walk_around_a_wall :: proc(t: ^testing.T) {
    m := street(20, 20)
    defer destroy(&m)
    m.features = make([dynamic]Feature, m.allocator)
    append(&m.features, Feature{id = "wall", kind = .Wall, footprint = rings(rect(10, 0, 11, 15)), height = 2})
    apply(t, &m, nil)

    p := find_path(&m, node(&m, 5.5, 5.5), node(&m, 15.5, 5.5), WALKER, context.temp_allocator)
    testing.expect(t, p.found, "a way round the wall")
    for n in p.nodes do testing.expectf(t, !(n.x == 10 && n.y < 15), "through the wall at %v", n)
    // down to y 15, across, back up: well over the 10 m straight line
    testing.expectf(t, p.cost * DEFAULT_SPEED > 18, "detour cost %.1f s", p.cost)

    // closed in completely: no way
    m2 := street(20, 20)
    defer destroy(&m2)
    append(&m2.features, Feature{id = "box", kind = .Wall, footprint = rings(rect(3, 3, 8, 8)), height = 2})
    apply(t, &m2, []Edit{{id = "hole", kind = .Block, region = rect(4, 4, 7, 7)}})
    // the inside of the box: unblock one cell inside, walled all round
    m2.layers[0].height[5 * m2.w + 5] = 0
    reindex(&m2)
    q := find_path(&m2, node(&m2, 5.5, 5.5), node(&m2, 15.5, 15.5), WALKER, context.temp_allocator)
    testing.expect(t, !q.found, "walled in")
}

@(test)
steps_and_ledges :: proc(t: ^testing.T) {
    m := street(10, 3)
    defer destroy(&m)
    // a staircase of 0.3 m steps up to x = 5, then a 0.6 m ledge
    for y in 0 ..< 3 {
        for x in 1 ..< 5 do set_cell(&m, 0, x, y, 0.3 * f32(x))
        for x in 5 ..< 10 do set_cell(&m, 0, x, y, 1.8)
    }
    reindex(&m)
    m.stamped = true
    up := find_path(&m, node(&m, 0.5, 1.5), node(&m, 4.5, 1.5, 1.2), WALKER, context.temp_allocator)
    testing.expect(t, up.found, "0.3 m steps are walked")
    ledge := find_path(&m, node(&m, 0.5, 1.5), node(&m, 7.5, 1.5, 1.8), WALKER, context.temp_allocator)
    testing.expect(t, !ledge.found, "a 0.6 m ledge needs a link")
}

@(test)
ladder_onto_a_roof :: proc(t: ^testing.T) {
    build :: proc(t: ^testing.T, ladder: bool) -> Map {
        m := street(30, 20)
        append(&m.features, Feature{id = "b1", kind = .Building, footprint = rings(rect(10, 5, 20, 15)), height = 6})
        edits := make([dynamic]Edit, context.temp_allocator)
        append(&edits, Edit{id = "e1", kind = .Building, target = "b1", walkable_roof = true})
        if ladder do append(&edits, Edit{id = "e2", kind = .Link, link = .Ladder, a = {9.5, 10.5, 0}, b = {10.5, 10.5, 6}})
        apply(t, &m, edits[:])
        return m
    }

    m := build(t, true)
    defer destroy(&m)
    roof, has := layer_index(&m, "roof/b1")
    testing.expect(t, has, "the walkable roof is a layer")
    on_roof := node(&m, 15.5, 10.5, 6)
    testing.expect_value(t, int(on_roof.layer), roof)
    rh, _ := height(&m, on_roof)
    testing.expect(t, abs(rh - 6) < 0.01, "roof at 6 m")
    testing.expect(t, !walkable(&m, Node{0, 15, 10}), "no ground inside the building")

    p := find_path(&m, node(&m, 2.5, 10.5), on_roof, WALKER, context.temp_allocator)
    testing.expect(t, p.found, "up the ladder")
    used := false
    for l in p.links do if l >= 0 && m.links[l].kind == .Ladder do used = true
    testing.expect(t, used, "the path takes the ladder")
    // and back down
    down := find_path(&m, on_roof, node(&m, 2.5, 10.5), WALKER, context.temp_allocator)
    testing.expect(t, down.found, "ladders go both ways")

    no := build(t, false)
    defer destroy(&no)
    q := find_path(&no, node(&no, 2.5, 10.5), node(&no, 15.5, 10.5, 6), WALKER, context.temp_allocator)
    testing.expect(t, !q.found, "no ladder, no roof")
}

@(test)
links_and_abilities :: proc(t: ^testing.T) {
    m := street(30, 20)
    defer destroy(&m)
    append(&m.features, Feature{id = "b1", kind = .Building, footprint = rings(rect(10, 5, 20, 15)), height = 2.5})
    apply(t, &m, []Edit{
        {id = "roof", kind = .Building, target = "b1", walkable_roof = true},
        {id = "drop", kind = .Link, link = .Drop, a = {19.5, 10.5, 2.5}, b = {20.5, 10.5, 0}},
        {id = "pipe", kind = .Link, link = .Climb, a = {9.5, 10.5, 0}, b = {10.5, 10.5, 2.5}},
    })
    street_a := node(&m, 2.5, 10.5)
    roof := node(&m, 15.5, 10.5, 2.5)

    testing.expect(t, !find_path(&m, street_a, roof, WALKER, context.temp_allocator).found, "only a climber gets up")
    climber := WALKER
    climber.abilities = {.Climb}
    testing.expect(t, find_path(&m, street_a, roof, climber, context.temp_allocator).found, "the climber climbs")
    testing.expect(t, find_path(&m, roof, node(&m, 25.5, 10.5), WALKER, context.temp_allocator).found, "anyone drops down")

    // a drop is one way: from the street side below, nobody walks up it
    m.links[0].kind = .Drop
    m.links[1].kind = .Stairs
    m.links[1].ability = .Lockpick
    testing.expect(t, !find_path(&m, street_a, roof, climber, context.temp_allocator).found, "a link's own ability")

    // locked doors
    m.links[1] = Link{kind = .Door, a = m.links[1].a, b = m.links[1].b, door = .Locked}
    testing.expect(t, !find_path(&m, street_a, roof, WALKER, context.temp_allocator).found, "locked")
    picker := WALKER
    picker.abilities = {.Lockpick}
    testing.expect(t, find_path(&m, street_a, roof, picker, context.temp_allocator).found, "picked")
    m.links[1].door = .Closed
    testing.expect(t, find_path(&m, street_a, roof, WALKER, context.temp_allocator).found, "closed doors open")

    // a drop deeper than 3 m is refused
    m2 := street(30, 20)
    defer destroy(&m2)
    append(&m2.features, Feature{id = "b1", kind = .Building, footprint = rings(rect(10, 5, 20, 15)), height = 8})
    problems := apply_edits(&m2, []Edit{
        {id = "roof", kind = .Building, target = "b1", walkable_roof = true},
        {id = "jump", kind = .Link, link = .Drop, a = {19.5, 10.5, 8}, b = {20.5, 10.5, 0}},
    }, context.temp_allocator)
    testing.expect_value(t, len(problems), 1)
    if len(problems) == 1 do testing.expect_value(t, problems[0].edit, "jump")

    // a ladder whose foot is inside the building (only the roof there) is
    // refused, not turned into a roof-to-roof link
    m3 := street(30, 20)
    defer destroy(&m3)
    append(&m3.features, Feature{id = "b1", kind = .Building, footprint = rings(rect(10, 5, 20, 15)), height = 6})
    bad := apply_edits(&m3, []Edit{
        {id = "roof", kind = .Building, target = "b1", walkable_roof = true},
        {id = "ladder", kind = .Link, link = .Ladder, a = {10.5, 10.5, 0}, b = {11.5, 10.5, 6}},
    }, context.temp_allocator)
    testing.expect_value(t, len(bad), 1)
    testing.expect_value(t, len(m3.links), 0)
}

@(test)
guards_and_surfaces :: proc(t: ^testing.T) {
    m := street(20, 5)
    defer destroy(&m)
    apply(t, &m, []Edit{{id = "pond", kind = .Surface, region = rect(8, 0, 12, 5), surface = .Deep}})
    testing.expect(t, !find_path(&m, node(&m, 2.5, 2.5), node(&m, 17.5, 2.5), WALKER, context.temp_allocator).found, "deep water closes the street")

    m2 := street(20, 5)
    defer destroy(&m2)
    apply(t, &m2, nil)
    for y in 0 ..< 5 do m2.layers[0].flags[y * m2.w + 10] = {.No_Guards}
    guard := WALKER
    guard.guard = true
    testing.expect(t, !find_path(&m2, node(&m2, 2.5, 2.5), node(&m2, 17.5, 2.5), guard, context.temp_allocator).found, "guards stay out")
    testing.expect(t, find_path(&m2, node(&m2, 2.5, 2.5), node(&m2, 17.5, 2.5), WALKER, context.temp_allocator).found, "the player doesn't")
}

@(test)
height_decides_sight :: proc(t: ^testing.T) {
    m := street(40, 20)
    defer destroy(&m)
    append(&m.features, Feature{id = "low", kind = .Wall, footprint = rings(rect(20, 0, 21, 20)), height = 1.2})
    append(&m.features, Feature{id = "tower", kind = .Building, footprint = rings(rect(2, 8, 5, 11)), height = 6})
    append(&m.features, Feature{id = "tree", kind = .Tree, footprint = rings(rect(30, 0, 34, 20)), at = {32, 19.5}, trunk = 0.3, bottom = 3, height = 8})
    apply(t, &m, []Edit{{id = "e", kind = .Building, target = "tower", walkable_roof = true}})

    guard := eye_point({10.5, 10.5, 0}, .Standing)
    behind := [3]f32{22.5, 10.5, 0} // right behind the low wall

    testing.expect(t, can_see_body(&m, guard, behind, .Standing), "a standing man shows over a 1.2 m wall")
    testing.expect(t, !can_see_body(&m, guard, behind, .Crouching), "crouching behind it hides him")
    testing.expect(t, !can_see_body(&m, guard, behind, .Prone), "and prone")

    // the tower sees over the wall onto the crouching man; further back too
    tower := eye_point({3.5, 9.5, 6}, .Standing)
    testing.expect(t, can_see_body(&m, tower, {26.5, 10.5, 0}, .Crouching), "from the tower, over the wall")

    // under a canopy: seen; a canopy between: also seen (the ray passes under)
    testing.expect(t, can_see_body(&m, guard, {32.5, 10.5, 0}, .Standing), "under the canopy")
    testing.expect(t, can_see_body(&m, guard, {38.5, 10.5, 0}, .Crouching), "a low wall only hides those close behind it")
    // the tower looking through the canopy: blocked
    testing.expect(t, !can_see(&m, tower, {38.5, 10.5, 1.6}), "through the canopy from above")

    // a car: a span to 1.5 m hides someone crouching, not someone standing
    m2 := street(30, 10)
    defer destroy(&m2)
    append(&m2.features, Feature{id = "car", kind = .Prop, footprint = rings(rect(14, 3, 16, 7)), height = 1.5})
    apply(t, &m2, nil)
    g := eye_point({5.5, 5.5, 0}, .Standing)
    testing.expect(t, !can_see_body(&m2, g, {16.5, 5.5, 0}, .Crouching), "behind a car")
    testing.expect(t, can_see_body(&m2, g, {16.5, 5.5, 0}, .Standing), "over a car")
    testing.expect(t, cover_at(&m2, node(&m2, 16.5, 5.5)) == .Low, "the cell beside a car is low cover")
    testing.expect(t, cover_at(&m2, node(&m2, 10.5, 5.5)) == .None, "open street")

    // a hill hides what is behind it
    m3 := street(30, 3)
    defer destroy(&m3)
    for y in 0 ..< 3 do set_cell(&m3, 0, 15, y, 3)
    reindex(&m3)
    testing.expect(t, !can_see_body(&m3, eye_point({5.5, 1.5, 0}, .Standing), {25.5, 1.5, 0}, .Standing), "over the hill")
}

@(test)
vision_cone :: proc(t: ^testing.T) {
    m := street(30, 30)
    defer destroy(&m)
    append(&m.features, Feature{id = "wall", kind = .Wall, footprint = rings(rect(15, 10, 16, 20)), height = 3})
    apply(t, &m, nil)
    out := make([]bool, m.w * m.h, context.temp_allocator)
    eye := eye_point({5.5, 15.5, 0}, .Standing)
    visible(&m, eye, 0, math.PI / 2, 20, out)

    testing.expect(t, out[15 * m.w + 10], "ahead, in front of the wall")
    testing.expect(t, !out[15 * m.w + 20], "behind the wall")
    testing.expect(t, !out[15 * m.w + 2], "behind the guard")
    testing.expect(t, !out[15 * m.w + 28], "out of range")
    testing.expect(t, out[5 * m.w + 15], "ahead and to the side, past the wall's end")
}

@(test)
edits_report_and_flatten :: proc(t: ^testing.T) {
    m := street(20, 20)
    defer destroy(&m)
    for y in 0 ..< 20 {
        for x in 0 ..< 20 do set_cell(&m, 0, x, y, f32(x % 3) * 0.1)
    }
    append(&m.features, Feature{id = "b1", kind = .Building, footprint = rings(rect(2, 2, 6, 6)), height = 5})
    append(&m.features, Feature{id = "t1", kind = .Tree, footprint = rings(rect(10, 10, 13, 13)), at = {11.5, 11.5}, trunk = 0.4, bottom = 3, height = 7})
    problems := apply_edits(&m, []Edit{
        {id = "gone", kind = .Building, target = "b9", height = 4},
        {id = "rm", kind = .Remove, target = "t1"},
        {id = "rm2", kind = .Remove, target = "t1"},
        {id = "flat", kind = .Flatten, region = rect(14, 0, 20, 6), fit = true},
        {id = "level", kind = .Flatten, region = rect(14, 10, 20, 16), height = 0.5},
        {id = "taller", kind = .Building, target = "b1", height = 9},
    }, context.temp_allocator)

    testing.expect_value(t, len(problems), 2)
    if len(problems) == 2 {
        testing.expect_value(t, problems[0].edit, "gone")
        testing.expect_value(t, problems[1].edit, "rm2")
    }
    testing.expect(t, walkable(&m, node(&m, 11.5, 11.5)), "the removed tree's trunk is ground again")
    testing.expect_value(t, spans_at(&m, 11, 11)[0], Span{})
    testing.expect_value(t, metres(spans_at(&m, 3, 3)[0].top), f32(9))

    h0, _ := height(&m, node(&m, 14.5, 0.5))
    for y in 0 ..< 6 {
        for x in 14 ..< 20 {
            h, _ := height(&m, Node{0, i32(x), i32(y)})
            testing.expectf(t, h == h0, "flattened %d,%d: %v vs %v", x, y, h, h0)
        }
    }
    testing.expect(t, abs(h0 - 0.1) < 0.011, "fit: the mean")
    h1, _ := height(&m, node(&m, 15.5, 12.5))
    testing.expect_value(t, h1, f32(0.5))

    again := apply_edits(&m, nil, context.temp_allocator)
    testing.expect_value(t, len(again), 1)
}

@(test)
interior_hook :: proc(t: ^testing.T) {
    m := street(30, 20)
    defer destroy(&m)
    append(&m.features, Feature{id = "b1", kind = .Building, footprint = rings(rect(10, 5, 20, 15)), height = 6})
    apply(t, &m, []Edit{{id = "inn", kind = .Interior, target = "b1", size = {8, 6}, a = {9.5, 10.5, 0}, b = {0.5, 3.5, 0}}})
    testing.expect_value(t, len(m.interiors), 1)
    testing.expect_value(t, len(m.links), 1)
    if len(m.links) == 1 {
        testing.expect_value(t, m.links[0].b.interior, "inn")
        testing.expect(t, !link_usable(m.links[0], WALKER), "street paths don't go into interiors yet")
    }
    in_ := &m.interiors[0].m
    testing.expect(t, .Indoors in flags_at(in_, Node{0, 3, 3}), "interiors are indoors")
    testing.expect(t, find_path(in_, Node{0, 0, 0}, Node{0, 7, 5}, WALKER, context.temp_allocator).found, "walk inside")
}

@(test)
file_round_trip :: proc(t: ^testing.T) {
    m := street(30, 20, 0.5)
    defer destroy(&m)
    m.frame = Frame{origin = {1, 2}, size = {30, 20}, yaw = 12.5, world_scale = 0.005, ground = -0.01}
    append(&m.features, Feature{id = "b1", kind = .Building, footprint = rings(rect(10, 5, 20, 15)), height = 6})
    append(&m.features, Feature{id = "t1", kind = .Tree, footprint = rings(rect(24, 2, 27, 5)), at = {25.5, 3.5}, trunk = 0.4, bottom = 3, height = 8})
    apply(t, &m, []Edit{
        {id = "e1", kind = .Building, target = "b1", walkable_roof = true},
        {id = "e2", kind = .Link, link = .Ladder, a = {9.75, 10.25, 0}, b = {10.25, 10.25, 6}},
        {id = "e3", kind = .Interior, target = "b1", size = {8, 6}, a = {9.75, 12.25, 0}, b = {0.25, 0.25, 0}},
        {id = "e4", kind = .Surface, region = rect(0, 0, 5, 5), surface = .Gravel},
    })

    dir := os.get_env("TMPDIR", context.temp_allocator)
    if dir == "" do dir = "/tmp"
    path, _ := filepath.join({dir, "gamemap_test.map.json"}, context.temp_allocator)
    testing.expect_value(t, save(m, path), Error.None)
    defer os.remove(path)
    defer os.remove(bin_path(path, context.temp_allocator))

    r, err := load(path)
    defer destroy(&r)
    testing.expect_value(t, err, Error.None)
    if err != .None do return

    testing.expect_value(t, r.frame, m.frame)
    testing.expect_value(t, r.w, m.w)
    testing.expect_value(t, len(r.layers), len(m.layers))
    for l, i in m.layers {
        q := r.layers[i]
        testing.expect_value(t, q.name, l.name)
        testing.expect_value(t, [4]int{q.x, q.y, q.w, q.h}, [4]int{l.x, l.y, l.w, l.h})
        for k in 0 ..< len(l.height) {
            if q.height[k] != l.height[k] || q.surface[k] != l.surface[k] || q.cover[k] != l.cover[k] || q.flags[k] != l.flags[k] {
                testing.expectf(t, false, "layer %d cell %d differs", i, k)
                break
            }
        }
    }
    for s, i in m.spans {
        if r.spans[i] != s {
            testing.expectf(t, false, "spans of cell %d differ", i)
            break
        }
    }
    testing.expect_value(t, len(r.features), 2)
    testing.expect_value(t, r.features[1].id, "t1")
    testing.expect_value(t, r.features[1].kind, Feature_Kind.Tree)
    testing.expect_value(t, len(r.links), 2)
    testing.expect_value(t, r.links[0].kind, Link_Kind.Ladder)
    testing.expect_value(t, r.links[1].b.interior, "e3")
    testing.expect_value(t, len(r.interiors), 1)
    testing.expect_value(t, r.interiors[0].m.w, 8)
    testing.expect(t, .Indoors in flags_at(&r.interiors[0].m, Node{0, 2, 2}), "interior grids")

    // the loaded map plays the same
    a := find_path(&m, node(&m, 2.25, 10.25), node(&m, 15.25, 10.25, 6), WALKER, context.temp_allocator)
    b := find_path(&r, node(&r, 2.25, 10.25), node(&r, 15.25, 10.25, 6), WALKER, context.temp_allocator)
    testing.expectf(t, a.found && b.found && a.cost == b.cost && len(a.nodes) == len(b.nodes), "same path after loading: %v %v %v %v", a.found, b.found, a.cost, b.cost)

    // a newer version is refused
    text, _ := os.read_entire_file(path, context.temp_allocator)
    newer, _ := filepath.join({dir, "gamemap_newer.map.json"}, context.temp_allocator)
    patched := transmute([]byte)fmt.tprintf("%s", string(text))
    for i in 0 ..< len(patched) - 12 {
        if string(patched[i:i + 12]) == "\"version\": 1" {
            patched[i + 11] = '9'
            break
        }
    }
    _ = os.write_entire_file(newer, patched)
    defer os.remove(newer)
    _, verr := load(newer)
    testing.expect_value(t, verr, Error.Version)

    // a missing binary file is an error, not an empty map
    _, berr := load(newer[:len(newer) - 5])
    testing.expect_value(t, berr, Error.Read)
}

@(test)
deterministic :: proc(t: ^testing.T) {
    mk :: proc(t: ^testing.T) -> Map {
        m := street(40, 40)
        append(&m.features, Feature{id = "b1", kind = .Building, footprint = rings(rect(10, 10, 20, 30)), height = 6})
        append(&m.features, Feature{id = "b2", kind = .Building, footprint = rings(rect(22, 5, 30, 25)), height = 4})
        apply(t, &m, nil)
        return m
    }
    a, b := mk(t), mk(t)
    defer destroy(&a)
    defer destroy(&b)
    p := find_path(&a, node(&a, 1.5, 20.5), node(&a, 38.5, 20.5), WALKER, context.temp_allocator)
    q := find_path(&b, node(&b, 1.5, 20.5), node(&b, 38.5, 20.5), WALKER, context.temp_allocator)
    testing.expect(t, p.found && len(p.nodes) == len(q.nodes), "same length")
    for n, i in p.nodes do if n != q.nodes[i] do testing.expectf(t, false, "node %d differs", i)
}

@(test)
clearance :: proc(t: ^testing.T) {
    // a 1 m gap in a wall: a walker goes through, someone 2 m wide does not
    m := street(20, 20)
    defer destroy(&m)
    append(&m.features, Feature{id = "w1", kind = .Wall, footprint = rings(rect(10, 0, 11, 9)), height = 3})
    append(&m.features, Feature{id = "w2", kind = .Wall, footprint = rings(rect(10, 10, 11, 20)), height = 3})
    apply(t, &m, nil)
    testing.expect(t, find_path(&m, node(&m, 5.5, 9.5), node(&m, 15.5, 9.5), WALKER, context.temp_allocator).found, "through the gap")
    wide := Agent{radius = 1}
    testing.expect(t, !find_path(&m, node(&m, 5.5, 5.5), node(&m, 15.5, 5.5), wide, context.temp_allocator).found, "too wide for it")
}

// Not a pass / fail: how long a long path takes on a full-size map, 400 x 400
// cells with a block of buildings. Logged.
@(test)
speed :: proc(t: ^testing.T) {
    m := street(200, 200, 0.5)
    defer destroy(&m)
    for by in 0 ..< 9 {
        for bx in 0 ..< 9 {
            x, y := f32(10 + bx * 20), f32(10 + by * 20)
            append(&m.features, Feature{id = fmt.aprintf("b%d_%d", bx, by, allocator = m.allocator), kind = .Building, footprint = rings(rect(x, y, x + 14, y + 14)), height = 8})
        }
    }
    apply(t, &m, nil)
    start := node(&m, 1, 1)
    goal := node(&m, 198, 198)
    p: Path
    t0 := time.tick_now()
    for _ in 0 ..< 5 do p = find_path(&m, start, goal, WALKER, context.temp_allocator)
    ms := time.duration_milliseconds(time.tick_since(t0)) / 5
    testing.expect(t, p.found, "across the town")
    out := make([]bool, m.w * m.h, context.temp_allocator)
    t1 := time.tick_now()
    visible(&m, eye_point({100, 100, 0}, .Standing), 0, math.PI / 2, 30, out)
    vms := time.duration_milliseconds(time.tick_since(t1))
    log.infof("400 x 400 cells: corner to corner %.2f ms, a 30 m cone %.2f ms", ms, vms)
}
