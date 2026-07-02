// GPU-free smoke for the Example2 equation-story bundle: instantiate under Bun
// (no DOM, no GPU) and let the Swift entry log the story structure. Build first:
//   swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-example2 js --use-cdn \
//     --output js-example2 --product Example2
import { instantiate } from "../js-example2/instantiate.js";
import { defaultNodeSetup } from "../js-example2/platforms/node.js";

const options = await defaultNodeSetup({});
await instantiate(options);
// Give the JS event loop a beat for the Swift Task (font/MathJax probes) to run.
await new Promise((resolve) => setTimeout(resolve, 1200));
