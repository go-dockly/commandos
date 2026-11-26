package actors

// One frame of player intent. The simulation only ever sees this struct,
// never the keyboard, so game_update can be driven headlessly in tests.
//
// move uses the player's ground plane: move.x is +right, move.y is +down
// (towards the mission's +y, which is world +z). It need not be normalised;
// player_update normalises it.
//
// interact and restart are edge-triggered: set them only on the frame the
// key was pressed, not while it is held.
Input :: struct {
    move: [2]f32,
    sneak: bool,
    run: bool,
    interact: bool,
    restart: bool,
}
