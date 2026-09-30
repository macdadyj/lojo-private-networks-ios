"use strict";

// Prints the phone pairing code for this site gateway as a terminal QR and writes a PNG.
// The code holds only public data: network name, the two HTTPS addresses and the SHA-256
// fingerprint of the site CA certificate. The phone uses the fingerprint to pin that CA.
//   node pair.js <ca.crt> <out.png>   (SITE_NAME, LAN_URL, OVERLAY_URL from the environment)
const crypto = require("crypto");
const fs = require("fs");
const QRCode = require("qrcode");

const [caPath, pngPath] = process.argv.slice(2);
if (!caPath || !pngPath || !process.env.SITE_NAME) {
  console.error("usage: SITE_NAME=... LAN_URL=... OVERLAY_URL=... node pair.js <ca.crt> <out.png>");
  process.exit(2);
}

const der = new crypto.X509Certificate(fs.readFileSync(caPath)).raw;
const fingerprint = crypto.createHash("sha256").update(der).digest("hex");

const params = new URLSearchParams({
  v: "1",
  n: process.env.SITE_NAME,
  lan: process.env.LAN_URL || "",
  ov: process.env.OVERLAY_URL || "",
  ca: fingerprint,
});
const code = "lojo://pair?" + params.toString();

(async () => {
  await QRCode.toFile(pngPath, code, { errorCorrectionLevel: "M", margin: 2, width: 560 });
  const term = await QRCode.toString(code, { type: "terminal", small: true, errorCorrectionLevel: "M" });
  process.stdout.write(term);
  console.log("\nPairing code (paste into the app if you can't scan):\n" + code);
  console.log("\nSite CA SHA-256: " + fingerprint.match(/../g).join(":").toUpperCase());
  console.log("QR image: " + pngPath);
})();
