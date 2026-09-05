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

  // Swaps actually made on this page, keyed by dictionary entry. Reported in
  // one batch so the backend can count real exposure instead of crediting every
  // active word on every page visit.
  let swapCounts = Object.create(null);
  let reportedEntries = new Set();
  let swapReportTimer = null;

  // How the tokenizer is allowed to treat this page, resolved from what the API
  // sent with the dictionary. `maxPhraseTokens` is the longest phrase entry the
  // user actually has, so a dictionary of single words costs nothing to walk;
  // `maxDensity` is the share of each sentence that may be swapped, which is a
  // learning setting and therefore the server's to decide.
  let swapOptions = { maxPhraseTokens: 1, maxDensity: null };

  // Long enough to let the second walk and the first mutation batch land, so a
  // page reports once rather than three times.
  const SWAP_REPORT_DELAY = 2500;

  // Set to true to trace the YouTube title pipeline in the console.
  const DEBUG = false;

  const SKIP_TAGS = new Set([
    "SCRIPT", "STYLE", "TEXTAREA", "INPUT", "SELECT",
    "CODE", "PRE", "SVG", "MATH", "IFRAME",
    "NOSCRIPT", "BR", "HR",
  ]);

  const SKIP_CLASSES = /linguaswap|CodeMirror|hljs/;

  // Lemmatization, the proper-noun guard, and the punctuation/casing helpers
  // live in lemmatizer.js, which the manifest loads before this file.
  const tokens = globalThis.LinguaSwapLemmatizer;

  if (DEBUG) console.log("LinguaSwap content script loaded (title-fix v2)");

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

    // YouTube re-renders <yt-formatted-string> and re-adds is-empty="" on nodes
    // whose text we set directly, hiding our translated title. Clear it eagerly
    // whenever it appears on an element that actually has content.
    for (const mutation of mutations) {
      if (mutation.type === "attributes" && mutation.attributeName === "is-empty") {
        clearIsEmpty(mutation.target);
      }
    }

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
    attributes: true,
    attributeFilter: ["is-empty"],
  });

  function clearIsEmpty(el) {
    if (!el || el.nodeType !== Node.ELEMENT_NODE) return;
    if (!el.hasAttribute("is-empty")) return;
    if (!el.textContent || !el.textContent.trim()) return;
    el.removeAttribute("is-empty");
  }

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
    // A YouTube navigation is a new page: whatever it shows counts again.
    flushSwapReport();
    resetSwapReport();

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

  function resetTitleBeforeNavigation() {
    // YouTube reuses the same h1 DOM node across SPA navigations. Before it
    // re-renders the title for the next video, restore whatever we last wrote
    // back to the pristine original. Otherwise YouTube APPENDS the new video's
    // title onto our leftover translated text node, producing a combined title.
    if (titleCheckTimer) {
      clearTimeout(titleCheckTimer);
      titleCheckTimer = null;
    }

    const el = findTitle();
    if (!el) return;
    
    // Try to reset to original. Even if this fails (race condition where YouTube
    // already appended), the stripping logic in translateTitle will handle it.
    if (lastOriginalTitle && el.textContent === lastRenderedTitle) {
      el.textContent = lastOriginalTitle;
      tlog("reset to original before navigation:", lastOriginalTitle);
    }
    
    delete el.dataset.lsOriginal;
    delete el.dataset.lsTranslated;
    delete el.dataset.lsHover;
    
    // Keep lastRenderedTitle/lastOriginalTitle so the stripping logic can work.
    // They will be cleared after successfully handling the new video's title.
  }

  window.addEventListener("yt-navigate-start", resetTitleBeforeNavigation);
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

        // Two passes so a spelling always beats a lemma: several entries can
        // share a lemma, and the API sends them in frequency order.
        const entries = [];
        let longestPhrase = 1;

        for (const w of response.words) {
          const entry = {
            translation: w.translation,
            status: w.status,
            original: w.original,
            lemma: normalizeKey(w.lemma || w.original),
          };
          entries.push(entry);

          // A phrase entry is keyed exactly as the tokenizer will ask for it:
          // its words joined by single spaces, lowercased.
          const surface = normalizeKey(w.original);
          if (!wordMap[surface]) wordMap[surface] = entry;
          longestPhrase = Math.max(longestPhrase, phraseLength(w));
        }
        for (const entry of entries) {
          if (!wordMap[entry.lemma]) wordMap[entry.lemma] = entry;
        }

        swapOptions = {
          maxPhraseTokens: longestPhrase,
          maxDensity: resolveDensity(response.swap),
        };

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

  // Handed to the tokenizer, which walks candidate base forms for each page
  // token until one of them is in the user's dictionary.
  function lookupCandidate(candidate) {
    return wordMap[candidate] || null;
  }

  // The dictionary is keyed on single-spaced lowercase text, so a phrase entry
  // stored with odd spacing still answers the tokenizer's lookup.
  function normalizeKey(word) {
    return String(word || "").trim().toLowerCase().replace(/\s+/g, " ");
  }

  // `token_count` comes from the server, which derives it from the entry
  // itself; splitting is the fallback for a server too old to send it.
  function phraseLength(word) {
    if (Number.isInteger(word.token_count) && word.token_count > 0) return word.token_count;
    return normalizeKey(word.original).split(" ").length;
  }

  // A server that does not send a density still gets one: an uncapped page is
  // the pidgin the cap exists to prevent, so the shared default stands in.
  function resolveDensity(swap) {
    const value = swap && Number(swap.max_density);
    if (Number.isFinite(value) && value >= 0) return value;
    return tokens.DEFAULT_MAX_DENSITY;
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

    const { parts, matched } = tokens.segmentText(text, lookupCandidate, swapOptions);
    if (!matched) return null;

    // A translated title is exposure like any other swap. The title watchers
    // re-run this on the same text, which is harmless: an entry is only ever
    // reported once per page.
    for (const part of parts) {
      if (part.type === "swap") noteSwap(part.entry.original);
    }

    return tokens.renderParts(parts);
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
  let titleMutationObserver = null;
  let titleDebounceTimer = null;

  function scheduleTitleCheck() {
    if (titleCheckTimer) return;
    titleCheckTimer = setTimeout(() => {
      titleCheckTimer = null;
      translateTitle();
    }, 300);
  }

  function watchTitleElement(el) {
    // Stop watching previous element
    if (titleMutationObserver) {
      titleMutationObserver.disconnect();
      titleMutationObserver = null;
    }
    
    if (!el) return;
    
    // Watch for YouTube mutating the title text
    titleMutationObserver = new MutationObserver(() => {
      // Debounce: wait for YouTube to finish mutating (500ms of silence)
      if (titleDebounceTimer) clearTimeout(titleDebounceTimer);
      titleDebounceTimer = setTimeout(() => {
        titleDebounceTimer = null;
        tlog("title mutations settled, translating");
        translateTitle();
      }, 500);
    });
    
    titleMutationObserver.observe(el, {
      childList: true,
      characterData: true,
      subtree: true
    });
  }

  // Trace logging for the title pipeline. Behind a flag we can flip to true
  // once, so we do not spam the console in normal operation.
  let titleDebug = DEBUG;

  function tlog(...args) {
    if (titleDebug) console.log("LS-TITLE", ...args);
  }

  // The last translated / original title strings we wrote into
  // {@link titleElement}. They survive navigation even though {...} DOM data-*
  // attributes are wiped on the reused h1, so we can tell "text left behind on
  // the previous video" apart from a freshly-rendered title for the current one.
  let lastRenderedTitle = null;
  let lastOriginalTitle = null;

  function translateTitle() {
    const el = findTitle();
    
    // Set up observer on new title element
    if (el !== titleElement) {
      titleElement = el;
      watchTitleElement(el);
    }
    
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

    // YouTube reuses the same node across SPA navigations and APPENDS the newly
    // rendered title onto whatever text we left behind (translated or original).
    // Strip that stale prefix so we only handle the actual new title.
    let effective = current;
    let stripped = false;

    if (lastRenderedTitle && effective !== lastRenderedTitle && effective.startsWith(lastRenderedTitle)) {
      effective = effective.slice(lastRenderedTitle.length).trim();
      stripped = true;
      tlog("stripped translated prefix ->", effective);
    } else if (lastOriginalTitle && effective !== lastOriginalTitle && effective.startsWith(lastOriginalTitle)) {
      effective = effective.slice(lastOriginalTitle.length).trim();
      stripped = true;
      tlog("stripped original prefix ->", effective);
    }

    if (vid !== currentTitleVideoId) {
      currentTitleVideoId = vid;
      tlog("video changed ->", vid, "current=", current, "last=", lastRenderedTitle);
      // The reused h1 may still hold the previous video's text, either as our
      // own translated output or as YouTube's untouched original. Accept the
      // node only once it differs from BOTH, otherwise wait for fresh content.
      if (current === lastRenderedTitle || current === lastOriginalTitle) {
        tlog("still showing previous video content, wait");
        scheduleTitleCheck();
        return;
      }

      const target = effective || current;
      const translated = translateString(target);
      tlog("new-video translate", { current, effective, translated });
      if (translated || stripped) {
        writeTitle(el, target, translated || target);
      }
      return;
    }

    if (current === lastRenderedTitle) {
      tlog("already rendered, skip");
      return;
    }

    const target = effective || current;
    const translated = translateString(target);
    tlog("same-video translate", { current, effective, translated });
    if (!translated && !stripped) return;

    writeTitle(el, target, translated || target);
  }

  function writeTitle(el, original, translated) {
    lastRenderedTitle = translated;
    lastOriginalTitle = original;
    
    // Temporarily disconnect observer so we don't trigger on our own write
    const wasObserving = titleMutationObserver !== null;
    if (wasObserving && titleMutationObserver) {
      titleMutationObserver.disconnect();
    }
    
    el.textContent = translated;
    // YouTube's <yt-formatted-string> toggles the `is-empty` attribute itself
    // when it fills the title; writing textContent directly bypasses that, which
    // leaves the element marked empty and YouTube hides it (blank title). Clear
    // it whenever we write, so the title is actually rendered.
    el.removeAttribute("is-empty");
    tlog("WROTE title:", translated, "(orig:", original + ")");

    if (el.dataset.lsOriginal !== original || el.dataset.lsTranslated !== translated) {
      el.dataset.lsOriginal = original;
      el.dataset.lsTranslated = translated;
      attachTitleHover(el);
    }
    
    // Reconnect observer to watch for YouTube's changes
    if (wasObserving) {
      watchTitleElement(el);
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

  function isInsideTitle(node) {
    if (node === titleElement) return true;
    let el = node.nodeType === Node.TEXT_NODE ? node.parentNode : node;
    while (el && el.nodeType === Node.ELEMENT_NODE) {
      if (el === titleElement) return true;
      // Title lives under an <h1> carrying the "title" class. Guard by selector
      // too, so the body word-walker never touches it even while `titleElement`
      // is stale (reused node) or not yet found during SPA navigation.
      if (el.tagName === "H1" && el.classList && el.classList.contains("title")) {
        return true;
      }
      el = el.parentNode;
    }
    return false;
  }

  function walkAndReplace(node) {
    if (!node || !enabled) return;

    if (node.nodeType === Node.ELEMENT_NODE) {
      if (isInsideTitle(node)) return;
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
    if (isInsideTitle(textNode)) return;

    const text = textNode.textContent;
    const { parts, matched } = tokens.segmentText(text, lookupCandidate, swapOptions);

    const fragments = [];

    for (const part of parts) {
      if (part.type !== "swap") {
        fragments.push(document.createTextNode(part.text));
        continue;
      }

      // Punctuation stays outside the span, so the span holds exactly the word
      // and hover can swap it back without disturbing the sentence.
      if (part.prefix) fragments.push(document.createTextNode(part.prefix));
      fragments.push(createReplacementSpan(part));
      if (part.suffix) fragments.push(document.createTextNode(part.suffix));
    }

    if (matched) {
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

  function createReplacementSpan(part) {
    const wordData = part.entry;
    const cleanWord = part.core;
    const span = document.createElement("span");
    span.className = "linguaswap-word";
    span.dataset.linguaswap = "true";
    // The word as it appeared on the page, which is what hover reveals and
    // what gets restored when replacements are removed.
    span.dataset.original = cleanWord;
    span.dataset.originalLower = cleanWord.toLowerCase();
    // The dictionary entry behind it. After lemmatization the two differ
    // ("running" vs "run"), and the API only knows the entry.
    span.dataset.entry = wordData.original;
    span.dataset.translation = part.display;
    span.dataset.status = wordData.status;

    span.textContent = part.display;

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
          word: wordData.original,
          languagePair,
        });
      }
    });

    span.addEventListener("mouseleave", () => {
      if (revealed) {
        revealed = false;
        span.classList.remove("ls-revealed");
        span.textContent = span.dataset.displayText || part.display;
      }
    });

    span.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      showRatingPopup(span, wordData);
    });

    replacementCount++;
    noteSwap(wordData.original);
    return span;
  }

  // The entry behind a swap, not the surface form: the API resolves dictionary
  // spellings, and lemmatizing page text is this side's job.
  function noteSwap(entry) {
    // Each entry is reported once per page. A word met twice in an article is
    // still one encounter, and the report is what drives promotion.
    if (!entry || reportedEntries.has(entry)) return;
    swapCounts[entry] = (swapCounts[entry] || 0) + 1;

    if (swapReportTimer) clearTimeout(swapReportTimer);
    swapReportTimer = setTimeout(flushSwapReport, SWAP_REPORT_DELAY);
  }

  function flushSwapReport() {
    if (swapReportTimer) {
      clearTimeout(swapReportTimer);
      swapReportTimer = null;
    }

    const words = Object.keys(swapCounts).map((word) => ({
      word,
      count: swapCounts[word],
    }));
    if (words.length === 0) return;

    for (const { word } of words) reportedEntries.add(word);
    swapCounts = Object.create(null);

    safeSendMessage({ type: "RECORD_REPLACEMENTS", words, languagePair });
  }

  function resetSwapReport() {
    if (swapReportTimer) {
      clearTimeout(swapReportTimer);
      swapReportTimer = null;
    }
    swapCounts = Object.create(null);
    reportedEntries = new Set();
  }

  function showRatingPopup(span, wordData) {
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
        rateWord(span, wordData, btn.status);
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

  function rateWord(span, wordData, status) {
    span.dataset.status = status;

    updateSpanStatusClass(span, status);

    // The same entry object sits under both its spelling and its lemma key, so
    // mutating it here updates every way the word can be looked up.
    wordData.status = status;

    // Every surface form on the page that resolved to this entry moves too:
    // rating "running" easy also settles "runs" and "ran".
    const entry = wordData.original.replace(/["\\]/g, "\\$&");
    const all = document.querySelectorAll(`span.linguaswap-word[data-entry="${entry}" i]`);
    for (const el of all) {
      if (el !== span) {
        el.dataset.status = status;
        updateSpanStatusClass(el, status);
      }
    }

    safeSendMessage({
      type: "RATE_WORD",
      word: wordData.original,
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
    lastOriginalTitle = null;
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
      flushSwapReport();
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

  // beforeunload does not always fire; a hidden tab is the reliable signal.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") flushSwapReport();
  });
})();
