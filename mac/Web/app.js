// VR Desktop – WebXR client for the Quest browser.
// Connects to the Mac over WebRTC (signaling: one POST /offer), shows each streamed Mac window
// as a panel in 3D space and sends mouse/keyboard input back over the "ctl" data channel.
import * as THREE from './three.module.min.js';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const SLOTS = 4;                 // must match StreamSession.maxSlots on the Mac
const METERS_PER_POINT = 1 / 1000; // default panel width: 1000 pt wide window -> 1 m
const DEFAULT_DISTANCE = 1.4;
const TITLE_H = 0.06;
const MOVE_INTERVAL_MS = 16;     // mouse-move throttle

// ---------------------------------------------------------------------------
// DOM / status
// ---------------------------------------------------------------------------
const statusEl = document.getElementById('status');
const enterBtn = document.getElementById('enter');
const menuBtn = document.getElementById('menu');
let statusText = 'Načítám…';
function setStatus(t) {
  statusText = t;
  statusEl.textContent = t;
  menu.redraw();
}

// ---------------------------------------------------------------------------
// Three.js scene
// ---------------------------------------------------------------------------
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.xr.enabled = true;
renderer.xr.setReferenceSpaceType('local-floor');
renderer.xr.setFramebufferScaleFactor(1.2); // a bit sharper text on Quest 2
document.body.appendChild(renderer.domElement);

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0f1317);
const camera = new THREE.PerspectiveCamera(70, window.innerWidth / window.innerHeight, 0.01, 100);
camera.position.set(0, 1.6, 0);
scene.add(camera);

const grid = new THREE.GridHelper(20, 40, 0x2b3540, 0x1b232b);
scene.add(grid);

window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});

function headPosition(out = new THREE.Vector3()) {
  const cam = renderer.xr.isPresenting ? renderer.xr.getCamera() : camera;
  return cam.getWorldPosition(out);
}
function headForward(out = new THREE.Vector3()) {
  const cam = renderer.xr.isPresenting ? renderer.xr.getCamera() : camera;
  cam.getWorldDirection(out);
  out.y = 0;
  if (out.lengthSq() < 1e-6) out.set(0, 0, -1);
  return out.normalize();
}

// ---------------------------------------------------------------------------
// Canvas text helper
// ---------------------------------------------------------------------------
function makeCanvasTexture(w, h) {
  const canvas = document.createElement('canvas');
  canvas.width = w; canvas.height = h;
  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 4;
  return { canvas, ctx: canvas.getContext('2d'), tex };
}
function ellipsize(ctx, text, maxW) {
  if (ctx.measureText(text).width <= maxW) return text;
  while (text.length > 1 && ctx.measureText(text + '…').width > maxW) text = text.slice(0, -1);
  return text + '…';
}

// ---------------------------------------------------------------------------
// Connection state
// ---------------------------------------------------------------------------
let pc = null;
let dc = null;
let macName = '';
let maxWindows = SLOTS;
let windows = [];                      // [{id,title,app,width,height}]
let slots = new Array(SLOTS).fill(0);  // window id per video slot
const videos = [];                     // per slot: {video, texture, frames}
const panels = new Map();              // window id -> Panel

function send(obj) {
  if (dc && dc.readyState === 'open') dc.send(JSON.stringify(obj));
}
function windowInfo(id) { return windows.find(w => w.id === id); }
function selectedIds() { return slots.filter(id => id !== 0); }
function setSelection(ids) { send({ type: 'select', windowIds: ids.slice(0, maxWindows) }); }

// ---------------------------------------------------------------------------
// Panels
// ---------------------------------------------------------------------------
const interactive = [];  // meshes the pointers can hit

class Panel {
  constructor(id) {
    this.id = id;
    this.width = 1.0;
    this.aspect = 10 / 16;
    this.group = new THREE.Group();
    this.slot = -1;

    this.material = new THREE.MeshBasicMaterial({ color: 0x222a33, toneMapped: false });
    this.content = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), this.material);
    this.content.userData = { kind: 'content', panel: this };
    this.group.add(this.content);

    this.titleTex = makeCanvasTexture(1024, 64);
    this.title = new THREE.Mesh(new THREE.PlaneGeometry(1, 1),
      new THREE.MeshBasicMaterial({ map: this.titleTex.tex, transparent: true, toneMapped: false }));
    this.title.userData = { kind: 'title', panel: this };
    this.group.add(this.title);

    // Hover outline
    this.frame = new THREE.Mesh(new THREE.PlaneGeometry(1, 1),
      new THREE.MeshBasicMaterial({ color: 0x3b82f6, toneMapped: false }));
    this.frame.position.z = -0.002;
    this.frame.visible = false;
    this.group.add(this.frame);

    interactive.push(this.content, this.title);
    scene.add(this.group);
    this.restoreLayout();
    this.layout();
    this.drawTitle();
  }

  get height() { return this.width * this.aspect; }
  get info() { return windowInfo(this.id) || { title: 'Okno ' + this.id, app: '', width: 1000, height: 625 }; }
  get key() { const i = this.info; return 'vrd:' + i.app + '|' + i.title; }

  layout() {
    const w = this.width, h = this.height;
    this.content.scale.set(w, h, 1);
    this.title.scale.set(w, TITLE_H, 1);
    this.title.position.set(0, h / 2 + TITLE_H / 2 + 0.008, 0);
    this.frame.scale.set(w + 0.02, h + 0.02, 1);
  }

  drawTitle(hoverClose = false) {
    const { ctx, canvas, tex } = this.titleTex;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = 'rgba(30,38,46,0.92)';
    roundRect(ctx, 0, 0, canvas.width, canvas.height, 18); ctx.fill();
    ctx.fillStyle = '#e8edf2';
    ctx.font = '600 32px system-ui, sans-serif';
    ctx.textBaseline = 'middle';
    const i = this.info;
    const label = !i.app || i.title.includes(i.app) ? i.title : i.app + ' — ' + i.title;
    ctx.fillText(ellipsize(ctx, label, canvas.width - 120), 24, canvas.height / 2);
    // close button in the right-most 64 px
    ctx.fillStyle = hoverClose ? '#ef4444' : '#3a4450';
    roundRect(ctx, canvas.width - 72, 8, 60, 48, 12); ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.font = '600 34px system-ui, sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('×', canvas.width - 42, canvas.height / 2 + 1);
    ctx.textAlign = 'left';
    tex.needsUpdate = true;
  }

  /** uv on the title bar -> is it the close button? */
  isClose(uv) { return uv.x > 1 - 72 / 1024; }

  setVideo(slot) {
    this.slot = slot;
    const v = videos[slot];
    if (v && v.texture) {
      this.material.map = v.texture;
      this.material.color.set(0xffffff);
      this.material.needsUpdate = true;
      this.updateAspect();
    } else {
      this.material.map = null;
      this.material.color.set(0x222a33);
      this.material.needsUpdate = true;
    }
  }

  updateAspect() {
    const v = videos[this.slot];
    if (v && v.video.videoWidth > 0) {
      const a = v.video.videoHeight / v.video.videoWidth;
      if (Math.abs(a - this.aspect) > 0.001) { this.aspect = a; this.layout(); }
    }
  }

  setHover(on) { this.frame.visible = on; }

  restoreLayout() {
    let saved = null;
    try { saved = JSON.parse(localStorage.getItem(this.key) || 'null'); } catch (e) { /* ignore */ }
    const i = this.info;
    this.aspect = i.height / i.width || this.aspect;
    if (saved && saved.p) {
      this.group.position.fromArray(saved.p);
      this.width = saved.w || this.width;
    } else {
      this.width = THREE.MathUtils.clamp(i.width * METERS_PER_POINT, 0.5, 2.0);
      // Spread new panels in an arc in front of the user.
      const n = panels.size;
      const yaw = [0, 0.85, -0.85, 1.7, -1.7][n % 5];
      const fwd = headForward().applyAxisAngle(new THREE.Vector3(0, 1, 0), yaw);
      const head = headPosition();
      this.group.position.copy(head).addScaledVector(fwd, DEFAULT_DISTANCE);
      this.group.position.y = Math.max(head.y, 1.2);
    }
    this.faceUser();
  }

  saveLayout() {
    try {
      localStorage.setItem(this.key, JSON.stringify({ p: this.group.position.toArray(), w: this.width }));
    } catch (e) { /* ignore */ }
  }

  faceUser() {
    const head = headPosition();
    head.y = THREE.MathUtils.lerp(head.y, this.group.position.y, 0.3); // mostly upright
    this.group.lookAt(head);
  }

  dispose() {
    this.saveLayout();
    scene.remove(this.group);
    for (const m of [this.content, this.title]) {
      const i = interactive.indexOf(m);
      if (i >= 0) interactive.splice(i, 1);
    }
    this.titleTex.tex.dispose();
  }
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function syncPanels() {
  const wanted = new Set(selectedIds());
  for (const [id, p] of panels) {
    if (!wanted.has(id)) { p.dispose(); panels.delete(id); }
  }
  slots.forEach((id, slot) => {
    if (!id) return;
    let p = panels.get(id);
    if (!p) { p = new Panel(id); panels.set(id, p); }
    if (p.slot !== slot || p.material.map !== (videos[slot] && videos[slot].texture)) p.setVideo(slot);
    p.drawTitle();
  });
  menu.redraw();
}

// ---------------------------------------------------------------------------
// Window list menu (in VR and 2D)
// ---------------------------------------------------------------------------
const menu = {
  rows: 12,
  page: 0,
  open: false,
  mesh: null,
  tex: null,
  init() {
    this.tex = makeCanvasTexture(1024, 1100);
    this.mesh = new THREE.Mesh(new THREE.PlaneGeometry(0.62, 0.62 * 1100 / 1024),
      new THREE.MeshBasicMaterial({ map: this.tex.tex, transparent: true, toneMapped: false }));
    this.mesh.userData = { kind: 'menu' };
    this.mesh.visible = false;
    scene.add(this.mesh);
    interactive.push(this.mesh);
    this.redraw();
  },
  toggle(force) {
    this.open = force === undefined ? !this.open : force;
    if (this.open) {
      send({ type: 'listWindows' });
      const head = headPosition();
      const fwd = headForward();
      this.mesh.position.copy(head).addScaledVector(fwd, 0.8);
      this.mesh.position.y = head.y - 0.15;
      this.mesh.lookAt(head);
    }
    this.mesh.visible = this.open;
    this.redraw();
  },
  // Layout constants (canvas px)
  HEADER: 150, ROW: 66, FOOTER: 90,
  redraw() {
    if (!this.tex) return;
    const { ctx, canvas, tex } = this.tex;
    const W = canvas.width, H = canvas.height;
    ctx.clearRect(0, 0, W, H);
    ctx.fillStyle = 'rgba(20,26,32,0.95)';
    roundRect(ctx, 0, 0, W, H, 36); ctx.fill();
    ctx.fillStyle = '#e8edf2';
    ctx.font = '700 46px system-ui, sans-serif';
    ctx.textBaseline = 'middle';
    ctx.fillText('Okna z Macu' + (macName ? ' · ' + macName : ''), 40, 56);
    ctx.font = '28px system-ui, sans-serif';
    ctx.fillStyle = '#9aa7b4';
    ctx.fillText(ellipsize(ctx, statusText + ` · vybráno ${selectedIds().length}/${maxWindows}`, W - 80), 40, 110);

    const start = this.page * this.rows;
    const list = windows.slice(start, start + this.rows);
    list.forEach((w, i) => {
      const y = this.HEADER + i * this.ROW;
      const on = selectedIds().includes(w.id);
      ctx.fillStyle = on ? '#1d4ed8' : (i === this.hoverRow ? '#2a333d' : '#1c232b');
      roundRect(ctx, 24, y + 4, W - 48, this.ROW - 8, 14); ctx.fill();
      ctx.fillStyle = '#fff';
      ctx.font = '600 30px system-ui, sans-serif';
      ctx.fillText(on ? '✓' : '', 44, y + this.ROW / 2);
      ctx.fillText(ellipsize(ctx, w.title, W - 420), 88, y + this.ROW / 2);
      ctx.font = '24px system-ui, sans-serif';
      ctx.fillStyle = '#b8c4d0';
      ctx.textAlign = 'right';
      ctx.fillText(ellipsize(ctx, w.app, 280), W - 44, y + this.ROW / 2);
      ctx.textAlign = 'left';
    });
    if (windows.length === 0) {
      ctx.fillStyle = '#9aa7b4';
      ctx.font = '30px system-ui, sans-serif';
      ctx.fillText(dc && dc.readyState === 'open' ? 'Žádná okna k dispozici.' : 'Čekám na spojení s Macem…', 40, this.HEADER + 40);
    }
    // footer: paging + close
    const fy = H - this.FOOTER;
    const pages = Math.max(1, Math.ceil(windows.length / this.rows));
    ctx.font = '600 30px system-ui, sans-serif';
    const btn = (x, label, enabled) => {
      ctx.fillStyle = enabled ? '#2f3a46' : '#1c232b';
      roundRect(ctx, x, fy + 12, 200, 62, 14); ctx.fill();
      ctx.fillStyle = enabled ? '#fff' : '#5b6672';
      ctx.textAlign = 'center';
      ctx.fillText(label, x + 100, fy + 44);
      ctx.textAlign = 'left';
    };
    btn(24, '◀ Zpět', this.page > 0);
    btn(244, 'Další ▶', this.page < pages - 1);
    btn(W - 224, 'Zavřít', true);
    ctx.fillStyle = '#9aa7b4';
    ctx.font = '26px system-ui, sans-serif';
    ctx.fillText(`${this.page + 1}/${pages}`, 470, fy + 44);
    tex.needsUpdate = true;
  },
  hoverRow: -1,
  /** Map uv to an action. */
  hit(uv) {
    const W = 1024, H = 1100;
    const x = uv.x * W, y = (1 - uv.y) * H;
    if (y > H - this.FOOTER) {
      if (x < 224) return { action: 'prev' };
      if (x > 244 && x < 444) return { action: 'next' };
      if (x > W - 224) return { action: 'close' };
      return null;
    }
    const row = Math.floor((y - this.HEADER) / this.ROW);
    if (row >= 0 && row < this.rows && y >= this.HEADER) {
      const w = windows[this.page * this.rows + row];
      if (w) return { action: 'toggle', id: w.id, row };
    }
    return null;
  },
  hover(uv) {
    const h = uv ? this.hit(uv) : null;
    const row = h && h.action === 'toggle' ? h.row : -1;
    if (row !== this.hoverRow) { this.hoverRow = row; this.redraw(); }
  },
  click(uv) {
    const h = this.hit(uv);
    if (!h) return;
    const pages = Math.max(1, Math.ceil(windows.length / this.rows));
    if (h.action === 'prev') this.page = Math.max(0, this.page - 1);
    else if (h.action === 'next') this.page = Math.min(pages - 1, this.page + 1);
    else if (h.action === 'close') this.toggle(false);
    else if (h.action === 'toggle') {
      const sel = selectedIds();
      if (sel.includes(h.id)) setSelection(sel.filter(x => x !== h.id));
      else if (sel.length < maxWindows) setSelection([...sel, h.id]);
    }
    this.redraw();
  },
};
menu.init();
menuBtn.addEventListener('click', () => menu.toggle());

// ---------------------------------------------------------------------------
// Pointer logic shared by XR controllers and the desktop mouse
// ---------------------------------------------------------------------------
const raycaster = new THREE.Raycaster();
const tmpMat = new THREE.Matrix4();
const tmpVec = new THREE.Vector3();

class Pointer {
  constructor(name) {
    this.name = name;
    this.hover = null;       // {kind, panel, uv, point, distance}
    this.dragPanel = null;   // panel receiving a mouse drag (button held)
    this.dragButton = 0;
    this.grab = null;        // {panel, offset: Matrix4, dist}
    this.lastMove = 0;
    this.lastUV = null;
    this.scrollAcc = { x: 0, y: 0 };
  }

  /** Raycast against interactive meshes. ray: THREE.Ray in world space. */
  update(ray) {
    raycaster.ray.copy(ray);
    raycaster.far = 20;
    const visible = interactive.filter(m => m.visible !== false && (m.userData.kind !== 'menu' || menu.open));
    const hits = raycaster.intersectObjects(visible, false);
    const h = hits[0];
    const prev = this.hover;
    this.hover = h ? { kind: h.object.userData.kind, panel: h.object.userData.panel, uv: h.uv, point: h.point, distance: h.distance } : null;

    if (prev && prev.panel && (!this.hover || prev.panel !== this.hover.panel)) prev.panel.setHover(false);
    if (this.hover && this.hover.panel) this.hover.panel.setHover(true);
    if (prev && prev.kind === 'title' && (!this.hover || this.hover.kind !== 'title' || this.hover.panel !== prev.panel)) prev.panel.drawTitle(false);
    if (this.hover && this.hover.kind === 'title') this.hover.panel.drawTitle(this.hover.panel.isClose(this.hover.uv));
    if (this.hover && this.hover.kind === 'menu') menu.hover(this.hover.uv);
    else if (prev && prev.kind === 'menu') menu.hover(null);

    // Mouse move / drag
    const now = performance.now();
    if (this.dragPanel) {
      const uv = this.uvOnPanel(this.dragPanel, ray);
      if (uv && now - this.lastMove > MOVE_INTERVAL_MS) {
        this.sendMouse(this.dragPanel, uv, 'move');
        this.lastMove = now;
      }
    } else if (this.hover && this.hover.kind === 'content' && now - this.lastMove > MOVE_INTERVAL_MS * 2) {
      const uv = this.hover.uv;
      if (!this.lastUV || Math.abs(uv.x - this.lastUV.x) + Math.abs(uv.y - this.lastUV.y) > 0.0005) {
        this.sendMouse(this.hover.panel, uv, 'move');
        this.lastMove = now;
      }
    }
    return h;
  }

  /** Intersect the ray with the (infinite) panel plane -> uv, clamped. */
  uvOnPanel(panel, ray) {
    const m = panel.content.matrixWorld;
    const normal = new THREE.Vector3(0, 0, 1).transformDirection(m);
    const plane = new THREE.Plane().setFromNormalAndCoplanarPoint(normal, panel.content.getWorldPosition(tmpVec));
    const p = ray.intersectPlane(plane, new THREE.Vector3());
    if (!p) return null;
    const local = panel.content.worldToLocal(p);
    return { x: THREE.MathUtils.clamp(local.x + 0.5, 0, 1), y: THREE.MathUtils.clamp(local.y + 0.5, 0, 1) };
  }

  sendMouse(panel, uv, action, button = 0) {
    this.lastUV = { x: uv.x, y: uv.y };
    send({ t: 'mouse', w: panel.id, x: uv.x, y: 1 - uv.y, a: action, b: button });
  }

  /** Primary button (trigger / left mouse). Returns true if handled. */
  press(button = 0) {
    const h = this.hover;
    if (!h) return false;
    if (h.kind === 'menu') { if (button === 0) menu.click(h.uv); return true; }
    if (h.kind === 'title') {
      if (button === 0 && h.panel.isClose(h.uv)) {
        setSelection(selectedIds().filter(id => id !== h.panel.id));
        return true;
      }
      return 'grab';
    }
    if (h.kind === 'content') {
      this.dragPanel = h.panel;
      this.dragButton = button;
      this.sendMouse(h.panel, h.uv, 'down', button);
      return true;
    }
    return false;
  }

  release(ray) {
    if (this.dragPanel) {
      const uv = this.uvOnPanel(this.dragPanel, ray) || this.lastUV;
      if (uv) this.sendMouse(this.dragPanel, uv, 'up', this.dragButton);
      this.dragPanel = null;
    }
  }

  click(button) {
    const h = this.hover;
    if (h && h.kind === 'content') {
      this.sendMouse(h.panel, h.uv, 'down', button);
      this.sendMouse(h.panel, h.uv, 'up', button);
    }
  }

  scroll(dx, dy) {
    const h = this.hover;
    if (!h || h.kind !== 'content') return;
    this.scrollAcc.x += dx; this.scrollAcc.y += dy;
    const sx = Math.trunc(this.scrollAcc.x), sy = Math.trunc(this.scrollAcc.y);
    if (sx || sy) {
      this.scrollAcc.x -= sx; this.scrollAcc.y -= sy;
      send({ t: 'scroll', w: h.panel.id, x: h.uv.x, y: 1 - h.uv.y, dx: sx, dy: sy });
    }
  }

  /** Grab the hovered panel, attached to `holder` (controller Object3D). */
  startGrab(holder) {
    const h = this.hover;
    if (!h || !h.panel) return false;
    holder.updateMatrixWorld();
    this.grab = { panel: h.panel, offset: new THREE.Matrix4().copy(holder.matrixWorld).invert().multiply(h.panel.group.matrixWorld) };
    return true;
  }

  updateGrab(holder, stickX, stickY, dt) {
    if (!this.grab) return;
    const g = this.grab;
    // Thumbstick: push/pull along the controller (y) and resize (x).
    if (Math.abs(stickY) > 0.15) {
      const t = new THREE.Vector3().setFromMatrixPosition(g.offset);
      const len = t.length();
      const newLen = THREE.MathUtils.clamp(len * (1 + -stickY * dt * 1.5), 0.25, 8);
      if (len > 1e-4) { t.multiplyScalar(newLen / len); g.offset.setPosition(t); }
    }
    if (Math.abs(stickX) > 0.15) {
      g.panel.width = THREE.MathUtils.clamp(g.panel.width * (1 + stickX * dt * 1.2), 0.2, 5);
      g.panel.layout();
    }
    tmpMat.multiplyMatrices(holder.matrixWorld, g.offset);
    g.panel.group.position.setFromMatrixPosition(tmpMat);
    g.panel.faceUser();
  }

  endGrab() {
    if (this.grab) { this.grab.panel.saveLayout(); this.grab = null; }
  }
}

// ---------------------------------------------------------------------------
// XR controllers
// ---------------------------------------------------------------------------
const controllers = [];
for (let i = 0; i < 2; i++) {
  const c = renderer.xr.getController(i);
  const lineGeo = new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(0, 0, 0), new THREE.Vector3(0, 0, -1)]);
  const line = new THREE.Line(lineGeo, new THREE.LineBasicMaterial({ color: 0x9cc3ff, transparent: true, opacity: 0.7 }));
  line.scale.z = 3;
  c.add(line);
  const dot = new THREE.Mesh(new THREE.SphereGeometry(0.006, 12, 8), new THREE.MeshBasicMaterial({ color: 0xffffff }));
  dot.visible = false;
  scene.add(dot);
  const state = { c, line, dot, pointer: new Pointer('xr' + i), source: null, buttons: [], squeezing: false };
  c.addEventListener('connected', e => { state.source = e.data; });
  c.addEventListener('disconnected', () => { state.source = null; });
  c.addEventListener('selectstart', () => {
    const r = state.pointer.press(0);
    if (r === 'grab') { state.pointer.startGrab(c); state.grabByTrigger = true; }
  });
  c.addEventListener('selectend', () => {
    if (state.grabByTrigger) { state.pointer.endGrab(); state.grabByTrigger = false; }
    state.pointer.release(rayFromController(c));
  });
  c.addEventListener('squeezestart', () => { state.pointer.startGrab(c); });
  c.addEventListener('squeezeend', () => { state.pointer.endGrab(); });
  scene.add(c);
  controllers.push(state);
}

function rayFromController(c) {
  raycaster.setFromXRController(c);
  return raycaster.ray.clone();
}

function updateControllers(dt) {
  for (const s of controllers) {
    if (!s.source) { s.dot.visible = false; continue; }
    const ray = rayFromController(s.c);
    const h = s.pointer.update(ray);
    s.line.scale.z = h ? h.distance : 3;
    s.dot.visible = !!h;
    if (h) s.dot.position.copy(h.point);

    const gp = s.source.gamepad;
    if (!gp) continue;
    const sx = gp.axes[2] || 0, sy = gp.axes[3] || 0;
    if (s.pointer.grab) {
      s.pointer.updateGrab(s.c, sx, sy, dt);
    } else if (Math.abs(sy) > 0.15 || Math.abs(sx) > 0.15) {
      // Thumbstick over a window scrolls it (stick up = scroll up).
      const speed = 1400 * dt;
      s.pointer.scroll(-sx * speed * Math.abs(sx), -sy * speed * Math.abs(sy));
    }
    // Buttons: 4 = A/X, 5 = B/Y
    const pressed = gp.buttons.map(b => b.pressed);
    if (pressed[4] && !s.buttons[4]) s.pointer.click(1);   // right click
    if (pressed[5] && !s.buttons[5]) menu.toggle();
    s.buttons = pressed;
  }
}

// ---------------------------------------------------------------------------
// Desktop mouse (for testing without a headset)
// ---------------------------------------------------------------------------
const mousePointer = new Pointer('mouse');
const ndc = new THREE.Vector2();
let mouseRay = null;
let mouseGrab = null;
function mouseRayFrom(e) {
  const r = renderer.domElement.getBoundingClientRect();
  ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
  raycaster.setFromCamera(ndc, camera);
  return raycaster.ray.clone();
}
renderer.domElement.addEventListener('pointermove', e => {
  if (renderer.xr.isPresenting) return;
  mouseRay = mouseRayFrom(e);
  if (mouseGrab) {
    const p = mouseRay.origin.clone().addScaledVector(mouseRay.direction, mouseGrab.dist).sub(mouseGrab.offset);
    mouseGrab.panel.group.position.copy(p);
    mouseGrab.panel.faceUser();
    return;
  }
  mousePointer.update(mouseRay);
});
renderer.domElement.addEventListener('pointerdown', e => {
  if (renderer.xr.isPresenting) return;
  mouseRay = mouseRayFrom(e);
  mousePointer.update(mouseRay);
  const button = e.button === 2 ? 1 : 0;
  const r = mousePointer.press(button);
  if (r === 'grab') {
    const h = mousePointer.hover;
    mouseGrab = { panel: h.panel, dist: h.distance, offset: h.point.clone().sub(h.panel.group.position) };
  }
  renderer.domElement.setPointerCapture(e.pointerId);
});
renderer.domElement.addEventListener('pointerup', e => {
  if (renderer.xr.isPresenting) return;
  mouseRay = mouseRayFrom(e);
  if (mouseGrab) { mouseGrab.panel.saveLayout(); mouseGrab = null; }
  mousePointer.release(mouseRay);
});
renderer.domElement.addEventListener('contextmenu', e => e.preventDefault());
renderer.domElement.addEventListener('wheel', e => {
  if (renderer.xr.isPresenting) return;
  e.preventDefault();
  mousePointer.update(mouseRayFrom(e));
  mousePointer.scroll(-e.deltaX, -e.deltaY);
}, { passive: false });

// ---------------------------------------------------------------------------
// Keyboard (Bluetooth keyboard paired with the Quest, or the computer keyboard)
// ---------------------------------------------------------------------------
const NAMED_KEYS = {
  Enter: 'return', Backspace: 'backspace', Tab: 'tab', Escape: 'escape', Delete: 'delete',
  ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down',
  Home: 'home', End: 'end', PageUp: 'pageup', PageDown: 'pagedown',
  F1: 'f1', F2: 'f2', F3: 'f3', F4: 'f4', F5: 'f5', F6: 'f6', F7: 'f7', F8: 'f8', F9: 'f9', F10: 'f10', F11: 'f11', F12: 'f12',
};
const CODE_KEYS = { // physical key -> Mac key name (for shortcuts like cmd+c regardless of layout)
  Minus: 'minus', Equal: 'equal', Comma: 'comma', Period: 'period', Slash: 'slash', Semicolon: 'semicolon',
  Quote: 'quote', BracketLeft: 'leftbracket', BracketRight: 'rightbracket', Backslash: 'backslash', Backquote: 'grave', Space: 'space',
};
window.addEventListener('keydown', e => {
  if (!dc || dc.readyState !== 'open') return;
  // Ctrl and Cmd (Meta) both map to Cmd on the Mac, so PC keyboards work with Ctrl+C / Ctrl+V.
  const mods = [];
  if (e.metaKey || e.ctrlKey) mods.push('cmd');
  if (e.altKey) mods.push('alt');
  if (e.shiftKey) mods.push('shift');
  let key = NAMED_KEYS[e.key];
  if (!key && (e.metaKey || e.ctrlKey || e.altKey)) {
    if (/^Key[A-Z]$/.test(e.code)) key = e.code.slice(3).toLowerCase();
    else if (/^Digit[0-9]$/.test(e.code)) key = e.code.slice(5);
    else key = CODE_KEYS[e.code];
  }
  if (key) {
    send({ t: 'key', key, down: true, mods });
    send({ t: 'key', key, down: false, mods });
    e.preventDefault();
  } else if (e.key.length === 1) {
    send({ t: 'text', s: e.key });
    e.preventDefault();
  }
});

// ---------------------------------------------------------------------------
// WebRTC
// ---------------------------------------------------------------------------
function makeVideoTexture(video) {
  // VideoTexture (not Texture): three.js then uploads with texImage2D using the real video size.
  const texture = new THREE.VideoTexture(video);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.minFilter = THREE.LinearFilter;
  texture.magFilter = THREE.LinearFilter;
  texture.generateMipmaps = false;
  return texture;
}

function ensureVideo(slot, track) {
  let v = videos[slot];
  if (!v) {
    const video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.autoplay = true;
    v = { video, texture: null, frames: -1, w: 0, h: 0 };
    // A new window in this slot can have a different size. WebGL textures have a fixed size,
    // so make a fresh texture whenever the video resolution changes.
    video.addEventListener('resize', () => {
      if (video.videoWidth === v.w && video.videoHeight === v.h) return;
      v.w = video.videoWidth; v.h = video.videoHeight;
      if (v.texture) v.texture.dispose();
      v.texture = v.w > 0 ? makeVideoTexture(video) : null;
      v.frames = -1;
      for (const p of panels.values()) if (p.slot === slot) p.setVideo(slot);
    });
    videos[slot] = v;
  }
  v.video.srcObject = new MediaStream([track]);
  v.video.play().catch(() => {});
  return v;
}

/** Upload a video frame to its texture only when a new frame was decoded. */
function updateVideoTextures() {
  for (const v of videos) {
    if (!v || !v.texture || v.video.readyState < 2 || v.video.videoWidth === 0) continue;
    const q = v.video.getVideoPlaybackQuality ? v.video.getVideoPlaybackQuality().totalVideoFrames : -2;
    if (q === -2 || q !== v.frames) { v.frames = q; v.texture.needsUpdate = true; }
  }
}

function waitForIce(pc, timeoutMs) {
  return new Promise(resolve => {
    if (pc.iceGatheringState === 'complete') return resolve();
    const t = setTimeout(resolve, timeoutMs);
    pc.addEventListener('icegatheringstatechange', () => {
      if (pc.iceGatheringState === 'complete') { clearTimeout(t); resolve(); }
    });
  });
}

let reconnectTimer = null;
function scheduleReconnect(ms = 2000) {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => { reconnectTimer = null; connect(); }, ms);
}

async function connect() {
  if (pc) { try { pc.close(); } catch (e) { /* ignore */ } }
  dc = null;
  setStatus('Připojuji se k Macu…');
  const conn = new RTCPeerConnection({ iceServers: [] });
  pc = conn;

  // Prefer H.264 (hardware decoding on the Quest).
  let codecs = null;
  if (window.RTCRtpReceiver && RTCRtpReceiver.getCapabilities) {
    const caps = RTCRtpReceiver.getCapabilities('video');
    if (caps) {
      const h264 = caps.codecs.filter(c => /h264/i.test(c.mimeType));
      codecs = [...h264, ...caps.codecs.filter(c => !/h264/i.test(c.mimeType))];
    }
  }
  const transceivers = [];
  for (let i = 0; i < SLOTS; i++) {
    const t = conn.addTransceiver('video', { direction: 'recvonly' });
    if (codecs && t.setCodecPreferences) { try { t.setCodecPreferences(codecs); } catch (e) { /* ignore */ } }
    transceivers.push(t);
  }

  const channel = conn.createDataChannel('ctl', { ordered: true });
  channel.onopen = () => { dc = channel; setStatus('Připojeno'); send({ type: 'listWindows' }); };
  channel.onclose = () => { if (pc === conn) { setStatus('Spojení ukončeno'); scheduleReconnect(); } };
  channel.onmessage = e => handleMessage(JSON.parse(e.data));

  conn.ontrack = e => {
    const slot = transceivers.indexOf(e.transceiver);
    if (slot >= 0) ensureVideo(slot, e.track);
  };
  let discTimer = null;
  conn.onconnectionstatechange = () => {
    if (pc !== conn) return;
    const s = conn.connectionState;
    if (s === 'failed' || s === 'closed') { setStatus('Spojení selhalo, zkouším znovu…'); scheduleReconnect(); }
    else if (s === 'disconnected') {
      setStatus('Spojení přerušeno…');
      clearTimeout(discTimer);
      discTimer = setTimeout(() => { if (conn.connectionState !== 'connected') scheduleReconnect(0); }, 4000);
    }
  };

  try {
    await conn.setLocalDescription(await conn.createOffer());
    await waitForIce(conn, 2000);
    const r = await fetch('/offer', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sdp: conn.localDescription.sdp }),
    });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const { sdp } = await r.json();
    if (pc !== conn) return;
    await conn.setRemoteDescription({ type: 'answer', sdp });
  } catch (err) {
    console.error(err);
    if (pc === conn) { setStatus('Mac nedostupný (' + err.message + '), zkouším znovu…'); scheduleReconnect(3000); }
  }
}

function handleMessage(m) {
  switch (m.type) {
    case 'hello':
      macName = m.name || '';
      maxWindows = Math.min(m.maxWindows || SLOTS, SLOTS);
      setStatus('Připojeno k ' + macName);
      break;
    case 'windows':
      windows = m.windows || [];
      for (const p of panels.values()) p.drawTitle();
      menu.redraw();
      break;
    case 'slots':
      slots = (m.slots || []).slice(0, SLOTS);
      while (slots.length < SLOTS) slots.push(0);
      syncPanels();
      if (selectedIds().length === 0 && !menu.open) menu.toggle(true);
      break;
    case 'error':
      setStatus('Chyba: ' + m.message);
      break;
  }
}

// ---------------------------------------------------------------------------
// XR session
// ---------------------------------------------------------------------------
async function setupXR() {
  if (!navigator.xr) {
    enterBtn.textContent = window.isSecureContext ? 'WebXR není k dispozici' : 'WebXR vyžaduje HTTPS';
    return;
  }
  const ok = await navigator.xr.isSessionSupported('immersive-vr').catch(() => false);
  if (!ok) { enterBtn.textContent = 'VR není podporováno'; return; }
  enterBtn.disabled = false;
  enterBtn.addEventListener('click', async () => {
    try {
      const session = await navigator.xr.requestSession('immersive-vr', { optionalFeatures: ['local-floor'] });
      await renderer.xr.setSession(session);
      // Re-place panels around the user once the real head pose is known.
      setTimeout(() => {
        if (menu.open) menu.toggle(true);
      }, 300);
    } catch (e) {
      setStatus('VR se nepodařilo spustit: ' + e.message);
    }
  });
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------
const clock = new THREE.Clock();
renderer.setAnimationLoop(() => {
  const dt = Math.min(clock.getDelta(), 0.1);
  updateVideoTextures();
  if (renderer.xr.isPresenting) updateControllers(dt);
  renderer.render(scene, camera);
});

setupXR();
connect();

// Expose a little state for debugging / automated tests.
window.vrd = { get panels() { return panels; }, get slots() { return slots; }, get windows() { return windows; }, menu, send, camera };
