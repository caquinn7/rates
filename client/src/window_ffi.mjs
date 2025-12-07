export function setTimeout(func, delayMs) {
  return window.setTimeout(func, delayMs);
}

export function getUrlWithUpdatedQueryParam(key, value) {
  const url = new URL(window.location);
  url.searchParams.set(key, value);
  return url.href;
}