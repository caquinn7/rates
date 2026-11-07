let activeBrowser;

export function withBrowser(run) {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const previousHistory = Object.getOwnPropertyDescriptor(globalThis, "history");
  const previousBrowser = activeBrowser;
  const browser = { url: new URL("https://rates.test/"), writes: 0 };
  activeBrowser = browser;

  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: { get location() { return browser.url; } },
  });
  Object.defineProperty(globalThis, "history", {
    configurable: true,
    value: {
      replaceState(_state, _title, url) {
        browser.url = new URL(url);
        browser.writes += 1;
      },
    },
  });

  try {
    return run();
  } finally {
    restoreGlobal("window", previousWindow);
    restoreGlobal("history", previousHistory);
    activeBrowser = previousBrowser;
  }
}

function restoreGlobal(name, descriptor) {
  if (descriptor) {
    Object.defineProperty(globalThis, name, descriptor);
  } else {
    delete globalThis[name];
  }
}

export function encodedState() {
  return activeBrowser.url.searchParams.get("state") ?? "";
}

export function urlWriteCount() {
  return activeBrowser.writes;
}

export function socket() {
  return { send() { } };
}
