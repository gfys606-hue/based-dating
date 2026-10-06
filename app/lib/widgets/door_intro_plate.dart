/// Where things sit in the rendered study images (pixels in a square of [size]).
/// Generated from tools/intro_render/study.py — re-run it if the scene changes.
class DoorPlate {
  DoorPlate._();
  static const size = 1200.0;
  static const focal = 1082.43; // camera focal length in image pixels
  // the opening in the wall behind the hidden bookcase
  static const dwL = 478.5, dwT = 368.1, dwR = 718.3, dwB = 917.5;
  // the front of the hidden bookcase (the part that swings)
  static const dfL = 468.4, dfT = 327.1, dfR = 727.7, dfB = 947.5;
  // a point down in the stairwell (where the words rise from)
  static const stX = 600.0, stY = 838.5;
  // the red book that works the lever
  static const lbL = 614.9, lbT = 555.0, lbR = 620.9, lbB = 635.1;
}
