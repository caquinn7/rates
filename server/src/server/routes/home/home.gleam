import client
import client/start_data.{StartData} as _client_start_data
import gleam/json
import gleam/list
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import server/routes/home/start_data
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest, RateRequest}
import shared/rates/rate_response.{type RateResponse}
import wisp.{type Response}

pub fn get(
  currencies: List(Currency),
  get_rate: fn(RateRequest) -> Result(RateResponse, Nil),
) -> Response {
  currencies
  |> get_start_data(get_rate)
  |> result.map_error(fn(_) { wisp.internal_server_error() })
  |> result.map(fn(start_data) {
    let start_data_json =
      start_data
      |> start_data.encode
      |> json.to_string

    let content =
      start_data
      |> client.model_from_start_data
      |> client.view
      |> page_scaffold(start_data_json)

    content
    |> element.to_document_string_tree
    |> wisp.html_body(wisp.response(200), _)
  })
  |> result.unwrap_both
}

fn get_start_data(
  currencies: List(Currency),
  get_rate: fn(RateRequest) -> Result(RateResponse, Nil),
) {
  use btc <- result.try(list.find(currencies, fn(c) { c.symbol == "BTC" }))
  use usd <- result.try(list.find(currencies, fn(c) { c.symbol == "USD" }))
  use rate_response <- result.try(get_rate(RateRequest(btc.id, usd.id)))
  Ok(StartData(currencies, rate_response))
}

fn page_scaffold(content: Element(a), seed_json: String) -> Element(a) {
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
        html.title([], "RateRadar 💹 📡"),
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
        // html.script(
      //   [attribute.type_("text/javascript")],
      //   "window.__ENV__ = " <> "\"" <> ctx.env <> "\"",
      // ),
      ]),
      html.body([attribute.class("flex flex-col min-h-screen")], [
        html.div([attribute.id("app")], [content]),
      ]),
    ],
  )
}
