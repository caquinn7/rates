import client/start_data.{type StartData}
import gleam/json.{type Json}
import server/rates/rate_response
import server/routes/home/currency

pub fn encode(start_data: StartData) -> Json {
  json.object([
    #("currencies", json.array(start_data.currencies, currency.encode)),
    #("rate", rate_response.encode(start_data.rate)),
  ])
}
