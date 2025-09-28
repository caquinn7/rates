import server/domain/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/integrations/kraken/price_store.{type PriceEntry}

pub type KrakenInterface {
  KrakenInterface(
    subscribe: fn(KrakenSymbol) -> Nil,
    unsubscribe: fn(KrakenSymbol) -> Nil,
    check_for_price: fn(KrakenSymbol) -> Result(PriceEntry, Nil),
  )
}
