/// Where things sit in the rendered hallway images (pixels in a square of [size]).
/// Generated from tools/intro_render/render.py — re-run it if the scene changes.
class DoorPlate {
  DoorPlate._();
  static const size = 1200.0;
  static const focal = 960.20; // camera focal length in image pixels
  // the doorway opening in the back wall
  static const dwL = 496.1, dwT = 433.4, dwR = 700.4, dwB = 895.3;
  // the face of the closed door
  static const dfL = 500.5, dfT = 436.0, dfR = 696.3, dfB = 887.2;
  // a point down in the stairwell (where the words rise from)
  static const stX = 600.0, stY = 812.7;
}
