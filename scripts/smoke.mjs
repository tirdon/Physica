// Headless smoke test: instantiate the wasm bundle under Bun (no GPU) and let
// the Swift entry print the demo timeline. Build the bundle first:
//   swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js js --use-cdn --output js
import { instantiate } from "../js/instantiate.js";
import { defaultNodeSetup } from "../js/platforms/node.js";

const options = await defaultNodeSetup({});
await instantiate(options);
// Give the JS event loop a beat for the Swift Task to run.
await new Promise((resolve) => setTimeout(resolve, 500));
