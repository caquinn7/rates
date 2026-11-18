import gleeunit
import glight

pub fn main() {
  // silence logger for tests
  let assert Ok(Nil) = glight.configure([])
  gleeunit.main()
}
