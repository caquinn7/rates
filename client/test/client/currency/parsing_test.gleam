import client/currency/parsing
import gleam/list
import shared/numbers/non_negative_float

pub fn parse_amount_rejects_leading_signs_test() {
  list.each(
    [
      "+", "-", "+1", "-1", "+0", "-0", "+0.00", "-0.00", "+.5", "-.5",
      "+1,234.56", "-1,234.56", "+1.0e3", "-1.0e3",
    ],
    fn(text) {
      assert parsing.parse_amount(text) == Error(Nil)
    },
  )
}

pub fn parse_amount_accepts_existing_unsigned_syntax_test() {
  list.each(
    [
      #("0", 0.0),
      #("1", 1.0),
      #(".5", 0.5),
      #("0.", 0.0),
      #("1.2300", 1.23),
      #("1.23456789", 1.23456789),
      #("1,234.56", 1234.56),
      #("1.0e10", 10_000_000_000.0),
      #("1.0e-3", 0.001),
      #("1.0E+3", 1000.0),
    ],
    fn(test_case) {
      let #(text, expected) = test_case
      let assert Ok(amount) = parsing.parse_amount(text)
      assert non_negative_float.unwrap(amount) == expected
    },
  )
}

pub fn parse_amount_preserves_existing_invalid_syntax_test() {
  list.each(["", " ", "1,00", "1..", "1e3"], fn(text) {
    assert parsing.parse_amount(text) == Error(Nil)
  })
}
