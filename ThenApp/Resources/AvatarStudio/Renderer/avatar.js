import * as THREE from './three.module.min.js';
import { GLTFLoader } from './GLTFLoader.js';

const canvas = document.querySelector('#avatar');
const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setClearColor(0xffffff, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;

const scene = new THREE.Scene();
const camera = new THREE.OrthographicCamera(-1.6, 1.6, 3.2, -3.2, 0.1, 100);
camera.position.set(0, 0.2, 8);
camera.lookAt(0, 0.15, 0);

scene.add(new THREE.HemisphereLight(0xffffff, 0xd8d3ca, 2.6));
const key = new THREE.DirectionalLight(0xffffff, 3.2);
key.position.set(-3, 5, 5);
key.castShadow = true;
scene.add(key);
const rim = new THREE.DirectionalLight(0xc6d4ff, 1.1);
rim.position.set(4, 2, -4);
scene.add(rim);

const root = new THREE.Group();
root.position.y = -0.04;
scene.add(root);

const avatarRoot = new THREE.Group();
root.add(avatarRoot);

const platformMaterial = new THREE.MeshStandardMaterial({ color: 0xf7f7f7, roughness: 0.58 });
const platform = new THREE.Mesh(new THREE.CylinderGeometry(1.05, 1.18, 0.11, 64), platformMaterial);
platform.position.y = -2.62;
platform.receiveShadow = true;
root.add(platform);

const loader = new GLTFLoader();
const assetFiles = Object.freeze({
  body: 'body-neutral.glb',
  face: 'face-hair-black.glb',
  'ivory-knit': 'top-ivory-knit.glb',
  'blue-shirt': 'outerwear-blue-shirt.glb',
  'black-skirt': 'bottom-black-skirt.glb',
  'mint-skirt': 'bottom-mint-skirt.glb',
  'cream-sneakers': 'shoes-cream.glb',
  'black-boots': 'shoes-black-boots.glb',
});
const allowed = Object.freeze({
  top: new Set(['ivory-knit', 'blue-shirt']),
  bottom: new Set(['black-skirt', 'mint-skirt']),
  shoes: new Set(['cream-sneakers', 'black-boots']),
});
const assets = new Map();
let yaw = -0.08;
let pointerX = null;
let activeSession = null;
let activeRevision = -1;
let activeLook = null;
let motionEnabled = true;
let animationFrame = null;
let lastFrameTime = null;
let gestureLean = 0;
let gestureLeanTarget = 0;
let outfitPulseStartedAt = null;

function post(message) {
  window.webkit?.messageHandlers?.avatarBridge?.postMessage(message);
}

function render() {
  avatarRoot.rotation.y = yaw;
  renderer.render(scene, camera);
}

function resetMotionPose() {
  avatarRoot.position.set(0, 0, 0);
  avatarRoot.rotation.x = 0;
  avatarRoot.rotation.z = 0;
  avatarRoot.scale.set(1, 1, 1);
  gestureLean = 0;
  gestureLeanTarget = 0;
  outfitPulseStartedAt = null;
}

function startAnimation() {
  if (animationFrame !== null || document.hidden) return;
  animationFrame = window.requestAnimationFrame(animate);
}

function animate(time) {
  animationFrame = null;
  const deltaSeconds = lastFrameTime === null
    ? 0
    : Math.min((time - lastFrameTime) / 1000, 0.05);
  lastFrameTime = time;
  const leanBlend = 1 - Math.exp(-12 * deltaSeconds);
  gestureLean += (gestureLeanTarget - gestureLean) * leanBlend;

  let outfitPulse = 0;
  if (motionEnabled && outfitPulseStartedAt !== null) {
    const progress = Math.min((time - outfitPulseStartedAt) / 420, 1);
    outfitPulse = Math.sin(progress * Math.PI) * 0.018;
    if (progress >= 1) outfitPulseStartedAt = null;
  }

  if (motionEnabled) {
    const seconds = time / 1000;
    const breath = Math.sin(seconds * 1.65) * 0.0024;
    avatarRoot.position.y = Math.sin(seconds * 1.35) * 0.012;
    avatarRoot.rotation.x = Math.sin(seconds * 0.62 + 0.7) * 0.005;
    avatarRoot.rotation.z = Math.sin(seconds * 0.72) * 0.008 + gestureLean;
    avatarRoot.scale.set(
      1 - breath * 0.25 + outfitPulse,
      1 + breath + outfitPulse,
      1 - breath * 0.25 + outfitPulse,
    );
  } else {
    resetMotionPose();
  }

  render();
  if (motionEnabled || Math.abs(gestureLean - gestureLeanTarget) > 0.0001 || outfitPulseStartedAt !== null) {
    startAnimation();
  }
}

function resize() {
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  renderer.setSize(width, height, false);
  const aspect = Math.max(width / Math.max(height, 1), 0.5);
  camera.left = -2.76 * aspect;
  camera.right = 2.76 * aspect;
  camera.top = 3.10;
  camera.bottom = -3.10;
  camera.updateProjectionMatrix();
  render();
}

function setMorphs(object, shoulderWidth, torsoDepth) {
  object.traverse((child) => {
    if (!child.isMesh || !child.morphTargetInfluences || !child.morphTargetDictionary) return;
    const shoulder = child.morphTargetDictionary.shoulderWidth;
    const torso = child.morphTargetDictionary.torsoDepth;
    if (Number.isInteger(shoulder)) child.morphTargetInfluences[shoulder] = shoulderWidth;
    if (Number.isInteger(torso)) child.morphTargetInfluences[torso] = torsoDepth;
  });
}

function validPayload(payload) {
  return payload
    && typeof payload.session === 'string'
    && payload.session.length >= 32
    && Number.isInteger(payload.revision)
    && payload.revision >= 0
    && allowed.top.has(payload.top)
    && allowed.bottom.has(payload.bottom)
    && allowed.shoes.has(payload.shoes)
    && Number.isFinite(payload.yaw)
    && typeof payload.reduceMotion === 'boolean'
    && Number.isFinite(payload.shoulderWidth)
    && Number.isFinite(payload.torsoDepth)
    && payload.shoulderWidth >= -0.25
    && payload.shoulderWidth <= 0.25
    && payload.torsoDepth >= -0.25
    && payload.torsoDepth <= 0.25;
}

function apply(payload) {
  if (!validPayload(payload)) {
    post({ type: 'failed', code: 'invalidConfiguration' });
    return;
  }
  if (activeSession === payload.session && payload.revision < activeRevision) return;
  activeSession = payload.session;
  activeRevision = payload.revision;
  motionEnabled = !payload.reduceMotion;
  yaw = payload.yaw;
  const nextLook = `${payload.top}|${payload.bottom}|${payload.shoes}`;
  if (motionEnabled && activeLook !== null && activeLook !== nextLook) {
    outfitPulseStartedAt = performance.now();
  }
  activeLook = nextLook;
  const visibleFiles = new Set([
    assetFiles.body,
    assetFiles.face,
    assetFiles[payload.top],
    assetFiles[payload.bottom],
    assetFiles[payload.shoes],
  ]);
  for (const [file, object] of assets) {
    object.visible = visibleFiles.has(file);
    setMorphs(object, payload.shoulderWidth, payload.torsoDepth);
  }
  if (motionEnabled) startAnimation();
  else {
    resetMotionPose();
    render();
  }
  post({ type: 'applied', session: activeSession, revision: activeRevision });
}

window.ThenAvatar = Object.freeze({ apply });

canvas.addEventListener('pointerdown', (event) => {
  pointerX = event.clientX;
  canvas.setPointerCapture(event.pointerId);
});
canvas.addEventListener('pointermove', (event) => {
  if (pointerX === null) return;
  const deltaX = event.clientX - pointerX;
  yaw += deltaX * 0.012;
  if (motionEnabled) {
    gestureLeanTarget = THREE.MathUtils.clamp(-deltaX * 0.0018, -0.035, 0.035);
    startAnimation();
  }
  pointerX = event.clientX;
  render();
});
canvas.addEventListener('pointerup', (event) => {
  pointerX = null;
  gestureLeanTarget = 0;
  startAnimation();
  canvas.releasePointerCapture(event.pointerId);
  post({ type: 'angle', session: activeSession, revision: activeRevision, yaw });
});
canvas.addEventListener('pointercancel', () => {
  pointerX = null;
  gestureLeanTarget = 0;
  startAnimation();
});
canvas.addEventListener('webglcontextlost', (event) => {
  event.preventDefault();
  post({ type: 'failed', code: 'contextLost' });
});

new ResizeObserver(resize).observe(canvas);

async function prepare() {
  const files = Object.values(assetFiles);
  const loaded = await Promise.all(files.map(async (file) => {
    let gltf;
    try {
      gltf = await loader.loadAsync(`avatar://local/assets/${file}`);
    } catch {
      throw new Error(`load:${file}`);
    }
    gltf.scene.name = file;
    gltf.scene.visible = false;
    gltf.scene.traverse((child) => {
      if (!child.isMesh) return;
      child.castShadow = true;
      child.receiveShadow = true;
      child.frustumCulled = false;
    });
    return [file, gltf.scene];
  }));
  for (const [file, object] of loaded) {
    assets.set(file, object);
    avatarRoot.add(object);
  }
  try {
    resize();
  } catch {
    throw new Error('initialRender');
  }
  post({ type: 'ready', assetCount: assets.size });
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    if (animationFrame !== null) window.cancelAnimationFrame(animationFrame);
    animationFrame = null;
    lastFrameTime = null;
    return;
  }
  if (motionEnabled) startAnimation();
  else render();
});

const preparationFailureCodes = new Set([
  ...Object.values(assetFiles).map((file) => `load:${file}`),
  'initialRender',
]);

prepare().catch((error) => {
  const code = preparationFailureCodes.has(error?.message) ? error.message : 'assetLoadFailed';
  post({ type: 'failed', code });
});

window.addEventListener('pagehide', () => {
  if (animationFrame !== null) window.cancelAnimationFrame(animationFrame);
  for (const object of assets.values()) {
    object.traverse((child) => {
      child.geometry?.dispose();
      if (Array.isArray(child.material)) child.material.forEach((material) => material.dispose());
      else child.material?.dispose();
    });
  }
  platform.geometry.dispose();
  platformMaterial.dispose();
  renderer.dispose();
}, { once: true });
