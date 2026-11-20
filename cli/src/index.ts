#!/usr/bin/env node
import { execFile, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, open, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, extname, join, resolve } from "node:path";
import { parseArgs, promisify } from "node:util";

const run = promisify(execFile);

const ID_RE = /^[A-Za-z0-9_-]{22}$/;
// R2 needs parts of equal size. A Worker on the free plan accepts a body of 100 MB maximum.
const PART_BYTES = 32 * 1024 * 1024;
const LOOM_RE = /^https:\/\/www\.loom\.com\/share\/[0-9a-f]{32}(\?.*)?$/;

interface Config {
  url: string;
  adminToken: string;
  // The rsync destination of the archive: "user@host:directory" or a local directory.
  archive?: string;
  // A shell command that reads audio on stdin and writes WebVTT captions on stdout.
  transcribe?: string;
}

interface Meta {
  id: string;
  title: string;
  source: string;
  durationS: number;
  createdAt: string;
  // The link of the video in a different service, for an imported video.
  importedFrom?: string;
}

interface PublishOptions {
  title?: string;
  transcript?: boolean;
  createdAt?: string;
  importedFrom?: string;
}

interface VideoRow {
  id: string;
  title: string;
  duration_s: number;
  size_bytes: number;
  has_transcript: number;
  state: string;
  created_at: number;
  last_viewed_at: number;
}

const USAGE = `Usage:
  loomy publish <file> [--title <title>]   Publish a recording and print its link.
  loomy publish <id>                       Publish an evicted video again. Uses the local copy, or the archive.
  loomy import <loom-link>...              Download videos from Loom share links and publish them. Needs yt-dlp.
  loomy transcribe [<id>] [--force]        Make the transcript of one video, or of all videos with no transcript.
  loomy archive [<id>]                     Copy one video, or all videos, to the archive.
  loomy list [--json]                      List all videos.
  loomy rm <id>                            Remove a video from the watch service.

Configuration:
  Set LOOMY_URL and LOOMY_ADMIN_TOKEN, or write them to ${configPath()}
  as {"url": "...", "adminToken": "...", "archive": "user@host:directory", "transcribe": "command"}.
  LOOMY_ARCHIVE sets the archive. LOOMY_TRANSCRIBE sets the transcribe command. Both are optional.
  The transcribe command reads audio on stdin and writes WebVTT on stdout.
  Use --no-transcript with publish or import to skip the transcript.
`;

function configPath(): string {
  return join(homedir(), ".config", "loomy", "config.json");
}

function dataDir(): string {
  return process.env.LOOMY_DATA_DIR ?? join(homedir(), "Library", "Application Support", "Loomy", "videos");
}

async function loadConfig(): Promise<Config> {
  let file: Partial<Config> = {};
  if (existsSync(configPath())) {
    file = JSON.parse(await readFile(configPath(), "utf8")) as Partial<Config>;
  }
  const url = (process.env.LOOMY_URL ?? file.url ?? "").replace(/\/+$/, "");
  const adminToken = process.env.LOOMY_ADMIN_TOKEN ?? file.adminToken ?? "";
  if (!url || !adminToken) {
    throw new Error(`The configuration is not complete.\n\n${USAGE}`);
  }
  const archive = (process.env.LOOMY_ARCHIVE ?? file.archive ?? "").replace(/\/+$/, "") || undefined;
  const transcribe = (process.env.LOOMY_TRANSCRIBE ?? file.transcribe ?? "").trim() || undefined;
  return { url, adminToken, archive, transcribe };
}

const ATTEMPTS = 4;

// Each admin request is safe to send again, so a network error or a server error gets a new attempt.
async function api(config: Config, method: string, path: string, body?: string | Uint8Array, json = false): Promise<unknown> {
  const headers: Record<string, string> = { authorization: `Bearer ${config.adminToken}` };
  if (json) headers["content-type"] = "application/json";
  let failure = "";
  for (let attempt = 1; attempt <= ATTEMPTS; attempt++) {
    if (attempt > 1) {
      log(`  ${failure} Attempt ${attempt} of ${ATTEMPTS}.`);
      await new Promise((done) => setTimeout(done, 500 * 2 ** (attempt - 2)));
    }
    try {
      const response = await fetch(`${config.url}${path}`, { method, headers, body });
      if (response.ok) return await response.json();
      failure = `${method} ${path} failed: ${response.status} ${(await response.text()).slice(0, 300)}`;
      if (response.status < 500) break;
    } catch (err) {
      const cause = err instanceof Error && err.cause instanceof Error ? err.cause : undefined;
      const code = cause && "code" in cause ? `${String(cause.code)}: ` : "";
      failure = `${method} ${path} failed: network error (${code}${cause?.message ?? String(err)}).`;
    }
  }
  throw new Error(failure);
}

function log(message: string): void {
  process.stderr.write(`${message}\n`);
}

async function probeDuration(file: string): Promise<number> {
  const { stdout } = await run("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "json", file]);
  const duration = Number((JSON.parse(stdout) as { format?: { duration?: string } }).format?.duration);
  return Number.isFinite(duration) ? duration : 0;
}

async function transcode(source: string, target: string): Promise<void> {
  await run(
    "ffmpeg",
    [
      "-hide_banner", "-loglevel", "error", "-y",
      "-i", source,
      "-map", "0:v:0", "-map", "0:a:0?",
      "-vf", "scale=-2:'min(1080,ih)'",
      "-fpsmax", "30",
      "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
      "-c:a", "aac", "-b:a", "128k",
      "-movflags", "+faststart",
      target,
    ],
    { maxBuffer: 16 * 1024 * 1024 },
  );
}

async function makeThumbnail(video: string, target: string, durationS: number): Promise<void> {
  const at = Math.min(1, durationS / 2).toFixed(2);
  await run("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-y",
    "-ss", at, "-i", video,
    "-frames:v", "1", "-vf", "scale='min(1280,iw)':-2", "-q:v", "3",
    target,
  ]);
}

async function uploadFile(config: Config, id: string, name: string, file: string): Promise<void> {
  const { size } = await stat(file);
  const base = `/admin/videos/${id}/files/${name}`;
  if (size <= PART_BYTES) {
    await api(config, "PUT", base, await readFile(file));
    return;
  }

  const { uploadId } = (await api(config, "POST", `${base}/uploads`)) as { uploadId: string };
  const uploadPath = `${base}/uploads/${encodeURIComponent(uploadId)}`;
  const handle = await open(file, "r");
  try {
    const parts: unknown[] = [];
    const count = Math.ceil(size / PART_BYTES);
    for (let n = 1; n <= count; n++) {
      const length = Math.min(PART_BYTES, size - (n - 1) * PART_BYTES);
      const buffer = Buffer.alloc(length);
      await handle.read(buffer, 0, length, (n - 1) * PART_BYTES);
      parts.push(await api(config, "PUT", `${uploadPath}/${n}`, buffer));
      log(`  ${name}: part ${n} of ${count}`);
    }
    await api(config, "POST", uploadPath, JSON.stringify({ parts }), true);
  } catch (err) {
    await api(config, "DELETE", uploadPath).catch(() => undefined);
    throw err;
  } finally {
    await handle.close();
  }
}

const MEDIA_FILES = ["video.mp4", "thumb.jpg", "captions.vtt"];

function rsync(args: string[]): Promise<unknown> {
  // BatchMode makes ssh fail when it needs a password. It does not stop for input.
  return run("rsync", ["-a", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10", ...args]);
}

// The archive gets the files of the watch service and the original recording.
async function archiveVideo(archive: string, id: string): Promise<void> {
  const dir = join(dataDir(), id);
  const meta = JSON.parse(await readFile(join(dir, "meta.json"), "utf8")) as Meta;
  const target = `${archive}/${id}/`;
  await rsync([`${dir}/`, target]);
  if (existsSync(meta.source)) {
    await rsync([meta.source, `${target}original${extname(meta.source).toLowerCase()}`]);
  }
}

async function restoreVideo(archive: string, id: string): Promise<void> {
  const dir = join(dataDir(), id);
  await mkdir(dir, { recursive: true });
  await rsync(["--exclude", "original.*", `${archive}/${id}/`, `${dir}/`]);
}

async function archiveCommand(id: string | undefined): Promise<void> {
  const config = await loadConfig();
  if (!config.archive) throw new Error("The configuration has no archive.");
  if (id !== undefined && !ID_RE.test(id)) throw new Error("The ID is not valid.");
  const ids = id ? [id] : (await readdir(dataDir())).filter((name) => ID_RE.test(name));
  let failures = 0;
  for (const each of ids) {
    try {
      await archiveVideo(config.archive, each);
      log(`Archived ${each}.`);
    } catch (err) {
      failures++;
      log(`The archive copy of ${each} failed: ${errorText(err)}`);
    }
  }
  if (failures > 0) throw new Error(`${failures} of ${ids.length} videos are not in the archive.`);
}

function errorText(err: unknown): string {
  const stderr = err && typeof err === "object" && "stderr" in err ? String(err.stderr).trim() : "";
  return stderr || (err instanceof Error ? err.message : String(err));
}

function copyToClipboard(value: string): void {
  if (process.platform !== "darwin" || process.env.LOOMY_NO_CLIPBOARD) return;
  const child = spawn("pbcopy", { stdio: ["pipe", "ignore", "ignore"] });
  child.on("error", () => undefined);
  child.stdin.end(value);
}

async function publish(target: string, options: PublishOptions = {}): Promise<void> {
  const titleOption = options.title;
  const config = await loadConfig();
  let meta: Meta;
  let dir: string;

  const isLocalFile = existsSync(resolve(target));
  if (ID_RE.test(target) && !isLocalFile) {
    // Publish a video again from the local copy, or from the archive.
    dir = join(dataDir(), target);
    if (!existsSync(join(dir, "video.mp4"))) {
      if (!config.archive) throw new Error(`No local copy of ${target} exists, and the configuration has no archive.`);
      log("Get the video from the archive.");
      await restoreVideo(config.archive, target);
    }
    meta = JSON.parse(await readFile(join(dir, "meta.json"), "utf8")) as Meta;
    if (titleOption) meta.title = titleOption;
    log(`Publish "${meta.title}" again.`);
  } else {
    const source = resolve(target);
    if (!existsSync(source)) throw new Error(`The file does not exist: ${source}`);
    const id = randomBytes(16).toString("base64url");
    dir = join(dataDir(), id);
    await mkdir(dir, { recursive: true });
    meta = {
      id,
      title: titleOption ?? basename(source, extname(source)),
      source,
      durationS: await probeDuration(source),
      createdAt: options.createdAt ?? new Date().toISOString(),
      ...(options.importedFrom ? { importedFrom: options.importedFrom } : {}),
    };
    log("Transcode the recording.");
    await transcode(source, join(dir, "video.mp4"));
    await makeThumbnail(join(dir, "video.mp4"), join(dir, "thumb.jpg"), meta.durationS);
  }
  await writeFile(join(dir, "meta.json"), `${JSON.stringify(meta, null, 2)}\n`);

  log("Upload the video.");
  const path = `/admin/videos/${meta.id}`;
  await api(
    config,
    "PUT",
    path,
    JSON.stringify({ title: meta.title, durationS: meta.durationS, createdAt: Date.parse(meta.createdAt) || undefined }),
    true,
  );
  for (const name of MEDIA_FILES) {
    const file = join(dir, name);
    if (existsSync(file)) await uploadFile(config, meta.id, name, file);
  }
  const result = (await api(config, "POST", `${path}/ready`)) as { url: string };

  copyToClipboard(result.url);
  process.stdout.write(`${result.url}\n`);

  // The link works before the transcript exists. The transcript comes after it.
  if (config.transcribe && options.transcript !== false && !existsSync(join(dir, "captions.vtt"))) {
    try {
      if (await makeTranscript(config.transcribe, dir)) {
        await uploadFile(config, meta.id, "captions.vtt", join(dir, "captions.vtt"));
        await api(config, "POST", `${path}/ready`);
        log("The transcript is on the watch page.");
      }
    } catch (err) {
      log(`The transcript failed: ${errorText(err)}\nRun "loomy transcribe ${meta.id}" to try again.`);
      process.exitCode = 2;
    }
  }

  if (!config.archive) {
    log("The configuration has no archive. The Mac has the only copy.");
    return;
  }
  try {
    await archiveVideo(config.archive, meta.id);
    log("The video is in the archive.");
  } catch (err) {
    // The link works, so this is not a failure of the publish. Exit code 2 reports it.
    log(`The archive copy failed: ${errorText(err)}\nRun "loomy archive ${meta.id}" to try again.`);
    process.exitCode = 2;
  }
}

async function hasAudio(file: string): Promise<boolean> {
  const { stdout } = await run("ffprobe", [
    "-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", file,
  ]);
  return stdout.trim().length > 0;
}

// Sends the audio of video.mp4 to the transcribe command and writes captions.vtt.
// Returns false when the video has no audio.
async function makeTranscript(command: string, dir: string): Promise<boolean> {
  const video = join(dir, "video.mp4");
  if (!(await hasAudio(video))) {
    log("The video has no audio, so it gets no transcript.");
    return false;
  }
  log("Make the transcript.");
  const temp = await mkdtemp(join(tmpdir(), "loomy-audio-"));
  try {
    // video.mp4 always has AAC audio, so a copy of the stream is sufficient.
    const audio = join(temp, "audio.aac");
    await run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-i", video, "-vn", "-c:a", "copy", "-f", "adts", audio]);
    const input = await open(audio, "r");
    let output: string;
    try {
      output = await new Promise<string>((done, fail) => {
        const child = spawn("/bin/sh", ["-c", command], { stdio: [input.fd, "pipe", "pipe"] });
        const out: Buffer[] = [];
        const err: Buffer[] = [];
        child.stdout!.on("data", (chunk: Buffer) => out.push(chunk));
        child.stderr!.on("data", (chunk: Buffer) => err.push(chunk));
        child.on("error", fail);
        child.on("close", (code) => {
          const stderr = Buffer.concat(err).toString().trim();
          if (code === 0) done(Buffer.concat(out).toString());
          else fail(new Error(`The transcribe command stopped with code ${code}.${stderr ? `\n${stderr}` : ""}`));
        });
      });
    } finally {
      await input.close();
    }
    if (!output.startsWith("WEBVTT")) throw new Error("The transcribe command did not write WebVTT.");
    await writeFile(join(dir, "captions.vtt"), output);
    return true;
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
}

async function transcribeCommand(id: string | undefined, force: boolean): Promise<void> {
  const config = await loadConfig();
  if (!config.transcribe) throw new Error("The configuration has no transcribe command.");
  if (id !== undefined && !ID_RE.test(id)) throw new Error("The ID is not valid.");
  let ids: string[];
  if (id) {
    ids = [id];
    if (!existsSync(join(dataDir(), id, "video.mp4"))) {
      if (!config.archive) throw new Error(`No local copy of ${id} exists, and the configuration has no archive.`);
      log("Get the video from the archive.");
      await restoreVideo(config.archive, id);
    }
  } else {
    const names = existsSync(dataDir()) ? await readdir(dataDir()) : [];
    ids = names.filter(
      (name) =>
        ID_RE.test(name) &&
        existsSync(join(dataDir(), name, "video.mp4")) &&
        (force || !existsSync(join(dataDir(), name, "captions.vtt"))),
    );
  }
  if (ids.length === 0) {
    log("All local videos have a transcript.");
    return;
  }
  const { videos } = (await api(config, "GET", "/admin/videos")) as { videos: VideoRow[] };
  const states = new Map(videos.map((video) => [video.id, video.state]));
  let failures = 0;
  for (const each of ids) {
    const dir = join(dataDir(), each);
    try {
      if (!force && existsSync(join(dir, "captions.vtt"))) {
        log(`${each} already has a transcript. Use --force to make it again.`);
        continue;
      }
      log(`Transcribe ${each}.`);
      if (!(await makeTranscript(config.transcribe, dir))) continue;
      // An evicted video gets the transcript when it is published again.
      if (states.get(each) === "ready") {
        await uploadFile(config, each, "captions.vtt", join(dir, "captions.vtt"));
        await api(config, "POST", `/admin/videos/${each}/ready`);
        log("The transcript is on the watch page.");
      }
      if (config.archive) await archiveVideo(config.archive, each);
    } catch (err) {
      failures++;
      log(`The transcript of ${each} failed: ${errorText(err)}`);
    }
  }
  if (failures > 0) throw new Error(`${failures} of ${ids.length} transcripts failed.`);
}

// Returns the ID of the local video that came from this link, if one exists.
async function findImport(link: string): Promise<string | undefined> {
  if (!existsSync(dataDir())) return undefined;
  for (const id of await readdir(dataDir())) {
    const file = join(dataDir(), id, "meta.json");
    if (!ID_RE.test(id) || !existsSync(file)) continue;
    if ((JSON.parse(await readFile(file, "utf8")) as Meta).importedFrom === link) return id;
  }
  return undefined;
}

async function importLoom(links: string[], transcript: boolean): Promise<void> {
  for (const link of links) {
    if (!LOOM_RE.test(link)) throw new Error(`This is not a Loom share link: ${link}`);
  }
  let failures = 0;
  for (const raw of links) {
    const link = raw.split("?")[0]!;
    const existing = await findImport(link);
    if (existing) {
      log(`${link} is already imported as ${existing}. Skipped.`);
      continue;
    }
    const temp = await mkdtemp(join(tmpdir(), "loomy-import-"));
    process.exitCode = 0;
    try {
      log(`Download ${link}.`);
      const common = ["--no-warnings", "--no-playlist", "--ignore-config"];
      const { stdout } = await run("yt-dlp", [...common, "--skip-download", "--dump-json", "--", link], {
        maxBuffer: 64 * 1024 * 1024,
      });
      const info = JSON.parse(stdout) as { title?: string; timestamp?: number };
      const file = join(temp, "loom.mp4");
      await run("yt-dlp", [...common, "--quiet", "--merge-output-format", "mp4", "-o", file, "--", link], {
        maxBuffer: 64 * 1024 * 1024,
      });
      await publish(file, {
        title: info.title?.trim() || "Loom video",
        createdAt: info.timestamp ? new Date(info.timestamp * 1000).toISOString() : undefined,
        importedFrom: link,
        transcript,
      });
    } catch (err) {
      failures++;
      log(`The import of ${link} failed: ${errorText(err)}`);
      continue;
    } finally {
      // After a failed archive copy, the download stays, because "loomy archive" needs it.
      if (process.exitCode !== 2) await rm(temp, { recursive: true, force: true });
      else failures++;
    }
  }
  process.exitCode = 0;
  if (failures > 0) throw new Error(`${failures} of ${links.length} imports have a problem.`);
}

async function list(asJson: boolean): Promise<void> {
  const config = await loadConfig();
  const { videos } = (await api(config, "GET", "/admin/videos")) as { videos: VideoRow[] };
  if (asJson) {
    process.stdout.write(`${JSON.stringify(videos, null, 2)}\n`);
    return;
  }
  for (const video of videos) {
    const size = `${(video.size_bytes / 1e6).toFixed(1)} MB`.padStart(10);
    const viewed = new Date(video.last_viewed_at).toISOString().slice(0, 10);
    process.stdout.write(`${video.id}  ${video.state.padEnd(9)} ${size}  ${viewed}  ${video.title}\n`);
  }
  const total = videos.reduce((sum, video) => sum + video.size_bytes, 0);
  log(`${videos.length} videos, ${(total / 1e9).toFixed(2)} GB in the watch service.`);
}

async function remove(id: string): Promise<void> {
  if (!ID_RE.test(id)) throw new Error("The ID is not valid.");
  const config = await loadConfig();
  await api(config, "DELETE", `/admin/videos/${id}`);
  log(`Removed ${id} from the watch service. The local copy stays.`);
}

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      title: { type: "string" },
      json: { type: "boolean", default: false },
      force: { type: "boolean", default: false },
      "no-transcript": { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
  });
  const [command, argument] = positionals;
  if (values.help || !command) {
    process.stdout.write(USAGE);
    return;
  }
  if (command === "publish" && argument) return publish(argument, { title: values.title, transcript: !values["no-transcript"] });
  if (command === "import" && argument) return importLoom(positionals.slice(1), !values["no-transcript"]);
  if (command === "transcribe") return transcribeCommand(argument, values.force);
  if (command === "archive") return archiveCommand(argument);
  if (command === "list") return list(values.json);
  if (command === "rm" && argument) return remove(argument);
  throw new Error(`The command is not valid.\n\n${USAGE}`);
}

main().catch((err: unknown) => {
  process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
  process.exitCode = 1;
});
