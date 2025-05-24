pub type Side {
  Left
  Right
}

pub fn to_string(side) {
  case side {
    Left -> "left"
    Right -> "right"
  }
}
