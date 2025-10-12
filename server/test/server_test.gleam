import gleeunit
import glight

pub fn main() {
  // silence logger for tests
  glight.configure([])
  gleeunit.main()
}
