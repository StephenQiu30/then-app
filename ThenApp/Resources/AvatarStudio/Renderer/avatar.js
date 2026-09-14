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

function post(message) {
  window.webkit?.messageHandlers?.avatarBridge?.postMessage(message);
}

function render() {
  root.rotation.y = yaw;
  renderer.render(scene, camera);
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
  yaw = payload.yaw;
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
  render();
  post({ type: 'applied', session: activeSession, revision: activeRevision });
}

window.ThenAvatar = Object.freeze({ apply });

canvas.addEventListener('pointerdown', (event) => {
  pointerX = event.clientX;
  canvas.setPointerCapture(event.pointerId);
});
canvas.addEventListener('pointermove', (event) => {
  if (pointerX === null) return;
  yaw += (event.clientX - pointerX) * 0.012;
  pointerX = event.clientX;
  render();
});
canvas.addEventListener('pointerup', (event) => {
  pointerX = null;
  canvas.releasePointerCapture(event.pointerId);
  post({ type: 'angle', session: activeSession, revision: activeRevision, yaw });
});
canvas.addEventListener('pointercancel', () => { pointerX = null; });
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
    root.add(object);
  }
  try {
    resize();
  } catch {
    throw new Error('initialRender');
  }
  post({ type: 'ready', assetCount: assets.size });
}

const preparationFailureCodes = new Set([
  ...Object.values(assetFiles).map((file) => `load:${file}`),
  'initialRender',
]);

prepare().catch((error) => {
  const code = preparationFailureCodes.has(error?.message) ? error.message : 'assetLoadFailed';
  post({ type: 'failed', code });
});

window.addEventListener('pagehide', () => {
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
