// Makes YANA's icons from the drawing beside this file, icon.svg, which is the whole 1024 square with no corners cut.
//
//   node scripts/icon/make.js
//
// It writes:
//   Resources/AppIcon.png                                           the Mac icon: the drawing in Apple's rounded
//                                                                   square, with its shadow, on a clear 1024 canvas
//   iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png    the iPhone icon: the whole square, nothing clear
//                                                                   (iOS rounds the corners, and the App Store turns
//                                                                   down an icon with any transparency)
//   docs/icon.png                                                   the Mac icon at 256, for the README
//
// It needs Node with Playwright and its Chromium (npm install playwright, npx playwright install chromium), which
// draws the SVG. Nothing in the app's build uses this: build.sh starts from Resources/AppIcon.png.
const { chromium } = require('playwright');
const fs = require('fs');
const os = require('os');
const path = require('path');

const root = path.resolve(__dirname, '..', '..');
const drawing = 'file://' + path.join(__dirname, 'icon.svg');

// The Mac icon's shape: an 824 rounded square with corner radius 185.4 (Apple's template for a 1024 canvas), with
// the continuous corners Apple draws, which ease into the sides rather than meeting them as a quarter circle. The
// numbers are the well-known ones for UIBezierPath's rounded rectangle, in units of the radius.
function iconShape(size, r) {
  const f = n => n.toFixed(3);
  const corner = {
    tr: (x, y) => `${f(size - x * r)} ${f(y * r)}`,
    br: (x, y) => `${f(size - y * r)} ${f(size - x * r)}`,
    bl: (x, y) => `${f(x * r)} ${f(size - y * r)}`,
    tl: (x, y) => `${f(y * r)} ${f(x * r)}`,
  };
  // One corner, going clockwise, from where the straight side ends to where the next one starts
  const turn = p => `L ${p(1.528665, 0)} ` +
    `C ${p(1.08849296, 0)} ${p(0.86840694, 0)} ${p(0.63149379, 0.07491139)} ` +
    `C ${p(0.37282383, 0.16905956)} ${p(0.16905956, 0.37282383)} ${p(0.07491139, 0.63149379)} ` +
    `C ${p(0, 0.86840694)} ${p(0, 1.08849296)} ${p(0, 1.52866495)} `;
  return `path('M ${f(1.528665 * r)} 0 ${turn(corner.tr)}${turn(corner.br)}${turn(corner.bl)}${turn(corner.tl)}Z')`;
}

const whole = `<img src="${drawing}" style="display:block;width:1024px;height:1024px">`;
const mac = `<div style="width:1024px;height:1024px;position:relative;filter:drop-shadow(0 12px 24px rgba(0,0,0,.35))">
  <div style="position:absolute;left:100px;top:100px;width:824px;height:824px;clip-path:${iconShape(824, 185.4)}">
    <img src="${drawing}" style="display:block;width:824px;height:824px">
  </div></div>`;

(async () => {
  const browser = await chromium.launch();
  // A page made with setContent can't load a file: picture, so the page is a file too
  const pageFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'yana-icon-')), 'page.html');
  async function shoot(body, pixels, clear, to) {
    const page = await browser.newPage({ viewport: { width: pixels, height: pixels }, deviceScaleFactor: 1 });
    // The drawing is laid out at 1024 and scaled as a whole, so every size is the same picture
    fs.writeFileSync(pageFile, `<html><body style="margin:0;background:transparent;overflow:hidden">
      <div style="width:1024px;height:1024px;transform-origin:0 0;transform:scale(${pixels / 1024})">${body}</div>
      </body></html>`);
    await page.goto('file://' + pageFile);
    await page.evaluate(() => Promise.all([...document.images].map(image => image.decode())));
    await page.screenshot({ path: path.join(root, to), omitBackground: clear });
    await page.close();
    console.log('wrote', to);
  }
  await shoot(mac, 1024, true, 'Resources/AppIcon.png');
  await shoot(whole, 1024, false, 'iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png');
  await shoot(mac, 256, true, 'docs/icon.png');
  fs.rmSync(path.dirname(pageFile), { recursive: true, force: true });
  await browser.close();
})();
