const ANSI_ESCAPE = /\x1b\[[0-9;]*m/g;

const NOISE_LINE_REGEXES: RegExp[] = [
  /^\s*##\[(group|endgroup|debug)\]/,
  /^\s*\[command\]/,
  /Cache (?:hit|restored|saved)/i,
  /Pulling from \S+/,
  /Digest:\s+sha256:/,
  /Status: (?:Downloaded newer image|Image is up to date)/,
  /^\s*[a-f0-9]{12}: Pulling fs layer/,
  /Post-run cleanup/,
  /Post job cleanup\./,
  /Setting up Node\.js/,
  /FATAL:.*password authentication failed for user "postgres"/i,
];

export function stripLogNoise(raw: string): string {
  return raw
    .split("\n")
    .map((l) => l.replace(ANSI_ESCAPE, ""))
    .filter((l) => !NOISE_LINE_REGEXES.some((r) => r.test(l)))
    .join("\n");
}

const NOISE_FILE_REGEXES: RegExp[] = [
  /(?:^|\/)(?:package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lock[b]?|Gemfile\.lock|Cargo\.lock|poetry\.lock|composer\.lock|Podfile\.lock)$/i,
  /\.lock$/,
  /\.min\.(?:js|css)$/,
  /\.map$/,
  /\.(?:png|jpe?g|gif|webp|ico|svg|pdf|zip|tar|t?gz|mp4|mov|mp3|wav|ttf|woff2?|eot|bin|dat|db|sqlite|ipa|apk|dmg)$/i,
  /(?:^|\/)(?:node_modules|vendor|dist|build|\.build|out|target|DerivedData|\.next|\.nuxt|coverage)\//,
  /\.xcassets\//,
];

export function filterNoisyFilenames(files: string[]): string[] {
  return files.filter((f) => !NOISE_FILE_REGEXES.some((r) => r.test(f)));
}
