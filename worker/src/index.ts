import { renderMessagePage, renderWatchPage } from "./pages";

export interface Env {
  BUCKET: R2Bucket;
  DB: D1Database;
  ADMIN_TOKEN: string;
  STORAGE_BUDGET_BYTES: string;
}

export interface VideoRow {
  id: string;
  title: string;
  duration_s: number;
  size_bytes: number;
  has_transcript: number;
  state: "uploading" | "ready" | "evicted";
  created_at: number;
  updated_at: number;
  last_viewed_at: number;
}

// 128 random bits in base64url.
const ID_RE = /^[A-Za-z0-9_-]{22}$/;

const FILES: Record<string, string> = {
  "video.mp4": "video/mp4",
  "thumb.jpg": "image/jpeg",
  "captions.vtt": "text/vtt; charset=utf-8",
};

const VIEW_WRITE_INTERVAL_MS = 60 * 60 * 1000;
const STALE_UPLOAD_MS = 24 * 60 * 60 * 1000;

const BASE_HEADERS: Record<string, string> = {
  "x-robots-tag": "noindex, nofollow",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
};

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    let response: Response;
    try {
      response = await route(request, env, ctx);
    } catch (err) {
      console.error(err);
      response = text("Internal error", 500);
    }
    const headers = new Headers(response.headers);
    for (const [k, v] of Object.entries(BASE_HEADERS)) headers.set(k, v);
    return new Response(response.body, { status: response.status, headers });
  },

  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(evict(env));
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  const parts = url.pathname.split("/").filter(Boolean);

  if (parts[0] === "v") return publicRoute(request, env, ctx, url, parts.slice(1));
  if (parts[0] === "admin") {
    // An unauthorized caller gets the same answer as for an unknown path.
    if (!(await isAdmin(request, env))) return notFound();
    return adminRoute(request, env, url, parts.slice(1));
  }
  return notFound();
}

// ---------------------------------------------------------------------------
// Public routes: the watch page and the media files.
// ---------------------------------------------------------------------------

async function publicRoute(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  url: URL,
  parts: string[],
): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") return text("Method not allowed", 405);
  const [id, name] = parts;
  if (!id || !ID_RE.test(id) || parts.length > 2) return notFound();

  if (name === undefined) {
    const row = await getVideo(env, id);
    if (!row || row.state === "uploading") {
      return html(renderMessagePage("Video not found", "This link does not point to a video."), 404);
    }
    if (row.state === "evicted") {
      return html(
        renderMessagePage(
          "Video not available",
          "This video is not available at this time. Ask the person who sent the link to publish it again.",
        ),
        410,
      );
    }
    return html(renderWatchPage(row, url.origin));
  }

  const contentType = FILES[name];
  if (!contentType) return notFound();

  if (name === "video.mp4" && request.method === "GET") {
    const now = Date.now();
    ctx.waitUntil(
      env.DB.prepare("UPDATE videos SET last_viewed_at = ?1 WHERE id = ?2 AND state = 'ready' AND last_viewed_at < ?3")
        .bind(now, id, now - VIEW_WRITE_INTERVAL_MS)
        .run(),
    );
  }
  return serveObject(request, env, `${id}/${name}`, contentType);
}

async function serveObject(request: Request, env: Env, key: string, contentType: string): Promise<Response> {
  let object: R2Object | R2ObjectBody | null;
  try {
    object = await env.BUCKET.get(key, { range: request.headers, onlyIf: request.headers });
  } catch {
    // R2 rejects a range that the object cannot satisfy.
    return text("Range not satisfiable", 416);
  }
  if (!object) return notFound();

  const headers = new Headers({
    "content-type": contentType,
    "accept-ranges": "bytes",
    etag: object.httpEtag,
    "cache-control": "private, max-age=86400",
  });

  if (!("body" in object)) return new Response(null, { status: 304, headers });

  let status = 200;
  let length = object.size;
  if (request.headers.has("range") && object.range) {
    const range = object.range as { offset?: number; length?: number; suffix?: number };
    const start = range.suffix !== undefined ? object.size - range.suffix : (range.offset ?? 0);
    length = range.suffix !== undefined ? range.suffix : (range.length ?? object.size - start);
    headers.set("content-range", `bytes ${start}-${start + length - 1}/${object.size}`);
    status = 206;
  }
  headers.set("content-length", String(length));
  return new Response(request.method === "HEAD" ? null : object.body, { status, headers });
}

// ---------------------------------------------------------------------------
// Admin routes: only the publish tool calls these.
// ---------------------------------------------------------------------------

async function isAdmin(request: Request, env: Env): Promise<boolean> {
  if (!env.ADMIN_TOKEN || env.ADMIN_TOKEN.length < 32) return false;
  const encoder = new TextEncoder();
  const [given, expected] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(request.headers.get("authorization") ?? "")),
    crypto.subtle.digest("SHA-256", encoder.encode(`Bearer ${env.ADMIN_TOKEN}`)),
  ]);
  return crypto.subtle.timingSafeEqual(given, expected);
}

async function adminRoute(request: Request, env: Env, url: URL, parts: string[]): Promise<Response> {
  const method = request.method;
  if (parts[0] !== "videos") return notFound();

  // /admin/videos
  if (parts.length === 1) {
    if (method !== "GET") return text("Method not allowed", 405);
    const { results } = await env.DB.prepare("SELECT * FROM videos ORDER BY created_at DESC").all<VideoRow>();
    return json({ videos: results });
  }

  const id = parts[1]!;
  if (!ID_RE.test(id)) return text("Invalid ID", 400);

  // /admin/videos/:id
  if (parts.length === 2) {
    if (method === "PUT") return upsertVideo(request, env, id);
    if (method === "DELETE") {
      await deleteObjects(env, id);
      await env.DB.prepare("UPDATE videos SET state = 'evicted', size_bytes = 0, updated_at = ?1 WHERE id = ?2")
        .bind(Date.now(), id)
        .run();
      return json({ ok: true });
    }
    return text("Method not allowed", 405);
  }

  // /admin/videos/:id/ready
  if (parts.length === 3 && parts[2] === "ready") {
    if (method !== "POST") return text("Method not allowed", 405);
    return markReady(env, url, id);
  }

  // /admin/videos/:id/files/:name[/uploads[/:uploadId[/:part]]]
  if (parts[2] === "files" && parts[3]) {
    const name = parts[3];
    const contentType = FILES[name];
    if (!contentType) return text("Invalid file name", 400);
    if (!(await getVideo(env, id))) return text("Unknown video", 404);
    const key = `${id}/${name}`;
    const rest = parts.slice(4);

    if (rest.length === 0 && method === "PUT") {
      if (!request.body) return text("Missing body", 400);
      await env.BUCKET.put(key, request.body, { httpMetadata: { contentType } });
      return json({ ok: true });
    }
    if (rest[0] !== "uploads") return notFound();

    if (rest.length === 1 && method === "POST") {
      const upload = await env.BUCKET.createMultipartUpload(key, { httpMetadata: { contentType } });
      return json({ uploadId: upload.uploadId });
    }
    const upload = env.BUCKET.resumeMultipartUpload(key, rest[1]!);

    if (rest.length === 3 && method === "PUT") {
      const partNumber = Number(rest[2]);
      if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10000) return text("Invalid part", 400);
      if (!request.body) return text("Missing body", 400);
      const part = await upload.uploadPart(partNumber, request.body);
      return json({ partNumber: part.partNumber, etag: part.etag });
    }
    if (rest.length === 2 && method === "POST") {
      const body = (await request.json()) as { parts?: R2UploadedPart[] };
      if (!Array.isArray(body.parts) || body.parts.length === 0) return text("Missing parts", 400);
      await upload.complete(body.parts);
      return json({ ok: true });
    }
    if (rest.length === 2 && method === "DELETE") {
      await upload.abort();
      return json({ ok: true });
    }
  }
  return notFound();
}

async function upsertVideo(request: Request, env: Env, id: string): Promise<Response> {
  const body = (await request.json()) as { title?: unknown; durationS?: unknown };
  const title = typeof body.title === "string" ? body.title.trim().slice(0, 200) : "";
  const duration = typeof body.durationS === "number" && Number.isFinite(body.durationS) ? body.durationS : 0;
  if (!title) return text("Missing title", 400);
  const now = Date.now();
  // A video that is published again keeps its time of creation. Its time of
  // last view starts again, so the eviction job does not remove it immediately.
  await env.DB.prepare(
    `INSERT INTO videos (id, title, duration_s, state, created_at, updated_at, last_viewed_at)
     VALUES (?1, ?2, ?3, 'uploading', ?4, ?4, ?4)
     ON CONFLICT (id) DO UPDATE SET
       title = ?2, duration_s = ?3, state = 'uploading', updated_at = ?4, last_viewed_at = ?4`,
  )
    .bind(id, title, duration, now)
    .run();
  return json({ ok: true });
}

async function markReady(env: Env, url: URL, id: string): Promise<Response> {
  const heads = await Promise.all(Object.keys(FILES).map((name) => env.BUCKET.head(`${id}/${name}`)));
  const names = Object.keys(FILES);
  if (!heads[names.indexOf("video.mp4")]) return text("The video file is missing", 409);
  const size = heads.reduce((sum, head) => sum + (head?.size ?? 0), 0);
  const hasTranscript = heads[names.indexOf("captions.vtt")] ? 1 : 0;
  const result = await env.DB.prepare(
    "UPDATE videos SET state = 'ready', size_bytes = ?1, has_transcript = ?2, updated_at = ?3 WHERE id = ?4",
  )
    .bind(size, hasTranscript, Date.now(), id)
    .run();
  if (result.meta.changes === 0) return text("Unknown video", 404);
  return json({ ok: true, url: `${url.origin}/v/${id}`, sizeBytes: size });
}

// ---------------------------------------------------------------------------
// Eviction.
// ---------------------------------------------------------------------------

export async function evict(env: Env): Promise<void> {
  const now = Date.now();

  // Remove uploads that did not complete.
  const stale = await env.DB.prepare("SELECT id FROM videos WHERE state = 'uploading' AND updated_at < ?1")
    .bind(now - STALE_UPLOAD_MS)
    .all<{ id: string }>();
  for (const { id } of stale.results) {
    await deleteObjects(env, id);
    await env.DB.prepare("DELETE FROM videos WHERE id = ?1 AND state = 'uploading'").bind(id).run();
  }

  const budget = Number(env.STORAGE_BUDGET_BYTES);
  if (!Number.isFinite(budget) || budget <= 0) {
    console.error("STORAGE_BUDGET_BYTES is not valid. The eviction job did not run.");
    return;
  }
  const sum = await env.DB.prepare(
    "SELECT COALESCE(SUM(size_bytes), 0) AS total FROM videos WHERE state = 'ready'",
  ).first<{ total: number }>();
  let total = sum?.total ?? 0;

  while (total > budget) {
    const victim = await env.DB.prepare(
      "SELECT id, size_bytes FROM videos WHERE state = 'ready' ORDER BY last_viewed_at ASC, created_at ASC LIMIT 1",
    ).first<{ id: string; size_bytes: number }>();
    if (!victim) break;
    await deleteObjects(env, victim.id);
    await env.DB.prepare("UPDATE videos SET state = 'evicted', size_bytes = 0, updated_at = ?1 WHERE id = ?2")
      .bind(now, victim.id)
      .run();
    total -= victim.size_bytes;
    console.log(`Evicted ${victim.id} (${victim.size_bytes} bytes)`);
  }
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

function getVideo(env: Env, id: string): Promise<VideoRow | null> {
  return env.DB.prepare("SELECT * FROM videos WHERE id = ?1").bind(id).first<VideoRow>();
}

async function deleteObjects(env: Env, id: string): Promise<void> {
  await env.BUCKET.delete(Object.keys(FILES).map((name) => `${id}/${name}`));
}

function text(body: string, status = 200): Response {
  return new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}

function notFound(): Response {
  return text("Not found", 404);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function html(page: { body: string; nonce: string }, status = 200): Response {
  const csp = [
    "default-src 'none'",
    "media-src 'self'",
    "img-src 'self'",
    `style-src 'nonce-${page.nonce}'`,
    `script-src 'nonce-${page.nonce}'`,
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join("; ");
  return new Response(page.body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "content-security-policy": csp,
      "cache-control": "no-store",
    },
  });
}
