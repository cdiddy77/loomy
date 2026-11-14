#!/usr/bin/env node
import { execFile, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, open, readFile, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, extname, join, resolve } from "node:path";
import { parseArgs, promisify } from "node:util";

const run = promisify(execFile);

const ID_RE = /^[A-Za-z0-9_-]{22}$/;
// R2 needs parts of equal size. A Worker on the free plan accepts a body of 100 MB maximum.
const PART_BYTES = 32 * 1024 * 1024;

interface Config {
  url: string;
  adminToken: string;
}

interface Meta {
  id: string;
  title: string;
  source: string;
  durationS: number;
  createdAt: string;
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
  loomy publish <id>                       Publish an evicted video again from the local copy.
  loomy list [--json]                      List all videos.
  loomy rm <id>                            Remove a video from the watch service.

Configuration:
  Set LOOMY_URL and LOOMY_ADMIN_TOKEN, or write them to ${configPath()}
  as {"url": "...", "adminToken": "..."}.
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
  return { url, adminToken };
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

function copyToClipboard(value: string): void {
  if (process.platform !== "darwin" || process.env.LOOMY_NO_CLIPBOARD) return;
  const child = spawn("pbcopy", { stdio: ["pipe", "ignore", "ignore"] });
  child.on("error", () => undefined);
  child.stdin.end(value);
}

async function publish(target: string, titleOption: string | undefined): Promise<void> {
  const config = await loadConfig();
  let meta: Meta;
  let dir: string;

  if (ID_RE.test(target) && existsSync(join(dataDir(), target, "meta.json"))) {
    // Publish a video again from the local copy.
    dir = join(dataDir(), target);
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
      createdAt: new Date().toISOString(),
    };
    log("Transcode the recording.");
    await transcode(source, join(dir, "video.mp4"));
    await makeThumbnail(join(dir, "video.mp4"), join(dir, "thumb.jpg"), meta.durationS);
  }
  await writeFile(join(dir, "meta.json"), `${JSON.stringify(meta, null, 2)}\n`);

  log("Upload the video.");
  const path = `/admin/videos/${meta.id}`;
  await api(config, "PUT", path, JSON.stringify({ title: meta.title, durationS: meta.durationS }), true);
  for (const name of ["video.mp4", "thumb.jpg", "captions.vtt"]) {
    const file = join(dir, name);
    if (existsSync(file)) await uploadFile(config, meta.id, name, file);
  }
  const result = (await api(config, "POST", `${path}/ready`)) as { url: string };

  copyToClipboard(result.url);
  process.stdout.write(`${result.url}\n`);
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
      help: { type: "boolean", short: "h", default: false },
    },
  });
  const [command, argument] = positionals;
  if (values.help || !command) {
    process.stdout.write(USAGE);
    return;
  }
  if (command === "publish" && argument) return publish(argument, values.title);
  if (command === "list") return list(values.json);
  if (command === "rm" && argument) return remove(argument);
  throw new Error(`The command is not valid.\n\n${USAGE}`);
}

main().catch((err: unknown) => {
  process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
  process.exitCode = 1;
});
