package render

import "../game"
import rl "vendor:raylib"

// 2D overlay. Call after EndMode3D. Like render.odin, it only reads the World.
hud_draw :: proc(world: game.World) {
    rl.DrawText("OPERATION EAGLE NEST", 20, 20, 24, rl.DARKGRAY)
    rl.DrawText("WASD: move   Ctrl: sneak   Shift: run   E: interact   R: restart", 20, 54, 18, rl.DARKGRAY)
    rl.DrawText("F: camera follow   P: calculate guard path   Shift + drag: pan   Trackpad scroll: zoom", 20, 78, 18, rl.DARKGRAY)

    if world.level.objective.id != "" {
        if world.objective_complete {
            rl.DrawText("OBJECTIVE COMPLETE - reach the extraction zone", 20, 102, 20, rl.DARKGREEN)
        } else {
            rl.DrawText("OBJECTIVE: retrieve the documents (press E near them)", 20, 102, 20, rl.DARKGRAY)
        }
    }

    switch world.outcome {
    case .PLAYING:
        // No banner while the mission is running.
    case .SUCCESS:
        rl.DrawText("MISSION COMPLETE - press R to restart", 20, 134, 30, rl.DARKGREEN)
    case .FAILED:
        rl.DrawText("CAUGHT - press R to restart", 20, 134, 30, rl.MAROON)
    }
}
