// GPU-free smoke for the Example0 story bundle: instantiate under Bun (no DOM,
// no GPU) and let the Swift entry log the story structure. Build first:
//   swift package --swift-sdk 6.3-RELEASE-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-example0 js --use-cdn \
//     --output js-example0 --product Example0
import { instantiate } from "../js-example0/instantiate.js";
import { defaultNodeSetup } from "../js-example0/platforms/node.js";

const options = await defaultNodeSetup({});
await instantiate(options);
// Give the JS event loop a beat for the Swift Task (font/MathJax probes) to run.
await new Promise((resolve) => setTimeout(resolve, 1200));
