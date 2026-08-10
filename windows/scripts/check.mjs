import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const files = walk(path.join(root, "src")).filter((file) => /\.(?:c?js|mjs)$/u.test(file));
files.push(...walk(path.join(root, "scripts")).filter((file) => /\.(?:c?js|mjs)$/u.test(file)));
files.push(...walk(path.join(root, "test")).filter((file) => /\.(?:c?js|mjs)$/u.test(file)));

for (const file of files) {
  const result = spawnSync(process.execPath, ["--check", file], { encoding: "utf8" });
  if (result.status !== 0) {
    process.stderr.write(result.stderr);
    process.exit(result.status ?? 1);
  }
}
console.log(`Checked ${files.length} JavaScript files.`);

function walk(directory) {
  return readdirSync(directory).flatMap((entry) => {
    const file = path.join(directory, entry);
    return statSync(file).isDirectory() ? walk(file) : [file];
  });
}
