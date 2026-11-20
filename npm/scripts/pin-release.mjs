// Points the package at a GitHub release: downloads its Tally.zip, hashes it and writes release.json.
//   npm run pin -- v1.4
// Then bump "version" in package.json to match (1.4.0) and publish.
import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";

const tag = process.argv[2];
if (!/^v\d+(\.\d+)*$/.test(tag || "")) { console.error("usage: npm run pin -- v1.4"); process.exit(1); }

const url = `https://github.com/PratikRai0101/tally/releases/download/${tag}/Tally.zip`;
const res = await fetch(url);
if (!res.ok) { console.error(`HTTP ${res.status} for ${url}`); process.exit(1); }
const buf = Buffer.from(await res.arrayBuffer());
const release = { version: tag.slice(1), url, sha256: createHash("sha256").update(buf).digest("hex") };

writeFileSync(new URL("../release.json", import.meta.url), JSON.stringify(release, null, 2) + "\n");
console.log(`release.json → Tally ${release.version}, ${(buf.length / 1e6).toFixed(1)} MB, sha256 ${release.sha256}`);
