pub type Side {
  Left
  Right
}

pub fn opposite_side(side: Side) -> Side {
  case side {
    Left -> Right
    Right -> Left
  }
}

pub fn to_string(side) {
  case side {
    Left -> "left"
    Right -> "right"
  }
}
