const API_BASE = "http://localhost:4000/api/v1";

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

  if (message.type === "RATE_WORD") {
    handleRateWord(message.word, message.languagePair, message.status)
      .then(() => sendResponse({ ok: true }))
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
  const resp = await fetch(`${API_BASE}/auth/login`, {
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

  const resp = await fetch(`${API_BASE}${path}`, { ...options, headers });

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
