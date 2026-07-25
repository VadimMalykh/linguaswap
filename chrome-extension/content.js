(() => {
  "use strict";

  let enabled = true;
  let languagePair = "en-es";
  let wordMap = {};
  let replacementCount = 0;
  let startTime = Date.now();
  let processedNodes = new WeakSet();

  const SKIP_TAGS = new Set([
    "SCRIPT", "STYLE", "TEXTAREA", "INPUT", "SELECT",
    "CODE", "PRE", "SVG", "MATH", "IFRAME",
    "NOSCRIPT", "BR", "HR",
  ]);

  const SKIP_CLASSES = /linguaswap|CodeMirror|hljs/;

  chrome.runtime.sendMessage({ type: "GET_STATUS" }, (response) => {
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
      cachedWords = null;

      if (!enabled) {
        removeAllReplacements();
      } else {
        loadWordsAndReplace();
      }
    }
  });

  function loadWordsAndReplace() {
    chrome.runtime.sendMessage(
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
        reportPageVisit();
      }
    );
  }

  function walkAndReplace(node) {
    if (!node || !enabled) return;

    if (node.nodeType === Node.ELEMENT_NODE) {
      if (SKIP_TAGS.has(node.tagName)) return;
      if (node.classList && SKIP_CLASSES.test(node.className)) return;
      if (node.isContentEditable) return;
      if (node.dataset && node.dataset.linguaswap) return;

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

      for (const frag of fragments) {
        parent.insertBefore(frag, textNode);
      }
      parent.removeChild(textNode);
      processedNodes.add(textNode);
    }
  }

  function createReplacementSpan(originalText, cleanWord, wordData) {
    const span = document.createElement("span");
    span.className = "linguaswap-word";
    span.dataset.linguaswap = "true";
    span.dataset.original = cleanWord;
    span.dataset.translation = wordData.translation;
    span.dataset.status = wordData.status;

    span.textContent = wordData.translation;

    if (wordData.status === "new") {
      span.classList.add("ls-status-new");
    } else if (wordData.status === "learning") {
      span.classList.add("ls-status-learning");
    } else {
      span.classList.add("ls-status-known");
    }

    let revealed = false;

    span.addEventListener("mouseenter", () => {
      if (!revealed) {
        revealed = true;
        span.classList.add("ls-revealed");
        span.dataset.displayText = span.textContent;
        span.textContent = cleanWord;

        chrome.runtime.sendMessage({
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

    replacementCount++;
    return span;
  }

  function removeAllReplacements() {
    const replacements = document.querySelectorAll("span.linguaswap-word");
    for (const span of replacements) {
      const parent = span.parentNode;
      if (!parent) continue;

      const textNode = document.createTextNode(span.textContent);
      parent.replaceChild(textNode, span);
      parent.normalize();
    }
  }

  let visitTimer = null;

  function reportPageVisit() {
    if (visitTimer) clearInterval(visitTimer);

    visitTimer = setInterval(() => {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      if (replacementCount > 0 && elapsed >= 5) {
        chrome.runtime.sendMessage({
          type: "RECORD_PAGE_VISIT",
          url: window.location.href,
          wordsReplaced: replacementCount,
          timeSpent: elapsed,
        });
      }
    }, 30000);

    window.addEventListener("beforeunload", () => {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      if (replacementCount > 0) {
        navigator.sendBeacon(
          "about:blank",
          JSON.stringify({
            type: "PAGE_LEAVE",
            url: window.location.href,
            wordsReplaced: replacementCount,
            timeSpent: elapsed,
          })
        );

        chrome.runtime.sendMessage({
          type: "RECORD_PAGE_VISIT",
          url: window.location.href,
          wordsReplaced: replacementCount,
          timeSpent: elapsed,
        });
      }
    });
  }
})();
