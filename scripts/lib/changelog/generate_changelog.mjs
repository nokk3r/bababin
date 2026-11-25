#!/usr/bin/env node
/** Generate Keep a Changelog release sections (ru + en) via Cursor SDK. */

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const CHANGELOG_DIR = dirname(fileURLToPath(import.meta.url));
const SCRIPTS_DIR = resolve(CHANGELOG_DIR, "../..");
const ROOT = process.env.ROOT ? resolve(process.env.ROOT) : resolve(SCRIPTS_DIR, "..");
const CHANGELOG_RU_PATH = join(ROOT, "CHANGELOG.md");
const CHANGELOG_EN_PATH = join(ROOT, process.env.CHANGELOG_EN || "CHANGELOG.en.md");
const BILINGUAL = ["1", "true", "yes"].includes((process.env.CHANGELOG_BILINGUAL ?? "0").toLowerCase());
const APP_DISPLAY_NAME = process.env.RELEASE_APP_NAME || process.env.APP_DISPLAY_NAME || "macOS App";
const ALLOWED_SECTIONS = {
  ru: new Set(["Добавлено", "Исправлено", "Изменено", "Улучшено"]),
  en: new Set(["Added", "Fixed", "Changed", "Improved"]),
};
const SECTION_HEADING = /^## \[(?<version>[^\]]+)\] - (?<releaseDate>\d{4}-\d{2}-\d{2})\s*$/;

function loadDotenvFile(path) {
  if (!existsSync(path)) return;
  for (const rawLine of readFileSync(path, "utf8").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || !line.includes("=")) continue;
    const eq = line.indexOf("=");
    const key = line.slice(0, eq).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue;
    if (process.env[key]) continue;
    let value = line.slice(eq + 1).trim();
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}

function loadDotenv() {
  // Secrets live in swift_scripts/.env; ROOT is the app repo.
  loadDotenvFile(join(SCRIPTS_DIR, ".env"));
  if (ROOT !== SCRIPTS_DIR) {
    loadDotenvFile(join(ROOT, ".env"));
  }
}

function cursorApiKey() {
  loadDotenv();
  return (process.env.CURSOR_API_KEY ?? "").trim();
}

function runGit(args) {
  const result = spawnSync("git", args, {
    cwd: ROOT,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    const message = (result.stderr || result.stdout || "").trim();
    throw new Error(message || `git ${args.join(" ")} failed`);
  }
  return (result.stdout ?? "").trim();
}

function previousReleaseRef() {
  const output = runGit(["log", "--grep=^Release ", "--format=%H", "-1"]);
  return output || null;
}

function collectGitLog(fromRef) {
  const args = ["log"];
  if (fromRef) args.push(`${fromRef}..HEAD`);
  args.push("--pretty=format:%h %s", "--no-merges");
  return runGit(args)
    .split(/\r?\n/)
    .filter((line) => {
      const subject = line.includes(" ") ? line.split(" ").slice(1).join(" ") : line;
      return subject && !subject.startsWith("Release ");
    })
    .join("\n");
}

function collectDiffStat(fromRef) {
  const args = ["diff", "--stat"];
  args.push(fromRef ? `${fromRef}..HEAD` : "HEAD");
  try {
    return runGit(args);
  } catch {
    return "";
  }
}

function stripCodeFences(text) {
  const stripped = text.trim();
  const match = stripped.match(/^```(?:markdown|md)?\s*\n?([\s\S]*?)\n?```$/);
  return match ? match[1].trim() : stripped;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function extractVersionSection(text, version) {
  const cleaned = stripCodeFences(text);
  const pattern = new RegExp(
    `(## \\[${escapeRegExp(version)}\\] - \\d{4}-\\d{2}-\\d{2}[\\s\\S]*?)(?=\\n## \\[|$)`,
  );
  const match = cleaned.match(pattern);
  if (match) return match[1].trim();
  if (cleaned.startsWith(`## [${version}]`)) return cleaned.trim();
  throw new Error(`Generated text does not contain section for version ${version}`);
}

function validateSection(section, version, lang) {
  const allowed = ALLOWED_SECTIONS[lang];
  const lines = section.split(/\r?\n/);
  if (!lines.length) throw new Error("Changelog section is empty");

  const heading = lines[0].match(SECTION_HEADING);
  if (!heading) throw new Error("Missing heading: ## [version] - YYYY-MM-DD");
  if (heading.groups.version !== version) {
    throw new Error(`Expected version ${version}, got ${heading.groups.version}`);
  }

  let currentSection = null;
  let seenBullet = false;
  const seenSections = new Set();

  for (const line of lines.slice(1)) {
    if (!line.trim()) continue;
    if (line.startsWith("### ")) {
      const title = line.slice(4).trim();
      if (!allowed.has(title)) throw new Error(`Unsupported section (${lang}): ${title}`);
      if (seenSections.has(title)) throw new Error(`Duplicate section: ${title}`);
      seenSections.add(title);
      currentSection = title;
      continue;
    }
    if (line.startsWith("- ")) {
      if (!currentSection) throw new Error("Bullet list outside a section");
      if (line.slice(2).trim().length < 3) throw new Error("Bullet item is too short");
      seenBullet = true;
      continue;
    }
    throw new Error(`Unexpected line: ${line}`);
  }

  if (!seenSections.size || !seenBullet) {
    throw new Error("Section must contain at least one category with bullet items");
  }
}

function buildPrompt(version, releaseDate, channel, gitLog, diffStat, lang) {
  if (lang === "en") {
    const channelNote =
      channel === "beta"
        ? "This is a beta release. Mention that in one bullet under “Changed” if appropriate."
        : "This is a stable release.";

    return `Generate a changelog section for the macOS app ${APP_DISPLAY_NAME}.

Version: ${version}
Release date: ${releaseDate}
Channel: ${channel}
${channelNote}

Use ONLY information from the git log and diff stat below. Do not invent changes.

Response format (strict):
## [${version}] - ${releaseDate}

### Added
- ...

### Fixed
- ...

### Changed
- ...

### Improved
- ...

Rules:
- Write in English, briefly and clearly for app users.
- Include only non-empty sections from: Added, Fixed, Changed, Improved.
- Each bullet starts with “- ”.
- Do not add a “# Changelog” heading and do not wrap the response in a code fence.
- Do not mention internal details like “update script” unless they matter to users.
- Combine similar commits into one bullet.

Git log:
${gitLog || "(no commits)"}

Diff stat:
${diffStat || "(no changes)"}
`;
  }

  const channelNote =
    channel === "beta"
      ? "Это бета-релиз. Упомяни это одной строкой в начале секции «Изменено», если это уместно."
      : "Это стабильный релиз.";

  return `Сгенерируй секцию changelog для macOS-приложения ${APP_DISPLAY_NAME}.

Версия: ${version}
Дата релиза: ${releaseDate}
Канал: ${channel}
${channelNote}

Используй ТОЛЬКО информацию из git log и diff stat ниже. Не выдумывай изменения.

Формат ответа (строго):
## [${version}] - ${releaseDate}

### Добавлено
- ...

### Исправлено
- ...

### Изменено
- ...

### Улучшено
- ...

Правила:
- Пиши по-русски, коротко и понятно для пользователя приложения.
- Включай только непустые секции из списка: Добавлено, Исправлено, Изменено, Улучшено.
- Каждый пункт начинается с «- ».
- Не добавляй заголовок «# Changelog» и не оборачивай ответ в code fence.
- Не упоминай внутренние детали вроде «update script», если это не важно пользователю.
- Объединяй похожие коммиты в один пункт.

Git log:
${gitLog || "(нет коммитов)"}

Diff stat:
${diffStat || "(нет изменений)"}
`;
}

function buildTranslatePrompt(ruSection) {
  return `Translate the following Keep a Changelog section from Russian to English for the ${APP_DISPLAY_NAME} macOS app.

Keep the heading line exactly as-is (## [version] - YYYY-MM-DD).
Map section headers:
- Добавлено -> Added
- Исправлено -> Fixed
- Изменено -> Changed
- Улучшено -> Improved

Return ONLY the translated section. Do not wrap the response in a code fence.

${ruSection}`;
}

async function generateWithSdk(prompt) {
  const apiKey = cursorApiKey();
  if (!apiKey) {
    throw new Error("CURSOR_API_KEY is not set (export it or add to .env in the repo root)");
  }

  let Agent;
  try {
    ({ Agent } = await import("@cursor/sdk"));
  } catch {
    throw new Error("Install dependencies: npm install --prefix scripts/lib/changelog");
  }

  const result = await Agent.prompt(prompt, {
    apiKey,
    model: { id: "composer-2.5" },
    local: { cwd: ROOT },
  });

  if (result.status === "error") {
    throw new Error(`Cursor agent run failed: ${result.id}`);
  }
  if (!result.result?.trim()) {
    throw new Error("Cursor agent returned an empty result");
  }
  return result.result;
}

function fallbackSection(version, releaseDate, gitLog, channel, lang) {
  const changedTitle = lang === "en" ? "### Changed" : "### Изменено";
  const lines = [`## [${version}] - ${releaseDate}`, "", changedTitle];
  if (channel === "beta") {
    lines.push(lang === "en" ? "- Beta build for testing." : "- Бета-сборка для тестирования.");
  }

  const items = gitLog
    .split(/\r?\n/)
    .map((line) => (line.includes(" ") ? line.split(" ").slice(1).join(" ") : line).trim())
    .filter(Boolean);

  if (items.length) {
    for (const item of items.slice(0, 12)) lines.push(`- ${item}`);
  } else {
    lines.push(lang === "en" ? "- App update." : "- Обновление приложения.");
  }
  return lines.join("\n");
}

function sectionExists(version, changelogPath) {
  if (!existsSync(changelogPath)) return false;
  const pattern = new RegExp(`^## \\[${escapeRegExp(version)}\\] - \\d{4}-\\d{2}-\\d{2}\\s*$`, "m");
  return pattern.test(readFileSync(changelogPath, "utf8"));
}

function readSection(version, changelogPath) {
  if (!existsSync(changelogPath)) return null;
  const text = readFileSync(changelogPath, "utf8");
  const pattern = new RegExp(
    `(## \\[${escapeRegExp(version)}\\] - \\d{4}-\\d{2}-\\d{2}[\\s\\S]*?)(?=\\n## \\[|$)`,
  );
  const match = text.match(pattern);
  return match ? match[1].trim() : null;
}

function prependToChangelogIfMissing(section, version, changelogPath) {
  if (sectionExists(version, changelogPath)) return false;
  const header = "# Changelog\n";
  const body = existsSync(changelogPath) ? readFileSync(changelogPath, "utf8") : header;
  const normalized = body.startsWith("# Changelog") ? body : `${header}\n${body.trimStart()}`;
  const marker = "\n## [";
  const insertAt = normalized.indexOf(marker);
  const updated =
    insertAt === -1
      ? `${normalized.trimEnd()}\n\n${section.trim()}\n`
      : `${normalized.slice(0, insertAt).trimEnd()}\n\n${section.trim()}\n${normalized.slice(insertAt)}`;
  writeFileSync(changelogPath, updated, "utf8");
  return true;
}

async function generateBilingualSection(version, releaseDate, channel, gitLog, diffStat, useFallback) {
  if (useFallback) {
    return {
      ru: fallbackSection(version, releaseDate, gitLog, channel, "ru"),
      en: fallbackSection(version, releaseDate, gitLog, channel, "en"),
    };
  }

  const ruRaw = await generateWithSdk(
    buildPrompt(version, releaseDate, channel, gitLog, diffStat, "ru"),
  );
  const ru = extractVersionSection(ruRaw, version);
  validateSection(ru, version, "ru");

  let en;
  try {
    const enRaw = await generateWithSdk(buildTranslatePrompt(ru));
    en = extractVersionSection(enRaw, version);
    validateSection(en, version, "en");
  } catch {
    const enRaw = await generateWithSdk(
      buildPrompt(version, releaseDate, channel, gitLog, diffStat, "en"),
    );
    en = extractVersionSection(enRaw, version);
    validateSection(en, version, "en");
  }

  return { ru, en };
}

function parseArgs(argv) {
  const args = {
    version: "",
    channel: "stable",
    date: new Date().toISOString().slice(0, 10),
    fromRef: "",
    output: "",
    outputEn: "",
    prependChangelog: false,
    fallback: false,
    extractExisting: false,
    printStdout: false,
    lang: "",
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--version":
        args.version = argv[++i] ?? "";
        break;
      case "--channel":
        args.channel = argv[++i] ?? "stable";
        break;
      case "--date":
        args.date = argv[++i] ?? args.date;
        break;
      case "--from-ref":
        args.fromRef = argv[++i] ?? "";
        break;
      case "--output":
        args.output = argv[++i] ?? "";
        break;
      case "--output-en":
        args.outputEn = argv[++i] ?? "";
        break;
      case "--lang":
        args.lang = argv[++i] ?? "";
        break;
      case "--prepend-changelog":
        args.prependChangelog = true;
        break;
      case "--fallback":
        args.fallback = true;
        break;
      case "--extract-existing":
        args.extractExisting = true;
        break;
      case "--print":
        args.printStdout = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!args.version) throw new Error("--version is required");
  if (args.lang && args.lang !== "ru" && args.lang !== "en") {
    throw new Error("--lang must be ru or en");
  }
  return args;
}

async function generateMonoSection(version, releaseDate, channel, gitLog, diffStat, useFallback) {
  if (useFallback) {
    return fallbackSection(version, releaseDate, gitLog, channel, "ru");
  }

  const raw = await generateWithSdk(
    buildPrompt(version, releaseDate, channel, gitLog, diffStat, "ru"),
  );
  const section = extractVersionSection(raw, version);
  validateSection(section, version, "ru");
  return section;
}

async function main() {
  loadDotenv();
  const args = parseArgs(process.argv.slice(2));
  const version = args.version.replace(/^v/i, "");

  if (args.extractExisting) {
    const ruSection = readSection(version, CHANGELOG_RU_PATH);
    if (BILINGUAL) {
      const enSection = readSection(version, CHANGELOG_EN_PATH);
      if (!ruSection || !enSection) process.exit(1);
      if (args.output) writeFileSync(args.output, `${ruSection}\n`, "utf8");
      if (args.outputEn) writeFileSync(args.outputEn, `${enSection}\n`, "utf8");
      if (args.printStdout) process.stdout.write(`${ruSection}\n\n---\n\n${enSection}\n`);
      return;
    }

    if (!ruSection) process.exit(1);
    if (args.output) writeFileSync(args.output, `${ruSection}\n`, "utf8");
    if (args.printStdout || !args.output) process.stdout.write(`${ruSection}\n`);
    return;
  }

  const fromRef = args.fromRef || previousReleaseRef();
  const gitLog = collectGitLog(fromRef);
  const diffStat = collectDiffStat(fromRef);

  if (BILINGUAL) {
    const { ru, en } = await generateBilingualSection(
      version,
      args.date,
      args.channel,
      gitLog,
      diffStat,
      args.fallback,
    );

    if (args.output && (!args.lang || args.lang === "ru")) {
      writeFileSync(args.output, `${ru}\n`, "utf8");
    }
    if (args.outputEn && (!args.lang || args.lang === "en")) {
      writeFileSync(args.outputEn, `${en}\n`, "utf8");
    }

    if (args.prependChangelog) {
      prependToChangelogIfMissing(ru, version, CHANGELOG_RU_PATH);
      prependToChangelogIfMissing(en, version, CHANGELOG_EN_PATH);
    }

    if (args.printStdout || (!args.output && !args.outputEn && !args.prependChangelog)) {
      process.stdout.write(`${ru}\n\n---\n\n${en}\n`);
    }
    return;
  }

  const section = await generateMonoSection(
    version,
    args.date,
    args.channel,
    gitLog,
    diffStat,
    args.fallback,
  );

  if (args.output) writeFileSync(args.output, `${section}\n`, "utf8");
  if (args.prependChangelog) prependToChangelogIfMissing(section, version, CHANGELOG_RU_PATH);
  if (args.printStdout || (!args.output && !args.prependChangelog)) {
    process.stdout.write(`${section}\n`);
  }
}

main().catch((error) => {
  console.error(`error: ${error.message}`);
  process.exit(1);
});
