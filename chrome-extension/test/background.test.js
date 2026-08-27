const test = require("node:test");
const assert = require("node:assert");

// background.js registers a message listener as soon as it loads, so the parts
// of the extension API it touches at import time have to exist first.
globalThis.chrome = {
  runtime: { onMessage: { addListener() {} } },
  storage: { local: { get: async () => ({}) } },
};

const { normalizeServerUrl, DEFAULT_SERVER_URL } = require("../background.js");

test("normalizeServerUrl keeps a plain origin as it is", () => {
  assert.strictEqual(normalizeServerUrl("http://localhost:4000"), "http://localhost:4000");
  assert.strictEqual(
    normalizeServerUrl("https://linguaswap.example.com"),
    "https://linguaswap.example.com"
  );
});

test("normalizeServerUrl absorbs trailing slashes", () => {
  assert.strictEqual(normalizeServerUrl("http://localhost:4000/"), "http://localhost:4000");
  assert.strictEqual(normalizeServerUrl("http://localhost:4000///"), "http://localhost:4000");
});

test("normalizeServerUrl absorbs a pasted API path", () => {
  // Copying the base out of the README is the likely mistake, and doubling it
  // into /api/v1/api/v1 would fail every request with a bare 404.
  assert.strictEqual(normalizeServerUrl("http://localhost:4000/api/v1"), "http://localhost:4000");
  assert.strictEqual(normalizeServerUrl("http://localhost:4000/api/v1/"), "http://localhost:4000");
});

test("normalizeServerUrl trims surrounding whitespace", () => {
  assert.strictEqual(normalizeServerUrl("  http://localhost:4000  "), "http://localhost:4000");
});

test("normalizeServerUrl returns empty for nothing usable, so the default wins", () => {
  for (const value of ["", "   ", null, undefined]) {
    assert.strictEqual(normalizeServerUrl(value), "");
  }
  assert.strictEqual(DEFAULT_SERVER_URL, "http://localhost:4000");
});
