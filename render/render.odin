package render

import "../actors"
import "../game"
import "../gamemap"
import "../mission"
import "../nav"
import "../geom"
import rl "vendor:raylib"

// Everything that turns simulation state into pixels lives in render.odin and
// hud.odin. This is the only place (besides main.odin and the isometric
// camera) that touches raylib, so the simulation stays headless.
//
// The render procs take the World by value. A World is a handful of slices
// and small structs, so the copy is cheap, and it means a render proc cannot
// mutate the simulation.

WALL_RENDER_HEIGHT     :: 2.5
BUILDING_RENDER_HEIGHT :: 4.0
CRATE_RENDER_HEIGHT    :: 2.0

// Map a simulation point into the renderer's 3D space (x → x, y → z).
point_to_world :: proc(p: geom.Point, height: f32 = 0) -> rl.Vector3 {
    return rl.Vector3{p.x, height, p.y}
}

// Draws the 3D scene. Call between BeginMode3D and EndMode3D. debug_path is
// optional; pass an empty result to draw nothing.
world :: proc(world: game.World, debug_path: nav.Path) {
    // bounds takes a pointer, so give it a local copy to point at.
    lvl := world.level

    if lvl.has_map {
        render_map(&lvl.game_map)
    } else {
        render_ground(&lvl)
        render_geometry(world.level.geometry)
    }
    render_debug_path(debug_path)
    render_objective(world)
    render_extraction(world)
    render_player(world.player)
    render_guards(world.guards)
}

render_ground :: proc(lvl: ^mission.Mission) {
    bounds := mission.bounds(lvl)

    rl.DrawPlane(
        {bounds.width * 0.5, 0, bounds.height * 0.5},
        {bounds.width, bounds.height},
        rl.LIGHTGRAY,
    )
    rl.DrawGrid(i32(max(bounds.width, bounds.height)), 5)
}

// Draws the baked collision geometry. Because collision, line of sight and
// rendering all read the same list, a wall opening you can see is an opening
// the guards and the player can use, for walls of either orientation.
render_geometry :: proc(geo: geom.Geometry) {
    for s in geo.solids {
        height: f32
        color: rl.Color
        wire: rl.Color
        draw_wires := false

        #partial switch s.kind {
        case .WALL:
            height = WALL_RENDER_HEIGHT
            color = rl.DARKGRAY
        case .BUILDING:
            height = BUILDING_RENDER_HEIGHT
            color = rl.BROWN
            wire = rl.DARKGRAY
            draw_wires = true
        case .CRATE:
            height = CRATE_RENDER_HEIGHT
            color = rl.BROWN
            wire = rl.DARKBROWN
            draw_wires = true
        case:
            continue
        }

        center := rl.Vector3{s.x + s.w*0.5, height*0.5, s.y + s.h*0.5}
        rl.DrawCube(center, s.w, height, s.h, color)
        if draw_wires {
            rl.DrawCubeWires(center, s.w, height, s.h, wire)
        }
    }

    for c in geo.circles {
        #partial switch c.kind {
        case .BARREL:
            rl.DrawCylinder({c.x, 1, c.y}, c.r, c.r, 2, 12, rl.DARKGREEN)
        case .TREE:
            rl.DrawCylinder({c.x, 1.5, c.y}, 0.55, 0.4, 3, 8, rl.BROWN)
            rl.DrawSphere({c.x, 4, c.y}, c.r, rl.GREEN)
        }
    }
}

render_debug_path :: proc(path: nav.Path) {
    if !path.found || len(path.points) == 0 {
        return
    }

    // Path nodes sit just above ground level.
    for i in 0..<len(path.points) {
        point := point_to_world(path.points[i], 0.18)
        rl.DrawSphere(point, 0.20, rl.GOLD)

        if i + 1 < len(path.points) {
            next := point_to_world(path.points[i + 1], 0.18)
            rl.DrawLine3D(point, next, rl.GOLD)
        }
    }
}

// Objective marker: gold until retrieved, then greyed out.
render_objective :: proc(world: game.World) {
    if world.level.objective.id == "" {
        return
    }

    color := rl.GOLD
    if world.objective_complete {
        color = rl.GRAY
    }

    rl.DrawCube(
        {world.level.objective.x, 0.5, world.level.objective.y},
        1.2, 1, 1.2,
        color,
    )
}

// Extraction: faded while locked, solid green once the objective is complete.
render_extraction :: proc(world: game.World) {
    color := rl.Fade(rl.GREEN, 0.3)
    if world.objective_complete {
        color = rl.GREEN
    }

    e := world.level.extraction
    rl.DrawCylinder({e.x, 0.5, e.y}, e.radius, e.radius, 1, 16, color)
}

PLAYER_FACING_INDICATOR_LENGTH :: 2.5
GUARD_FACING_INDICATOR_LENGTH  :: 1.8

render_player :: proc(player: actors.Player) {
    lift: f32 = 0.6 if player.crouched else 1
    position := point_to_world(player.position, player.h + lift)
    facing_tip := point_to_world(
        {
            player.position.x + player.facing.x * PLAYER_FACING_INDICATOR_LENGTH,
            player.position.y + player.facing.y * PLAYER_FACING_INDICATOR_LENGTH,
        },
        player.h + lift,
    )

    rl.DrawSphere(position, player.radius, rl.BLUE)
    rl.DrawLine3D(position, facing_tip, rl.DARKBLUE)
}

render_guards :: proc(guards: []actors.Guard) {
    for guard in guards {
        position := point_to_world(guard.position, guard.h + 1)
        facing_tip := point_to_world(
            {
                guard.position.x + guard.facing.x * GUARD_FACING_INDICATOR_LENGTH,
                guard.position.y + guard.facing.y * GUARD_FACING_INDICATOR_LENGTH,
            },
            guard.h + 1,
        )

        color := rl.RED
        #partial switch guard.awareness.state {
        case .SUSPICIOUS:
            color = rl.ORANGE
        case .ALERTED:
            color = rl.MAROON
        }

        rl.DrawSphere(position, guard.radius, color)
        rl.DrawLine3D(position, facing_tip, rl.MAROON)
    }
}
MAP_FLOOR_COLOURS := [gamemap.Surface]rl.Color{
    .Ground = {150, 152, 140, 255},
    .Road   = {170, 170, 166, 255},
    .Grass  = {110, 150, 90, 255},
    .Gravel = {170, 160, 130, 255},
    .Roof   = {196, 120, 84, 255},
    .Floor  = {170, 150, 120, 255},
    .Water  = {80, 120, 170, 255},
    .Deep   = {40, 60, 110, 255},
}

// The gameplay map, the way the rules see it: each floor a thin slab at its
// height, each solid span a box (buildings, walls, cars; canopies green and
// floating). Runs of equal cells along x are merged into one box, so a
// street-sized map is a few thousand draws, not one per cell.
render_map :: proc(m: ^gamemap.Map) {
    c := m.cell
    SLAB :: f32(0.06)
    for &l, li in m.layers {
        for ly in 0 ..< l.h {
            lx := 0
            for lx < l.w {
                i := ly * l.w + lx
                if l.height[i] == gamemap.NO_FLOOR {
                    lx += 1
                    continue
                }
                run := 1
                for lx + run < l.w && l.height[i + run] == l.height[i] && l.surface[i + run] == l.surface[i] do run += 1
                h := gamemap.metres(l.height[i])
                x0 := f32(l.x + lx) * c
                y0 := f32(l.y + ly) * c
                col := MAP_FLOOR_COLOURS[l.surface[i]]
                if li > 0 do col = MAP_FLOOR_COLOURS[.Roof]
                rl.DrawCube({x0 + f32(run) * c * 0.5, h - SLAB * 0.5, y0 + c * 0.5}, f32(run) * c, SLAB, c, col)
                lx += run
            }
        }
    }
    for y in 0 ..< m.h {
        for k in 0 ..< gamemap.SPANS {
            x := 0
            for x < m.w {
                s := m.spans[y * m.w + x][k]
                if s.top <= s.bottom {
                    x += 1
                    continue
                }
                run := 1
                for x + run < m.w && m.spans[y * m.w + x + run][k] == s do run += 1
                lo := max(gamemap.metres(s.bottom), 0)
                hi := gamemap.metres(s.top)
                ground, _ := gamemap.height(m, {0, i32(x), i32(y)})
                canopy := lo > ground + 1
                col := rl.Color{90, 130, 80, 255} if canopy else rl.Color{150, 110, 80, 255}
                centre := rl.Vector3{(f32(x) + f32(run) * 0.5) * c, (lo + hi) * 0.5, (f32(y) + 0.5) * c}
                rl.DrawCube(centre, f32(run) * c, hi - lo, c, col)
                rl.DrawCubeWires(centre, f32(run) * c, hi - lo, c, rl.Fade(rl.DARKGRAY, 0.4))
                x += run
            }
        }
    }
    for l in m.links {
        if l.a.interior != "" || l.b.interior != "" do continue
        a := gamemap.node_point(m, {u16(l.a.layer), i32(l.a.x), i32(l.a.y)})
        b := gamemap.node_point(m, {u16(l.b.layer), i32(l.b.x), i32(l.b.y)})
        rl.DrawLine3D({a.x, a.z + 0.1, a.y}, {b.x, b.z + 0.1, b.y}, rl.YELLOW)
        rl.DrawSphere({a.x, a.z + 0.2, a.y}, 0.2, rl.YELLOW)
        rl.DrawSphere({b.x, b.z + 0.2, b.y}, 0.2, rl.YELLOW)
    }
}
