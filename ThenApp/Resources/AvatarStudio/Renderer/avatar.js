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
const preparingAssets = new Set();
let yaw = -0.08;
let pointerX = null;
let activeSession = null;
let activeRevision = -1;
let activeLook = null;
let motionEnabled = true;
let nativeActive = false;
let contextAvailable = true;
let destroyed = false;
let animationFrame = null;
let lastFrameTime = null;
let activeTimeMilliseconds = 0;
let activePointerID = null;
let gestureLean = 0;
let gestureLeanTarget = 0;
let outfitPulseStartedAt = null;
let resizeObserver = null;

function post(message) {
  window.webkit?.messageHandlers?.avatarBridge?.postMessage(message);
}

function render() {
  if (destroyed || !contextAvailable) return;
  avatarRoot.rotation.y = yaw;
  renderer.render(scene, camera);
}

function clearTransientMotion() {
  if (activePointerID !== null && canvas.hasPointerCapture(activePointerID)) {
    canvas.releasePointerCapture(activePointerID);
  }
  activePointerID = null;
  pointerX = null;
  gestureLean = 0;
  gestureLeanTarget = 0;
  outfitPulseStartedAt = null;
}

function resetMotionPose() {
  avatarRoot.position.set(0, 0, 0);
  avatarRoot.rotation.x = 0;
  avatarRoot.rotation.z = 0;
  avatarRoot.scale.set(1, 1, 1);
  clearTransientMotion();
}

function stageIsActive() {
  return nativeActive && !document.hidden && contextAvailable && !destroyed;
}

function stopAnimation({ clearTransient = false } = {}) {
  if (animationFrame !== null) window.cancelAnimationFrame(animationFrame);
  animationFrame = null;
  lastFrameTime = null;
  if (clearTransient) clearTransientMotion();
}

function startAnimation() {
  if (animationFrame !== null || !stageIsActive()) return;
  animationFrame = window.requestAnimationFrame(animate);
}

function animate(time) {
  animationFrame = null;
  if (!stageIsActive()) {
    stopAnimation({ clearTransient: true });
    return;
  }
  const deltaMilliseconds = lastFrameTime === null
    ? 0
    : Math.min(time - lastFrameTime, 50);
  lastFrameTime = time;
  activeTimeMilliseconds += deltaMilliseconds;
  const deltaSeconds = deltaMilliseconds / 1000;
  const leanBlend = 1 - Math.exp(-12 * deltaSeconds);
  gestureLean += (gestureLeanTarget - gestureLean) * leanBlend;

  let outfitPulse = 0;
  if (motionEnabled && outfitPulseStartedAt !== null) {
    const progress = Math.min((activeTimeMilliseconds - outfitPulseStartedAt) / 420, 1);
    outfitPulse = Math.sin(progress * Math.PI) * 0.018;
    if (progress >= 1) outfitPulseStartedAt = null;
  }

  if (motionEnabled) {
    const seconds = activeTimeMilliseconds / 1000;
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

function setActive(isActive) {
  if (destroyed || typeof isActive !== 'boolean') return;
  nativeActive = isActive;
  if (!stageIsActive()) {
    stopAnimation({ clearTransient: true });
    return;
  }
  if (motionEnabled) startAnimation();
  else render();
}

function resize() {
  if (destroyed || !contextAvailable) return;
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
  if (destroyed) return;
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
  if (motionEnabled && stageIsActive() && activeLook !== null && activeLook !== nextLook) {
    outfitPulseStartedAt = activeTimeMilliseconds;
  } else if (activeLook !== nextLook) {
    outfitPulseStartedAt = null;
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
  if (motionEnabled && stageIsActive()) startAnimation();
  else {
    resetMotionPose();
    if (stageIsActive()) render();
  }
  post({ type: 'applied', session: activeSession, revision: activeRevision });
}

function handlePointerDown(event) {
  if (!stageIsActive()) return;
  pointerX = event.clientX;
  activePointerID = event.pointerId;
  canvas.setPointerCapture(event.pointerId);
}

function handlePointerMove(event) {
  if (!stageIsActive() || pointerX === null || activePointerID !== event.pointerId) return;
  const deltaX = event.clientX - pointerX;
  yaw += deltaX * 0.012;
  if (motionEnabled) {
    gestureLeanTarget = THREE.MathUtils.clamp(-deltaX * 0.0018, -0.035, 0.035);
    startAnimation();
  }
  pointerX = event.clientX;
  render();
}

function handlePointerUp(event) {
  if (activePointerID !== event.pointerId) return;
  pointerX = null;
  activePointerID = null;
  gestureLeanTarget = 0;
  startAnimation();
  if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId);
  post({ type: 'angle', session: activeSession, revision: activeRevision, yaw });
}

function handlePointerCancel() {
  clearTransientMotion();
  if (stageIsActive() && motionEnabled) startAnimation();
}

function handleContextLost(event) {
  event.preventDefault();
  contextAvailable = false;
  stopAnimation({ clearTransient: true });
  post({ type: 'failed', code: 'contextLost' });
}

canvas.addEventListener('pointerdown', handlePointerDown);
canvas.addEventListener('pointermove', handlePointerMove);
canvas.addEventListener('pointerup', handlePointerUp);
canvas.addEventListener('pointercancel', handlePointerCancel);
canvas.addEventListener('webglcontextlost', handleContextLost);

resizeObserver = new ResizeObserver(resize);
resizeObserver.observe(canvas);

async function prepare() {
  const files = Object.values(assetFiles);
  const results = await Promise.allSettled(files.map(async (file) => {
    let gltf;
    try {
      gltf = await loader.loadAsync(`avatar://local/assets/${file}`);
    } catch {
      throw new Error(`load:${file}`);
    }
    if (destroyed) {
      disposeObject(gltf.scene);
      throw new Error('destroyed');
    }
    gltf.scene.name = file;
    gltf.scene.visible = false;
    gltf.scene.traverse((child) => {
      if (!child.isMesh) return;
      child.castShadow = true;
      child.receiveShadow = true;
      child.frustumCulled = false;
    });
    preparingAssets.add(gltf.scene);
    return [file, gltf.scene];
  }));
  const loaded = results
    .filter((result) => result.status === 'fulfilled')
    .map((result) => result.value);
  const failure = results.find((result) => result.status === 'rejected');
  if (failure) {
    for (const [, object] of loaded) {
      if (preparingAssets.delete(object)) disposeObject(object);
    }
    throw failure.reason;
  }
  if (destroyed) {
    for (const [, object] of loaded) {
      if (preparingAssets.delete(object)) disposeObject(object);
    }
    return;
  }
  for (const [file, object] of loaded) {
    preparingAssets.delete(object);
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

function handleVisibilityChange() {
  if (!stageIsActive()) {
    stopAnimation({ clearTransient: true });
    return;
  }
  if (motionEnabled) startAnimation();
  else render();
}

function disposeObject(object) {
  object.traverse((child) => {
    child.geometry?.dispose();
    if (Array.isArray(child.material)) child.material.forEach((material) => material.dispose());
    else child.material?.dispose();
  });
}

function destroy() {
  if (destroyed) return;
  nativeActive = false;
  stopAnimation({ clearTransient: true });
  destroyed = true;
  document.removeEventListener('visibilitychange', handleVisibilityChange);
  window.removeEventListener('pagehide', destroy);
  canvas.removeEventListener('pointerdown', handlePointerDown);
  canvas.removeEventListener('pointermove', handlePointerMove);
  canvas.removeEventListener('pointerup', handlePointerUp);
  canvas.removeEventListener('pointercancel', handlePointerCancel);
  canvas.removeEventListener('webglcontextlost', handleContextLost);
  resizeObserver?.disconnect();
  resizeObserver = null;
  for (const object of preparingAssets) disposeObject(object);
  preparingAssets.clear();
  for (const object of assets.values()) disposeObject(object);
  assets.clear();
  platform.geometry.dispose();
  platformMaterial.dispose();
  renderer.dispose();
}

window.ThenAvatar = Object.freeze({ apply, setActive, destroy });
document.addEventListener('visibilitychange', handleVisibilityChange);
window.addEventListener('pagehide', destroy);

const preparationFailureCodes = new Set([
  ...Object.values(assetFiles).map((file) => `load:${file}`),
  'initialRender',
]);

prepare().catch((error) => {
  if (destroyed || error?.message === 'destroyed') return;
  const code = preparationFailureCodes.has(error?.message) ? error.message : 'assetLoadFailed';
  post({ type: 'failed', code });
});
