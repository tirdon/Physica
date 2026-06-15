// Headless-WebGPU screenshots of story.html — the renderer/web verification drill
// from CLAUDE.md. Launches system Chrome with ANGLE-metal + unsafe-webgpu against
// the running bun server, drives the story with arrow keys, and writes a PNG per
// slide so the layout can be eyeballed. Run: `bun bunserver.js` then `bun scripts/shot.mjs`.
import puppeteer from "puppeteer-core";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const URL = "http://localhost:3000/story.html";
const OUT = "/tmp/physica-shots";
import { mkdirSync } from "node:fs";
mkdirSync(OUT, { recursive: true });

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  args: [
    "--headless=new",
    "--use-angle=metal",
    "--enable-unsafe-webgpu",
    "--enable-features=Vulkan",
    "--no-sandbox",
  ],
});
const page = await browser.newPage();
await page.setViewport({ width: 1000, height: 640, deviceScaleFactor: 2 });

const logs = [];
page.on("console", (m) => logs.push(m.text()));
page.on("pageerror", (e) => logs.push("PAGEERROR " + e.message));

await page.goto(URL, { waitUntil: "networkidle0", timeout: 30000 });

// Wait for the story runtime (or a renderer failure) to report on the console.
for (let i = 0; i < 60; i++) {
  if (logs.some((l) => /story runtime running|renderer unavailable/.test(l))) break;
  await new Promise((r) => setTimeout(r, 250));
}
await new Promise((r) => setTimeout(r, 1500)); // settle the first frame

async function shot(name) {
  await new Promise((r) => setTimeout(r, 1600)); // let any tween settle
  const caption = await page.$eval("#story-caption", (e) => e.textContent).catch(() => "");
  const hud = await page.$eval("#story-hud", (e) => e.textContent).catch(() => "");
  await page.screenshot({ path: `${OUT}/${name}.png` });
  console.log(`shot ${name}: hud="${hud}" caption="${caption}"`);
}

await page.bringToFront();
await page.mouse.click(500, 40); // focus the document so window keydown fires (empty top-center)
await new Promise((r) => setTimeout(r, 400));
await shot("0-start");
// Down lands on each slide's fully-built end (deferred-clear slides rest just
// before their boundary), so the first Down completes Setup. Four reach Period.
for (const name of ["1-setup-end", "2-forces", "3-solve", "4-period-end"]) {
  await page.keyboard.press("ArrowDown");
  await shot(name);
}
// Step backwards through Period's beats to catch the morph, then the sin θ graph.
await page.keyboard.press("ArrowLeft");
await shot("4c-period-morph");
await page.keyboard.press("ArrowLeft");
await shot("4b-period-graph");

console.log("\n--- console (filtered) ---");
console.log(
  logs.filter((l) => /Physica|error|webGPU|story|size/i.test(l)).slice(-25).join("\n"),
);
await browser.close();
