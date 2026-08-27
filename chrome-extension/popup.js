document.addEventListener("DOMContentLoaded", () => {
  const loginView = document.getElementById("login-view");
  const dashboard = document.getElementById("dashboard");
  const loading = document.getElementById("loading");
  const loginForm = document.getElementById("login-form");
  const loginError = document.getElementById("login-error");
  const loginBtn = document.getElementById("login-btn");
  const emailInput = document.getElementById("email");
  const passwordInput = document.getElementById("password");
  const toggleEnabled = document.getElementById("toggle-enabled");
  const languageSelect = document.getElementById("language-select");
  const logoutBtn = document.getElementById("logout-btn");
  const dashboardLink = document.getElementById("dashboard-link");
  const serverUrlInput = document.getElementById("server-url");
  const serverSaveBtn = document.getElementById("server-save");
  const serverMsg = document.getElementById("server-msg");

  chrome.runtime.sendMessage({ type: "GET_STATUS" }, (response) => {
    loading.style.display = "none";

    if (response && response.loggedIn) {
      showDashboard(response.user);
    } else {
      loginView.style.display = "block";
    }
  });

  loginForm.addEventListener("submit", (e) => {
    e.preventDefault();
    loginError.style.display = "none";
    loginBtn.disabled = true;
    loginBtn.textContent = "Logging in...";

    chrome.runtime.sendMessage(
      {
        type: "LOGIN",
        email: emailInput.value.trim(),
        password: passwordInput.value,
      },
      (response) => {
        loginBtn.disabled = false;
        loginBtn.textContent = "Log in";

        if (response && response.ok) {
          loginView.style.display = "none";
          showDashboard(response.user);
        } else {
          loginError.textContent = response?.error || "Login failed";
          loginError.style.display = "block";
        }
      }
    );
  });

  function showDashboard(user) {
    dashboard.style.display = "block";
    document.getElementById("user-email").textContent = user.email;

    chrome.storage.local.get(["settings"], (data) => {
      const settings = data.settings || {};
      toggleEnabled.checked = settings.enabled !== false;
      languageSelect.value = settings.languagePair || user.target_language || "en-es";
    });

    loadStats();
    loadServerUrl();
  }

  function loadServerUrl() {
    chrome.runtime.sendMessage({ type: "GET_SERVER_URL" }, (response) => {
      if (response && response.ok) serverUrlInput.value = response.serverUrl;
    });
  }

  function showServerMsg(text, kind) {
    serverMsg.textContent = text;
    serverMsg.className = `server-msg ${kind}`;
    serverMsg.style.display = "block";
  }

  // Pointing the extension at another backend needs host access to it, and
  // Chrome only grants an optional permission from a user gesture — which is
  // why this lives behind the Save button rather than firing as you type.
  serverSaveBtn.addEventListener("click", () => {
    const raw = serverUrlInput.value.trim();
    let origin;

    try {
      const parsed = new URL(raw);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        throw new Error("protocol");
      }
      origin = `${parsed.origin}/*`;
    } catch (err) {
      showServerMsg("Enter a full URL, e.g. https://linguaswap.example.com", "err");
      return;
    }

    chrome.permissions.request({ origins: [origin] }, (granted) => {
      if (chrome.runtime.lastError || !granted) {
        showServerMsg("Access to that server was not granted", "err");
        return;
      }

      chrome.runtime.sendMessage({ type: "SET_SERVER_URL", serverUrl: raw }, (response) => {
        if (response && response.ok) {
          serverUrlInput.value = response.serverUrl;
          showServerMsg("Saved. Reload open tabs to pick it up.", "ok");
        } else {
          showServerMsg("Could not save that server", "err");
        }
      });
    });
  });

  function loadStats() {
    chrome.runtime.sendMessage({ type: "GET_STATS" }, (response) => {
      if (response && response.ok) {
        document.getElementById("stat-total").textContent = response.stats.total_words;
        document.getElementById("stat-hard").textContent = response.stats.hard_words;
        document.getElementById("stat-simple").textContent = response.stats.simple_words;
        document.getElementById("stat-trivial").textContent = response.stats.trivial_words;
      }
    });
  }

  toggleEnabled.addEventListener("change", () => {
    const enabled = toggleEnabled.checked;
    saveSettings({ enabled });

    chrome.tabs.query({}, (tabs) => {
      for (const tab of tabs) {
        chrome.tabs.sendMessage(tab.id, {
          type: "TOGGLE_ENABLED",
          enabled,
        }, () => { if (chrome.runtime.lastError) { /* ignore */ } });
      }
    });
  });

  languageSelect.addEventListener("change", () => {
    const languagePair = languageSelect.value;
    saveSettings({ languagePair });

    chrome.storage.local.get("user", (data) => {
      if (data.user) {
        data.user.target_language = languagePair.split("-")[1];
        chrome.storage.local.set({ user: data.user });
      }
    });

    chrome.tabs.query({}, (tabs) => {
      for (const tab of tabs) {
        chrome.tabs.sendMessage(tab.id, {
          type: "SETTINGS_CHANGED",
          languagePair,
          enabled: toggleEnabled.checked,
        }, () => { if (chrome.runtime.lastError) { /* ignore */ } });
      }
    });
  });

  function saveSettings(overrides) {
    chrome.storage.local.get(["settings"], (data) => {
      const settings = {
        ...(data.settings || {}),
        ...overrides,
      };
      chrome.storage.local.set({ settings });
    });
  }

  logoutBtn.addEventListener("click", () => {
    chrome.runtime.sendMessage({ type: "LOGOUT" }, () => {
      dashboard.style.display = "none";
      loginView.style.display = "block";
      emailInput.value = "";
      passwordInput.value = "";
    });
  });

  dashboardLink.addEventListener("click", () => {
    chrome.runtime.sendMessage({ type: "GET_SERVER_URL" }, (response) => {
      const base = (response && response.ok && response.serverUrl) || "http://localhost:4000";
      chrome.tabs.create({ url: `${base}/dashboard` });
    });
  });
});
