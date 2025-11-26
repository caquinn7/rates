import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import server/domain/rates/rate_error.{type RateError}
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
  case get_page_data(currencies, get_rate) {
    Error(_) -> wisp.internal_server_error()

    Ok(page_data) -> {
      let page_data_json =
        page_data
        |> page_data.encode
        |> json.to_string

      page_data_json
      |> page_scaffold
      |> element.to_document_string
      |> wisp.html_body(wisp.response(200), _)
    }
  }
}

fn get_page_data(
  currencies: List(Currency),
  get_rate: fn(RateRequest) -> Result(RateResponse, RateError),
) -> Result(PageData, Nil) {
  let find_currency = fn(symbol) {
    list.find(currencies, fn(c) { c.symbol == symbol })
  }
  use btc <- result.try(find_currency("BTC"))
  use usd <- result.try(find_currency("USD"))

  let rate_req = RateRequest(btc.id, usd.id)

  use rate_response <- result.try(
    rate_req
    |> get_rate
    |> result.map_error(log_rate_request_error(rate_req, _)),
  )

  Ok(PageData(currencies, [rate_response]))
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
      attribute.attribute("data-theme", "dracula"),
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
          "@font-face {
            font-family: 'Roboto Mono';
            src: url('/static/fonts/roboto-mono/RobotoMono-VariableFont_wght.ttf') format('truetype');
            font-weight: 400;
            font-style: normal;
          }

          @font-face {
            font-family: 'Roboto Mono';
            src: url('/static/fonts/roboto-mono/RobotoMono-Italic-VariableFont_wght.ttf') format('truetype');
            font-weight: 400;
            font-style: italic;
          }

          @keyframes glow {
            0%, 100% {
              color: inherit;
              box-shadow: none;
            }
            25% {
              color: var(--glow-color);
              box-shadow: 0 0 4px var(--glow-color)
            }
          }

          .animate-glow {
            animation: glow 2s ease-in-out;
          }

          :root {
            --font-mono: 'Roboto Mono', monospace;
          }

          body {
            font-family: var(--font-mono);
          }",
        ),
        html.link([
          attribute.rel("stylesheet"),
          attribute.type_("text/css"),
          attribute.href("/static/client.css"),
        ]),
        html.script(
          [attribute.src("/static/client.js"), attribute.type_("module")],
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
