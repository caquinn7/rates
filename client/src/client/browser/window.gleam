@external(javascript, "../../window_ffi.mjs", "setTimeout")
pub fn set_timeout(func: fn() -> Nil, delay: Int) -> Int

@external(javascript, "../../window_ffi.mjs", "getUrlWithUpdatedQueryParam")
pub fn get_url_with_updated_query_param(key: String, value: String) -> String
