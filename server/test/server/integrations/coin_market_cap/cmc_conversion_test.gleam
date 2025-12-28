import gleam/dict
import gleam/json
import gleam/option.{None, Some}
import server/integrations/coin_market_cap/cmc_conversion.{
  CmcConversion, QuoteItem,
}
import shared/positive_float

pub fn decode_conversion_with_integer_amount_test() {
  let json =
    "{
      \"id\": 1,
      \"symbol\": \"BTC\",
      \"name\": \"Bitcoin\",
      \"amount\": 1,
      \"last_updated\": \"2024-09-27T20:57:00.000Z\",
      \"quote\": {
          \"2\": {
              \"price\": 100000,
              \"last_updated\": \"2024-09-27T20:57:00.000Z\"
          }
      }
  }"

  let result = json.parse(json, cmc_conversion.decoder())

  let assert Ok(CmcConversion(1, "BTC", "Bitcoin", amount, quote)) = result

  assert amount == positive_float.from_float_unsafe(1.0)

  assert dict.size(quote) == 1
  let assert Ok(_) = dict.get(quote, "2")
}

pub fn decode_conversion_with_float_amount_test() {
  let json =
    "{
      \"id\": 1,
      \"symbol\": \"BTC\",
      \"name\": \"Bitcoin\",
      \"amount\": 1.1,
      \"last_updated\": \"2024-09-27T20:57:00.000Z\",
      \"quote\": {
          \"2\": {
              \"price\": 100000,
              \"last_updated\": \"2024-09-27T20:57:00.000Z\"
          }
      }
  }"

  let result = json.parse(json, cmc_conversion.decoder())

  let assert Ok(CmcConversion(1, "BTC", "Bitcoin", amount, _)) = result
  assert amount == positive_float.from_float_unsafe(1.1)
}

pub fn decode_quote_item_with_integer_amount_test() {
  let json = "{\"price\":100000,\"last_updated\":\"2024-09-27T20:57:00.000Z\"}"

  let result = json.parse(json, cmc_conversion.quote_item_decoder())

  let assert Ok(QuoteItem(Some(price))) = result
  assert price == positive_float.from_float_unsafe(100_000.0)
}

pub fn decode_quote_item_with_float_amount_test() {
  let json =
    "{\"price\":100000.1,\"last_updated\":\"2024-09-27T20:57:00.000Z\"}"

  let result = json.parse(json, cmc_conversion.quote_item_decoder())

  let assert Ok(QuoteItem(Some(price))) = result
  assert price == positive_float.from_float_unsafe(100_000.1)
}

pub fn decode_quote_item_with_null_amount_test() {
  let json = "{\"price\":null,\"last_updated\":\"2024-09-27T20:57:00.000Z\"}"

  let result = json.parse(json, cmc_conversion.quote_item_decoder())

  assert Ok(QuoteItem(None)) == result
}
