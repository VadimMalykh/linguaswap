// Where the Phoenix app lives. Overridable from the popup and stored in
// chrome.storage.local, so a build can point at a deployed backend without a
// code change; the matching host permission is requested at the same time.
const DEFAULT_SERVER_URL = "http://localhost:4000";

// Trailing slashes and a pasted "/api/v1" are the two things people actually
// type, so both are absorbed rather than rejected.
function normalizeServerUrl(url) {
  return String(url || "")
    .trim()
    .replace(/\/+$/, "")
    .replace(/\/api\/v1$/, "");
}

async function apiBase() {
  const { serverUrl } = await chrome.storage.local.get("serverUrl");
  return `${normalizeServerUrl(serverUrl) || DEFAULT_SERVER_URL}/api/v1`;
}

let cachedWords = null;
let cachedLanguagePair = null;

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "LOGIN") {
    handleLogin(message.email, message.password)
      .then((result) => sendResponse(result))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }

  if (message.type === "LOGOUT") {
    chrome.storage.local.remove(["token", "user"]);
    cachedWords = null;
    cachedLanguagePair = null;
    sendResponse({ ok: true });
    return false;
  }

  if (message.type === "GET_STATUS") {
    chrome.storage.local.get(["token", "user"], (data) => {
      sendResponse({
        loggedIn: !!data.token,
        user: data.user || null,
      });
    });
    return true;
  }

  if (message.type === "GET_WORDS") {
    handleGetWords(message.languagePair)
      .then((words) => sendResponse({ ok: true, words }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }

  if (message.type === "RECORD_REVEAL") {
    handleRecordReveal(message.word, message.languagePair)
      .then(() => sendResponse({ ok: true }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }

  if (message.type === "RECORD_REPLACEMENT") {
    handleRecordReplacement(message.word, message.languagePair)
      .then(() => sendResponse({ ok: true }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }

  if (message.type === "RECORD_REPLACEMENTS") {
    handleRecordReplacements(message.words, message.languagePair)
      .then(() => sendResponse({ ok: true }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }

  if (message.type === "GET_SERVER_URL") {
    chrome.storage.local.get("serverUrl", (data) => {
      sendResponse({
        ok: true,
        serverUrl: normalizeServerUrl(data.serverUrl) || DEFAULT_SERVER_URL,
      });
    });
    return true;
  }

  if (message.type === "SET_SERVER_URL") {
    const serverUrl = normalizeServerUrl(message.serverUrl) || DEFAULT_SERVER_URL;
    chrome.storage.local.set({ serverUrl }, () => {
      // The cached dictionary belongs to the old server.
      cachedWords = null;
      cachedLanguagePair = null;
      sendResponse({ ok: true, serverUrl });
    });
    return true;
  }

  if (message.type === "RATE_WORD") {
    handleRateWord(message.word, message.languagePair, message.status)
      .then(() => {
        cachedWords = null;
        cachedLanguagePair = null;
        sendResponse({ ok: true });
      })
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }

  if (message.type === "RECORD_PAGE_VISIT") {
    handleRecordPageVisit(message.url, message.wordsReplaced, message.timeSpent, message.languagePair)
      .then(() => sendResponse({ ok: true }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }

  if (message.type === "GET_STATS") {
    handleGetStats()
      .then((stats) => sendResponse({ ok: true, stats }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
  }
});

async function handleLogin(email, password) {
  const resp = await fetch(`${await apiBase()}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });

  const data = await resp.json();

  if (!resp.ok) {
    return { ok: false, error: data.error || "Login failed" };
  }

  await chrome.storage.local.set({ token: data.token, user: data.user });
  return { ok: true, user: data.user };
}

async function authFetch(path, options = {}) {
  const { token } = await chrome.storage.local.get("token");
  if (!token) throw new Error("Not logged in");

  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
    ...options.headers,
  };

  const resp = await fetch(`${await apiBase()}${path}`, { ...options, headers });

  if (resp.status === 401) {
    await chrome.storage.local.remove(["token", "user"]);
    throw new Error("Session expired");
  }

  return resp;
}

async function handleGetWords(languagePair) {
  if (cachedWords && cachedLanguagePair === languagePair) {
    return cachedWords;
  }

  const resp = await authFetch(`/words?language_pair=${encodeURIComponent(languagePair)}`);
  const data = await resp.json();

  if (!resp.ok) throw new Error(data.error || "Failed to fetch words");

  cachedWords = data.words;
  cachedLanguagePair = languagePair;
  return data.words;
}

async function handleRecordReveal(word, languagePair) {
  const resp = await authFetch("/words/reveal", {
    method: "POST",
    body: JSON.stringify({ word, language_pair: languagePair }),
  });
  if (!resp.ok) {
    const data = await resp.json();
    throw new Error(data.error || "Failed to record reveal");
  }
}

async function handleRecordReplacement(word, languagePair) {
  const resp = await authFetch("/words/replace", {
    method: "POST",
    body: JSON.stringify({ word, language_pair: languagePair }),
  });
  if (!resp.ok) {
    const data = await resp.json();
    throw new Error(data.error || "Failed to record replacement");
  }
}

async function handleRecordReplacements(words, languagePair) {
  if (!Array.isArray(words) || words.length === 0) return;

  const resp = await authFetch("/words/replace", {
    method: "POST",
    body: JSON.stringify({ words, language_pair: languagePair }),
  });
  if (!resp.ok) {
    const data = await resp.json();
    throw new Error(data.error || "Failed to record replacements");
  }
}

async function handleRateWord(word, languagePair, status) {
  const resp = await authFetch("/words/rate", {
    method: "POST",
    body: JSON.stringify({ word, language_pair: languagePair, status }),
  });
  if (!resp.ok) {
    const data = await resp.json();
    throw new Error(data.error || "Failed to rate word");
  }
}

async function handleRecordPageVisit(url, wordsReplaced, timeSpent, languagePair) {
  const resp = await authFetch("/pagevisit", {
    method: "POST",
    body: JSON.stringify({
      url,
      words_replaced: wordsReplaced,
      time_spent: timeSpent,
      language_pair: languagePair,
    }),
  });
  if (!resp.ok) {
    const data = await resp.json();
    throw new Error(data.error || "Failed to record page visit");
  }
}

async function handleGetStats() {
  const resp = await authFetch("/stats");
  const data = await resp.json();
  if (!resp.ok) throw new Error(data.error || "Failed to fetch stats");
  return data.stats;
}

// Exported for the Node tests. In the service worker `module` does not exist,
// so this is inert there — the same trick lemmatizer.js uses.
if (typeof module === "object" && module.exports) {
  module.exports = { normalizeServerUrl, DEFAULT_SERVER_URL };
}
