//// Maps CoinMarketCap IDs to verified Kraken WebSocket v2 asset codes.
////
//// Verified November 19, 2026 against the top 100 crypto assets by rank and
//// the five fiat currencies in the [deployed catalog](https://rates.fly.dev/).
//// Asset identities were checked against [Kraken's spot markets](https://support.kraken.com/articles/kraken-markets)
//// and [asset list](https://support.kraken.com/articles/360000678446-cryptocurrencies-available-on-kraken).
//// Codes were checked against a live [WebSocket v2 instrument snapshot](https://docs.kraken.com/exchange/api-reference/spot-websocket-v2/instrument).
//// The mapping covers 92 of those crypto assets and four fiat currencies.
////
//// LEO (3957), KCS (2087), GT (4269), TUSD (2563), Binance Life (38590),
//// KITE (38828), BSV (3602), and INR (2796) had no matching spot pair in the
//// snapshot. United Stables (39120) is unmapped because Kraken's U is Union.
//// MemeCore (35491) was verified and its pairs were cancel-only at the time.
////
//// CoinMarketCap's [Gram](https://coinmarketcap.com/currencies/gram/) (11419)
//// is still [Toncoin on Kraken](https://www.kraken.com/convert/ton).
//// [Lighter](https://coinmarketcap.com/currencies/lighter/) (39125) uses
//// [LIGHTER on Kraken](https://www.kraken.com/prices/lighter). Kraken uses
//// [LIT for Litentry](https://blog.kraken.com/product/asset-listings/lit-meme-and-mog-available-for-trading).
//// [Nexo](https://blog.kraken.com/product/asset-listings/nexo-is-available-for-trading)
//// (2694) was confirmed through Kraken's listing announcement.
////
//// Kraken confirmed the migrations for [POL](https://support.kraken.com/articles/changes-to-matic-on-the-polygon-network)
//// and [AERO](https://support.kraken.com/articles/aero-migration). CoinMarketCap
//// still identifies [FET](https://coinmarketcap.com/currencies/artificial-superintelligence-alliance/)
//// (3773) as the Fetch.ai token under the alliance name.
//// [BTT](https://coinmarketcap.com/currencies/bittorrent-new/) (16086) and
//// [SUN](https://coinmarketcap.com/currencies/sun-token/) (10529) refer to the
//// current TRC-20 tokens listed by Kraken.

/// Returns the verified Kraken asset code for a CoinMarketCap ID.
pub fn from_cmc_id(id: Int) -> Result(String, Nil) {
  case id {
    // Bitcoin
    1 -> Ok("BTC")
    // Litecoin
    2 -> Ok("LTC")
    // XRP
    52 -> Ok("XRP")
    // Dogecoin
    74 -> Ok("DOGE")
    // Dash
    131 -> Ok("DASH")
    // Monero
    328 -> Ok("XMR")
    // Stellar
    512 -> Ok("XLM")
    // Tether USDt
    825 -> Ok("USDT")
    // Ethereum
    1027 -> Ok("ETH")
    // Ethereum Classic
    1321 -> Ok("ETC")
    // Zcash
    1437 -> Ok("ZEC")
    // Bitcoin Cash
    1831 -> Ok("BCH")
    // BNB
    1839 -> Ok("BNB")
    // TRON
    1958 -> Ok("TRX")
    // Chainlink
    1975 -> Ok("LINK")
    // Cardano
    2010 -> Ok("ADA")
    // Filecoin
    2280 -> Ok("FIL")
    // XDC Network
    2634 -> Ok("XDC")
    // Nexo
    2694 -> Ok("NEXO")
    // United States Dollar
    2781 -> Ok("USD")
    // Euro
    2790 -> Ok("EUR")
    // Pound Sterling
    2791 -> Ok("GBP")
    // Japanese Yen
    2797 -> Ok("JPY")
    // VeChain
    3077 -> Ok("VET")
    // Quant
    3155 -> Ok("QNT")
    // USDC
    3408 -> Ok("USDC")
    // Cronos
    3635 -> Ok("CRO")
    // Artificial Superintelligence Alliance
    3773 -> Ok("FET")
    // Cosmos
    3794 -> Ok("ATOM")
    // OKB
    3897 -> Ok("OKB")
    // Algorand
    4030 -> Ok("ALGO")
    // Hedera
    4642 -> Ok("HBAR")
    // PAX Gold
    4705 -> Ok("PAXG")
    // Stacks
    4847 -> Ok("STX")
    // Dai
    4943 -> Ok("DAI")
    // Tether Gold
    5176 -> Ok("XAUT")
    // Solana
    5426 -> Ok("SOL")
    // JUST
    5488 -> Ok("JST")
    // Render
    5690 -> Ok("RENDER")
    // Avalanche
    5805 -> Ok("AVAX")
    // Shiba Inu
    5994 -> Ok("SHIB")
    // NEAR Protocol
    6535 -> Ok("NEAR")
    // Curve DAO Token
    6538 -> Ok("CRV")
    // Polkadot
    6636 -> Ok("DOT")
    // Uniswap
    7083 -> Ok("UNI")
    // PancakeSwap
    7186 -> Ok("CAKE")
    // Injective
    7226 -> Ok("INJ")
    // Aave
    7278 -> Ok("AAVE")
    // Flare
    7950 -> Ok("FLR")
    // Raydium
    8526 -> Ok("RAY")
    // Internet Computer
    8916 -> Ok("ICP")
    // Sun [New]
    10_529 -> Ok("SUN")
    // Bitget Token
    11_092 -> Ok("BGB")
    // Gram (prev. Toncoin)
    11_419 -> Ok("TON")
    // Arbitrum
    11_841 -> Ok("ARB")
    // Worldcoin
    13_502 -> Ok("WLD")
    // BitTorrent [New]
    16_086 -> Ok("BTT")
    // USDD
    19_891 -> Ok("USDD")
    // Kaspa
    20_396 -> Ok("KAS")
    // EURC
    20_641 -> Ok("EURC")
    // Sui
    20_947 -> Ok("SUI")
    // Ondo
    21_159 -> Ok("ONDO")
    // Aptos
    21_794 -> Ok("APT")
    // Celestia
    22_861 -> Ok("TIA")
    // Bittensor
    22_974 -> Ok("TAO")
    // Sei
    23_149 -> Ok("SEI")
    // Pepe
    24_478 -> Ok("PEPE")
    // LayerZero
    26_997 -> Ok("ZRO")
    // Mantle
    27_075 -> Ok("MNT")
    // PayPal USD
    27_772 -> Ok("PYUSD")
    // Pyth Network
    28_177 -> Ok("PYTH")
    // Polygon (prev. MATIC)
    28_321 -> Ok("POL")
    // Jupiter
    29_210 -> Ok("JUP")
    // Aero
    29_270 -> Ok("AERO")
    // Ethena USDe
    29_470 -> Ok("USDE")
    // ether.fi
    29_814 -> Ok("ETHFI")
    // Ethena
    30_171 -> Ok("ENA")
    // Hyperliquid
    32_196 -> Ok("HYPE")
    // Sky
    33_038 -> Ok("SKY")
    // World Liberty Financial
    33_251 -> Ok("WLFI")
    // Global Dollar
    33_793 -> Ok("USDG")
    // Morpho
    34_104 -> Ok("MORPHO")
    // Ripple USD
    34_387 -> Ok("RLUSD")
    // Pudgy Penguins
    34_466 -> Ok("PENGU")
    // MemeCore
    35_491 -> Ok("M")
    // Venice Token
    35_509 -> Ok("VVV")
    // Pi
    35_697 -> Ok("PI")
    // World Liberty Financial USD
    36_148 -> Ok("USD1")
    // Aster
    36_341 -> Ok("ASTER")
    // Pump.fun
    36_507 -> Ok("PUMP")
    // Canton
    37_263 -> Ok("CC")
    // Falcon Finance
    38_482 -> Ok("FF")
    // Pieverse
    38_849 -> Ok("PIEVERSE")
    // Stable
    38_892 -> Ok("STABLE")
    // Midnight
    39_064 -> Ok("NIGHT")
    // Lighter
    39_125 -> Ok("LIGHTER")
    _ -> Error(Nil)
  }
}
