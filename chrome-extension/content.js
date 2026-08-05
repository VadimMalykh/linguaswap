(() => {
  "use strict";

  let enabled = true;
  let languagePair = "en-es";
  let wordMap = {};
  let replacementCount = 0;
  let startTime = Date.now();
  let processedNodes = new WeakSet();
  let activePopup = null;
  let mutationTimer = null;

  const SKIP_TAGS = new Set([
    "SCRIPT", "STYLE", "TEXTAREA", "INPUT", "SELECT",
    "CODE", "PRE", "SVG", "MATH", "IFRAME",
    "NOSCRIPT", "BR", "HR",
  ]);

  const SKIP_CLASSES = /linguaswap|CodeMirror|hljs/;

  function safeSendMessage(message, callback) {
    try {
      if (callback) {
        chrome.runtime.sendMessage(message, callback);
      } else {
        chrome.runtime.sendMessage(message);
      }
    } catch (err) {
      // Extension context may be invalidated after a reload; ignore.
    }
  }

  safeSendMessage({ type: "GET_STATUS" }, (response) => {
    if (!response || !response.loggedIn) return;

    chrome.storage.local.get("settings", (data) => {
      const settings = data.settings || {};
      enabled = settings.enabled !== false;
      languagePair = settings.languagePair || "en-es";

      if (enabled) {
        loadWordsAndReplace();
      }
    });
  });

  let pendingMutations = [];
  let lastUrl = window.location.href;
  let wrappedContainers = new WeakMap();

  const observer = new MutationObserver((mutations) => {
    if (!enabled) return;
    pendingMutations = pendingMutations.concat(mutations);
    if (mutationTimer) clearTimeout(mutationTimer);
    mutationTimer = setTimeout(() => {
      try {
        const batch = pendingMutations;
        pendingMutations = [];
        syncChangedSubtrees(batch);
      } catch (err) {
        // Ignore DOM edge cases from arbitrary pages.
      }
    }, 400);
  });
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true,
  });

  function syncChangedSubtrees(mutations) {
    const containers = new Set();

    for (const mutation of mutations) {
      if (mutation.type === "characterData") {
        if (mutation.target.parentNode) {
          containers.add(mutation.target.parentNode);
        }
        continue;
      }

      if (mutation.type === "childList") {
        if (mutation.target && mutation.target.nodeType === Node.ELEMENT_NODE) {
          containers.add(mutation.target);
        }
        for (const node of mutation.addedNodes) {
          if (node.nodeType === Node.ELEMENT_NODE) {
            containers.add(node);
          }
        }
      }
    }

    if (window.location.href !== lastUrl) {
      lastUrl = window.location.href;
      startTime = Date.now();
      replacementCount = 0;
      containers.add(document.body);
    }

    for (const container of containers) {
      if (container && container.nodeType === Node.ELEMENT_NODE) {
        walkAndReplace(container);
      }
    }
  }

  let lastNavigationReset = 0;

  function handleNavigation() {
    if (!enabled) return;

    const now = Date.now();
    if (now - lastNavigationReset < 1500) return;
    lastNavigationReset = now;

    lastUrl = window.location.href;
    startTime = now;
    replacementCount = 0;

    try {
      walkAndReplace(document.body);
      setTimeout(() => walkAndReplace(document.body), 800);
    } catch (err) {
      // Ignore DOM edge cases from arbitrary pages.
    }
  }

  window.addEventListener("yt-navigate-finish", handleNavigation);
  window.addEventListener("popstate", handleNavigation);
  window.addEventListener("hashchange", handleNavigation);

  chrome.runtime.onMessage.addListener((message) => {
    if (message.type === "TOGGLE_ENABLED") {
      enabled = message.enabled;
      if (!enabled) {
        removeAllReplacements();
      } else {
        loadWordsAndReplace();
      }
    }

    if (message.type === "SETTINGS_CHANGED") {
      languagePair = message.languagePair || languagePair;
      enabled = message.enabled !== undefined ? message.enabled : enabled;

      if (!enabled) {
        removeAllReplacements();
      } else {
        loadWordsAndReplace();
      }
    }
  });

  function loadWordsAndReplace() {
    safeSendMessage(
      { type: "GET_WORDS", languagePair },
      (response) => {
        if (!response || !response.ok || !response.words) return;

        wordMap = {};
        for (const w of response.words) {
          wordMap[w.original.toLowerCase()] = {
            translation: w.translation,
            status: w.status,
            original: w.original,
          };
        }

        walkAndReplace(document.body);
        setTimeout(() => walkAndReplace(document.body), 1500);
        reportPageVisit();
      }
    );
  }

  function containerFingerprint(node) {
    let out = "";
    const childNodes = node.childNodes;
    for (let i = 0; i < childNodes.length; i++) {
      const child = childNodes[i];
      if (child.nodeType === Node.TEXT_NODE) {
        out += child.textContent;
      } else if (
        child.nodeType === Node.ELEMENT_NODE &&
        child.classList &&
        child.classList.contains("linguaswap-run")
      ) {
        out += child.dataset.originalFull || child.textContent;
      } else {
        out += child.textContent;
      }
    }
    return out;
  }

  function walkAndReplace(node) {
    if (!node || !enabled) return;

    if (node.nodeType === Node.ELEMENT_NODE) {
      if (SKIP_TAGS.has(node.tagName)) return;
      if (node.classList && SKIP_CLASSES.test(node.className)) return;
      if (node.isContentEditable) return;
      if (node.dataset && node.dataset.linguaswap) return;

      const snapshot = wrappedContainers.get(node);
      if (snapshot !== undefined && snapshot !== containerFingerprint(node)) {
        const stale = node.querySelectorAll("span.linguaswap-run");
        for (const run of stale) {
          if (run.parentNode) run.parentNode.removeChild(run);
        }
        wrappedContainers.delete(node);
      }

      const children = Array.from(node.childNodes);
      for (const child of children) {
        walkAndReplace(child);
      }
      return;
    }

    if (node.nodeType === Node.TEXT_NODE) {
      replaceWordsInTextNode(node);
    }
  }

  function replaceWordsInTextNode(textNode) {
    if (processedNodes.has(textNode)) return;
    if (!textNode.textContent.trim()) return;

    const text = textNode.textContent;
    const words = text.split(/(\s+)/);

    let hasMatch = false;
    const fragments = [];

    for (const segment of words) {
      if (/^\s+$/.test(segment)) {
        fragments.push(document.createTextNode(segment));
        continue;
      }

      const clean = segment.replace(/[^\w']/g, "");
      const lower = clean.toLowerCase();

      if (wordMap[lower]) {
        hasMatch = true;
        const wordData = wordMap[lower];
        const span = createReplacementSpan(segment, clean, wordData);
        fragments.push(span);
      } else {
        fragments.push(document.createTextNode(segment));
      }
    }

    if (hasMatch) {
      const parent = textNode.parentNode;
      if (!parent) return;

      const run = document.createElement("span");
      run.className = "linguaswap-run";
      run.dataset.linguaswap = "true";
      run.dataset.originalFull = text;
      for (const frag of fragments) {
        run.appendChild(frag);
      }

      parent.insertBefore(run, textNode);
      parent.removeChild(textNode);
      processedNodes.add(textNode);

      if (parent.childNodes.length === 1) {
        wrappedContainers.set(parent, containerFingerprint(parent));
      }
    }
  }

  function createReplacementSpan(originalText, cleanWord, wordData) {
    const span = document.createElement("span");
    span.className = "linguaswap-word";
    span.dataset.linguaswap = "true";
    span.dataset.original = cleanWord;
    span.dataset.originalLower = cleanWord.toLowerCase();
    span.dataset.translation = wordData.translation;
    span.dataset.status = wordData.status;

    span.textContent = wordData.translation;

    if (wordData.status === "hard") {
      span.classList.add("ls-status-hard");
    } else if (wordData.status === "simple") {
      span.classList.add("ls-status-simple");
    } else {
      span.classList.add("ls-status-trivial");
    }

    let revealed = false;

    span.addEventListener("mouseenter", () => {
      if (!revealed) {
        revealed = true;
        span.classList.add("ls-revealed");
        span.dataset.displayText = span.textContent;
        span.textContent = cleanWord;

        safeSendMessage({
          type: "RECORD_REVEAL",
          word: cleanWord,
          languagePair,
        });
      }
    });

    span.addEventListener("mouseleave", () => {
      if (revealed) {
        revealed = false;
        span.classList.remove("ls-revealed");
        span.textContent = span.dataset.displayText || wordData.translation;
      }
    });

    span.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      showRatingPopup(span, cleanWord);
    });

    replacementCount++;
    return span;
  }

  function showRatingPopup(span, word) {
    removeActivePopup();

    const popup = document.createElement("div");
    popup.className = "linguaswap-rating-popup";
    popup.dataset.linguaswap = "true";

    const buttons = [
      { status: "hard", label: "Hard", cls: "ls-btn-hard" },
      { status: "simple", label: "Simple", cls: "ls-btn-simple" },
      { status: "trivial", label: "Easy", cls: "ls-btn-trivial" },
    ];

    for (const btn of buttons) {
      const button = document.createElement("button");
      button.className = `ls-rate-btn ${btn.cls}`;
      button.textContent = btn.label;
      if (span.dataset.status === btn.status) {
        button.classList.add("ls-rate-active");
      }
      button.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        rateWord(span, word, btn.status);
      });
      popup.appendChild(button);
    }

    document.body.appendChild(popup);
    activePopup = popup;

    const rect = span.getBoundingClientRect();
    popup.style.left = `${rect.left + window.scrollX}px`;
    popup.style.top = `${rect.top + window.scrollY + rect.height + 4}px`;

    const hideHandler = (e) => {
      if (!popup.contains(e.target) && e.target !== span) {
        removeActivePopup();
        document.removeEventListener("click", hideHandler);
      }
    };
    setTimeout(() => document.addEventListener("click", hideHandler), 10);
  }

  function removeActivePopup() {
    if (activePopup && activePopup.parentNode) {
      activePopup.parentNode.removeChild(activePopup);
    }
    activePopup = null;
  }

  function rateWord(span, word, status) {
    span.dataset.status = status;

    updateSpanStatusClass(span, status);

    if (wordMap[word]) {
      wordMap[word].status = status;
    }

    const lower = word.toLowerCase();
    const all = document.querySelectorAll(`span.linguaswap-word[data-original="${lower}" i]`);
    for (const el of all) {
      if (el !== span) {
        el.dataset.status = status;
        updateSpanStatusClass(el, status);
      }
    }

    safeSendMessage({
      type: "RATE_WORD",
      word,
      languagePair,
      status,
    });

    removeActivePopup();
  }

  function updateSpanStatusClass(el, status) {
    el.classList.remove("ls-status-hard", "ls-status-simple", "ls-status-trivial");
    if (status === "hard") {
      el.classList.add("ls-status-hard");
    } else if (status === "simple") {
      el.classList.add("ls-status-simple");
    } else {
      el.classList.add("ls-status-trivial");
    }
  }

  function removeAllReplacements() {
    const runs = document.querySelectorAll("span.linguaswap-run");
    for (const run of runs) {
      const parent = run.parentNode;
      if (!parent) continue;

      const textNode = document.createTextNode(run.dataset.originalFull || run.textContent);
      parent.replaceChild(textNode, run);
      parent.normalize();
    }

    const replacements = document.querySelectorAll("span.linguaswap-word");
    for (const span of replacements) {
      const parent = span.parentNode;
      if (!parent) continue;

      const textNode = document.createTextNode(span.dataset.original || span.textContent);
      parent.replaceChild(textNode, span);
      parent.normalize();
    }

    wrappedContainers = new WeakMap();
  }

  let visitTimer = null;

  function reportPageVisit() {
    if (visitTimer) clearInterval(visitTimer);

    visitTimer = setInterval(() => {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      if (replacementCount > 0 && elapsed >= 5) {
        safeSendMessage({
          type: "RECORD_PAGE_VISIT",
          url: window.location.href,
          wordsReplaced: replacementCount,
          timeSpent: elapsed,
          languagePair,
        });
      }
    }, 30000);

    window.addEventListener("beforeunload", () => {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      if (replacementCount > 0) {
        safeSendMessage({
          type: "RECORD_PAGE_VISIT",
          url: window.location.href,
          wordsReplaced: replacementCount,
          timeSpent: elapsed,
          languagePair,
        });
      }
    });
  }
})();
