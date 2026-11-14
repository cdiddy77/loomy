import type { VideoRow } from "./index";

export interface Page {
  body: string;
  nonce: string;
}

const STYLE = `
:root { color-scheme: light dark; --bg: #fafafa; --fg: #18181b; --muted: #6b6b76; --line: #e2e2e7; --hover: #ededf1; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #111113; --fg: #ededf0; --muted: #9a9aa6; --line: #2a2a30; --hover: #1d1d21; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 system-ui, -apple-system, sans-serif; }
main { max-width: 960px; margin: 0 auto; padding: 24px 16px 64px; }
video { display: block; width: 100%; max-height: 80vh; background: #000; border-radius: 10px; }
h1 { font-size: 1.4rem; line-height: 1.3; margin: 20px 0 4px; overflow-wrap: anywhere; }
h2 { font-size: 1rem; margin: 32px 0 8px; }
.meta { color: var(--muted); margin: 0; font-size: 0.9rem; }
.cues { list-style: none; margin: 0; padding: 0; border-top: 1px solid var(--line); }
.cues button { display: flex; gap: 12px; width: 100%; padding: 8px 4px; border: 0; border-bottom: 1px solid var(--line);
  background: none; color: inherit; font: inherit; text-align: left; cursor: pointer; }
.cues button:hover, .cues button.active { background: var(--hover); }
.cues time { color: var(--muted); font-variant-numeric: tabular-nums; flex: none; width: 4.5ch; }
.message { text-align: center; padding-top: 20vh; }
`;

// The script builds the transcript list from the captions track.
const SCRIPT = `
const video = document.querySelector("video");
const track = document.querySelector("track");
if (video && track) {
  const section = document.getElementById("transcript");
  const list = section.querySelector("ol");
  const clock = (s) => Math.floor(s / 60) + ":" + String(Math.floor(s % 60)).padStart(2, "0");
  const build = () => {
    const cues = track.track.cues;
    if (!cues || !cues.length || list.children.length) return;
    for (const cue of cues) {
      const item = document.createElement("li");
      const button = document.createElement("button");
      const time = document.createElement("time");
      const text = document.createElement("span");
      time.textContent = clock(cue.startTime);
      text.textContent = cue.text.replace(/<[^>]*>/g, "");
      button.append(time, text);
      button.addEventListener("click", () => { video.currentTime = cue.startTime; video.play(); });
      item.append(button);
      list.append(item);
      cue.addEventListener("enter", () => button.classList.add("active"));
      cue.addEventListener("exit", () => button.classList.remove("active"));
    }
    section.hidden = false;
  };
  // The browser loads the cues only when the track is not disabled.
  if (track.track.mode === "disabled") track.track.mode = "hidden";
  track.addEventListener("load", build);
  build();
}
`;

export function renderWatchPage(video: VideoRow, origin: string): Page {
  const nonce = makeNonce();
  const base = `${origin}/v/${video.id}`;
  const title = escapeHtml(video.title);
  const date = new Date(video.created_at).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
  const meta = [date, formatDuration(video.duration_s)].filter(Boolean).join(" · ");
  const track = video.has_transcript
    ? `<track kind="captions" src="${base}/captions.vtt" srclang="en" label="English">`
    : "";

  const body = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${title}</title>
<meta property="og:title" content="${title}">
<meta property="og:type" content="video.other">
<meta property="og:image" content="${base}/thumb.jpg">
<meta property="og:video" content="${base}/video.mp4">
<meta property="og:video:type" content="video/mp4">
<style nonce="${nonce}">${STYLE}</style>
</head>
<body>
<main>
<video controls playsinline preload="metadata" poster="${base}/thumb.jpg">
<source src="${base}/video.mp4" type="video/mp4">
${track}
</video>
<h1>${title}</h1>
<p class="meta">${escapeHtml(meta)}</p>
<section id="transcript" hidden>
<h2>Transcript</h2>
<ol class="cues"></ol>
</section>
</main>
<script nonce="${nonce}">${SCRIPT}</script>
</body>
</html>`;
  return { body, nonce };
}

export function renderMessagePage(heading: string, message: string): Page {
  const nonce = makeNonce();
  const body = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${escapeHtml(heading)}</title>
<style nonce="${nonce}">${STYLE}</style>
</head>
<body>
<main class="message">
<h1>${escapeHtml(heading)}</h1>
<p class="meta">${escapeHtml(message)}</p>
</main>
</body>
</html>`;
  return { body, nonce };
}

function makeNonce(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return btoa(String.fromCharCode(...bytes));
}

function formatDuration(seconds: number): string {
  if (!seconds || seconds < 1) return "";
  const total = Math.round(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
