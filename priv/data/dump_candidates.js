// Dumps candidates() for every word in a corpus list, so the Python port in
// build_dictionary.py can be diffed against the real lemmatizer. See the
// "Relationship to chrome-extension/lemmatizer.js" note in that file.
const fs = require("fs");
const lem = require("../../chrome-extension/lemmatizer.js");

const words = fs
  .readFileSync(process.argv[2], "utf8")
  .trim()
  .split("\n")
  .map((line) => line.split(" ")[0])
  .filter((w) => /^[a-z]+$/.test(w || ""));

const out = {};
for (const w of words) out[w] = lem.candidates(w);

fs.writeFileSync(process.argv[3], JSON.stringify(out));
console.log(`dumped ${Object.keys(out).length} candidate lists`);
