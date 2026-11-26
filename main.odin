
package main

import "core:os"

import rl "vendor:raylib"
import "camera"
import "game"
import "mission"
import "nav"
import "render"

// Translates the keyboard into one frame of simulation input.
input_poll :: proc() -> game.Input {
    input := game.Input{
        sneak = rl.IsKeyDown(rl.KeyboardKey.LEFT_CONTROL),
        run = rl.IsKeyDown(rl.KeyboardKey.LEFT_SHIFT),
        interact = rl.IsKeyPressed(rl.KeyboardKey.E),
        restart = rl.IsKeyPressed(rl.KeyboardKey.R),
    }

    if rl.IsKeyDown(rl.KeyboardKey.W) do input.move.y -= 1
    if rl.IsKeyDown(rl.KeyboardKey.S) do input.move.y += 1
    if rl.IsKeyDown(rl.KeyboardKey.A) do input.move.x -= 1
    if rl.IsKeyDown(rl.KeyboardKey.D) do input.move.x += 1

    return input
}

main :: proc() {
    rl.InitWindow(1280, 720, "Operation Eagle Nest - Greybox")
    defer rl.CloseWindow()

    rl.SetTargetFPS(60)

    // odin run . -- path/to/mission.json   (e.g. a mission exported by sandtable)
    mission_path := "mission/eagle/mission.json"
    if len(os.args) > 1 do mission_path = os.args[1]

    level, mission_ok := mission.load(mission_path)
    if !mission_ok {
        return
    }

    world := game.world_init(level)
    defer game.world_destroy(&world)

    cam := camera.init(render.point_to_world(world.player.position, 1), 65)
    cam.follows = true

    nav_debug_path := nav.Path{}
    defer delete(nav_debug_path.points)

    for !rl.WindowShouldClose() {
        dt := rl.GetFrameTime()

        // Toggle camera follow with F.
        if rl.IsKeyPressed(rl.KeyboardKey.F) {
            cam.follows = !cam.follows
        }

        game.update(&world, input_poll(), dt)

        // Recalculate a debug path for the west guard on demand.
        if rl.IsKeyPressed(rl.KeyboardKey.P) {
            delete(nav_debug_path.points)
            nav_debug_path = nav.Path{}

            if len(world.guards) > 0 {
                guard := &world.guards[0]

                if len(guard.patrol.points) > 0 &&
                   guard.patrol.target_index >= 0 &&
                   guard.patrol.target_index < len(guard.patrol.points) {
                    nav_debug_path = nav.find_path(
                        &world.level,
                        guard.position,
                        guard.patrol.points[guard.patrol.target_index],
                        guard.radius,
                    )
                }
            }
        }

        camera.update(&cam, dt)
        camera.follow(&cam, render.point_to_world(world.player.position, 1), dt)

        rl.BeginDrawing()
        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(cam.camera)
        render.world(world, nav_debug_path)
        rl.EndMode3D()

        render.hud_draw(world)

        rl.EndDrawing()
    }
}
