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
  let titleElement = null;
  let currentTitleVideoId = null;

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

    if (window.location.href !== lastUrl) {
      lastUrl = window.location.href;
      pendingMutations = [];
      if (mutationTimer) clearTimeout(mutationTimer);
      handleNavigation();
      return;
    }

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

    translateTitle();

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
      translateTitle();
      walkAndReplace(document.body);
      setTimeout(() => {
        translateTitle();
        walkAndReplace(document.body);
      }, 800);
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

        translateTitle();
        walkAndReplace(document.body);
        setTimeout(() => {
          translateTitle();
          walkAndReplace(document.body);
        }, 1500);
        reportPageVisit();
      }
    );
  }

  function findTitle() {
    return (
      document.querySelector(
        "h1.title.ytd-watch-metadata yt-formatted-string, " +
          "#title h1 yt-formatted-string, " +
          "h1.title yt-formatted-string"
      ) || null
    );
  }

  function translateString(text) {
    if (!text) return null;

    const words = text.split(/(\s+)/);
    let changed = false;
    const out = [];

    for (const segment of words) {
      if (/^\s+$/.test(segment)) {
        out.push(segment);
        continue;
      }

      const clean = segment.replace(/[^\w']/g, "");
      const lower = clean.toLowerCase();

      if (wordMap[lower]) {
        out.push(wordMap[lower].translation);
        changed = true;
      } else {
        out.push(segment);
      }
    }

    return changed ? out.join("") : null;
  }

  function getVideoId() {
    try {
      const url = new URL(window.location.href);
      const v = url.searchParams.get("v");
      if (v) return v;
      const m = url.pathname.match(/^\/(shorts|live|embed)\/([^/]+)/);
      if (m) return m[2];
    } catch (err) {
      // ignore
    }
    return window.location.pathname + window.location.search;
  }

  let titleCheckTimer = null;
  let titleCheckCount = 0;

  function scheduleTitleCheck() {
    if (titleCheckTimer) return;
    titleCheckTimer = setTimeout(() => {
      titleCheckTimer = null;
      translateTitle();
    }, 300);
  }

  // Trace logging for the title pipeline. Behind a flag we can flip to true
  // once, so we do not spam the console in normal operation.
  let titleDebug = true;

  function tlog(...args) {
    if (titleDebug) console.log("LS-TITLE", ...args);
  }

  // The last translated title string we wrote into {@link titleElement}. Survives
  // navigation even though {...} DOM data-* attributes are wiped on the reused h1.
  // Used to tell "stale text we left behind on the previous video" apart from a
  // freshly-rendered original title for the current video.
  let lastRenderedTitle = null;

  function translateTitle() {
    const el = findTitle();
    titleElement = el;
    if (!el) {
      tlog("no title element");
      return;
    }

    const vid = getVideoId();
    const current = (el.textContent || "").trim();
    tlog("enter", { vid, currentTitleVideoId, current, lastRenderedTitle });

    if (!current) {
      tlog("empty, wait");
      scheduleTitleCheck();
      return;
    }

    if (vid !== currentTitleVideoId) {
      currentTitleVideoId = vid;
      tlog("video changed ->", vid, "current=", current, "last=", lastRenderedTitle);
      if (current === lastRenderedTitle) {
        tlog("still showing previous render, wait");
        scheduleTitleCheck();
        return;
      }

      const translated = translateString(current);
      tlog("new-video translate", { current, translated });
      if (translated) {
        writeTitle(el, current, translated);
      }
      return;
    }

    if (current === lastRenderedTitle) {
      tlog("already rendered, skip");
      return;
    }

    const translated = translateString(current);
    tlog("same-video translate", { current, translated });
    if (!translated) return;

    writeTitle(el, current, translated);
  }

  function writeTitle(el, original, translated) {
    lastRenderedTitle = translated;
    el.textContent = translated;
    tlog("WROTE title:", translated, "(orig:", original + ")");

    if (el.dataset.lsOriginal !== original || el.dataset.lsTranslated !== translated) {
      el.dataset.lsOriginal = original;
      el.dataset.lsTranslated = translated;
      attachTitleHover(el);
    }
  }

  function attachTitleHover(el) {
    if (el.dataset.lsHover) return;
    el.dataset.lsHover = "1";
    el.addEventListener("mouseenter", () => {
      if (el.textContent === el.dataset.lsTranslated && el.dataset.lsOriginal) {
        el.textContent = el.dataset.lsOriginal;
      }
    });
    el.addEventListener("mouseleave", () => {
      if (el.textContent === el.dataset.lsOriginal && el.dataset.lsTranslated) {
        el.textContent = el.dataset.lsTranslated;
      }
    });
  }

  function isPlainWrapped(node) {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) continue;
      if (
        child.nodeType === Node.ELEMENT_NODE &&
        child.classList &&
        child.classList.contains("linguaswap-word")
      ) {
        continue;
      }
      return false;
    }
    return true;
  }

  function restoreWordSpans(node) {
    const spans = node.querySelectorAll("span.linguaswap-word");
    for (const span of spans) {
      const parent = span.parentNode;
      if (!parent) continue;
      const textNode = document.createTextNode(span.dataset.original || span.textContent);
      parent.replaceChild(textNode, span);
    }
  }

  function walkAndReplace(node) {
    if (!node || !enabled) return;

    if (node.nodeType === Node.ELEMENT_NODE) {
      if (node === titleElement) return;
      if (SKIP_TAGS.has(node.tagName)) return;
      if (node.classList && SKIP_CLASSES.test(node.className)) return;
      if (node.isContentEditable) return;
      if (node.dataset && node.dataset.linguaswap) return;

      const snapshot = wrappedContainers.get(node);
      if (snapshot !== undefined && node.textContent !== snapshot) {
        restoreWordSpans(node);
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
    if (textNode.parentNode === titleElement) return;

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

      for (const frag of fragments) {
        parent.insertBefore(frag, textNode);
      }
      parent.removeChild(textNode);
      processedNodes.add(textNode);

      if (isPlainWrapped(parent)) {
        wrappedContainers.set(parent, parent.textContent);
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
    const replacements = document.querySelectorAll("span.linguaswap-word");
    for (const span of replacements) {
      const parent = span.parentNode;
      if (!parent) continue;

      const textNode = document.createTextNode(span.dataset.original || span.textContent);
      parent.replaceChild(textNode, span);
      parent.normalize();
    }

    const title = findTitle();
    if (title && title.dataset.lsOriginal) {
      title.textContent = title.dataset.lsOriginal;
    }
    if (title) {
      delete title.dataset.lsOriginal;
      delete title.dataset.lsTranslated;
      delete title.dataset.lsHover;
    }

    lastRenderedTitle = null;
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
