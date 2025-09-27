import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import server/rates/rate_error.{type RateError}
import server/utils/logger
import shared/currency.{type Currency}
import shared/page_data.{type PageData, PageData}
import shared/rates/rate_request.{type RateRequest, RateRequest}
import shared/rates/rate_response.{type RateResponse}
import wisp.{type Response}

pub fn get(
  currencies: List(Currency),
  get_rate: fn(RateRequest) -> Result(RateResponse, RateError),
) -> Response {
  currencies
  |> get_page_data(get_rate)
  |> result.map_error(fn(_) { wisp.internal_server_error() })
  |> result.map(fn(page_data) {
    let page_data_json =
      page_data
      |> page_data.encode
      |> json.to_string

    page_data_json
    |> page_scaffold
    |> element.to_document_string_tree
    |> wisp.html_body(wisp.response(200), _)
  })
  |> result.unwrap_both
}

fn get_page_data(
  currencies: List(Currency),
  get_rate: fn(RateRequest) -> Result(RateResponse, RateError),
) -> Result(PageData, Nil) {
  use btc <- result.try(list.find(currencies, fn(c) { c.symbol == "BTC" }))
  use usd <- result.try(list.find(currencies, fn(c) { c.symbol == "USD" }))

  let rate_req = RateRequest(btc.id, usd.id)

  use rate_response <- result.try(
    rate_req
    |> get_rate
    |> result.map_error(log_rate_request_error(rate_req, _)),
  )

  Ok(PageData(currencies, rate_response))
}

fn log_rate_request_error(rate_req: RateRequest, err: RateError) -> Nil {
  logger.error(
    logger.new()
      |> logger.with("source", "home")
      |> logger.with("rate_request.from", int.to_string(rate_req.from))
      |> logger.with("rate_request.to", int.to_string(rate_req.to))
      |> logger.with("error", string.inspect(err)),
    "Error getting rate",
  )
}

fn page_scaffold(seed_json: String) -> Element(a) {
  html.html(
    [
      attribute.attribute("lang", "en"),
      attribute.attribute("data-theme", "business"),
    ],
    [
      html.head([], [
        html.meta([attribute.attribute("charset", "UTF-8")]),
        html.meta([
          attribute.attribute(
            "content",
            "width=device-width, initial-scale=1.0",
          ),
          attribute.name("viewport"),
        ]),
        html.title([], "rates 💹"),
        html.style(
          [],
          "
        @font-face {
          font-family: 'Roboto';
          src: url('/static/fonts/roboto/Roboto-VariableFont_wdth,wght.ttf') format('truetype');
          font-weight: 100 900;
          /* Supports weights from 100 to 900 */
          font-stretch: 75% 125%;
          /* Supports widths (stretch) from 75% to 125% */
          font-style: normal;
        }
        @font-face {
          font-family: 'Roboto';
          src: url('/static/fonts/roboto/Roboto-Italic-VariableFont_wdth,wght.ttf') format('truetype');
          font-weight: 100 900;
          font-stretch: 75% 125%;
          font-style: italic;
        }
        body {
          font-family: 'Roboto', sans-serif;
        }
      ",
        ),
        html.link([
          attribute.rel("stylesheet"),
          attribute.type_("text/css"),
          attribute.href("/static/client.css"),
        ]),
        html.script(
          [attribute.src("/static/client.mjs"), attribute.type_("module")],
          "",
        ),
        html.script(
          [attribute.type_("application/json"), attribute.id("model")],
          seed_json,
        ),
      ]),
      html.body([attribute.class("flex flex-col min-h-screen")], [
        html.div([attribute.id("app")], []),
      ]),
    ],
  )
}
