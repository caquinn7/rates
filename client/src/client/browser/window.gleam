@external(javascript, "../../window_ffi.mjs", "setTimeout")
pub fn set_timeout(func: fn() -> Nil, delay: Int) -> Int
