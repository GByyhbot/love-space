/* 造型间 · 3D 卡通形象与换装
 *
 * 为什么角色是程序化几何体，不是下载 VRM/GLB：
 *   1. 许可干净——three.js 是 MIT，角色是代码画的，没有第三方美术资产授权问题；
 *   2. 离线可用——APK 里没有网络也能换装，只背 687KB 引擎，不背几百 KB 模型；
 *   3. 可控——调比例、加动作都改代码，不用开 Blender。
 * 代价：形象是"我们的卡通版"，不是真人。这是产品选择，不是技术限制。
 *
 * 骨架（没有骨骼动画系统，但够用的 FK 层级）：
 *   root
 *   ├── upper       ← 倾身支点（腰部），转它上身连头带手臂一起倾
 *   │   └── upperInner     （-WAIST_Y 偏移，让子节点继续用原坐标写）
 *   │       ├── 躯干 / 头 / 双臂 / 上衣主体
 *   │       └── armL,R → elbowL,R   肩、肘
 *   └── legL,R → kneeL,R            髋、膝
 * 有了肘和膝，单膝下跪、公主抱这类姿势才做得出来；只有单段胶囊就只能整体摆动。
 *
 * 换装的实现：所有服装在构建时一次性建好，切换只改 visible。
 * 不走"销毁再重建"——那样每次点击都在分配几何体，来回点几次就漏显存。
 */

import * as THREE from './vendor/three.module.min.js';

/* ── 身材规格：成年人体比例（约 7 头身），男女各一套 ───────────────────
   之前是"两头身"的布偶，现在照商场模特来：肩线平、腰收、腿长。
   所有尺寸只写在这张表里，buildCharacter 只负责照表搭积木——
   想再调高矮胖瘦，改这张表就够，不用碰几何代码。 */
const BODIES = {
  // 男方：2.56 高 / 头 0.37 → 7.0 头身
  m: {
    h: 2.560,
    headR: 0.152, headY: 2.372, headSZ: 1.02,
    headShape: [[0.004, -0.178], [0.070, -0.166], [0.108, -0.126], [0.132, -0.062],
      [0.144, 0.006], [0.142, 0.070], [0.126, 0.126], [0.092, 0.166], [0.040, 0.184], [0.004, 0.188]],
    neckR: 0.082, neckTopR: 0.062, neckBot: 2.045, neckTop: 2.240,
    // shoulderY = 手臂支点。它必须比躯干顶点低一截：袖山是半个球，
    // 球顶会再抬 0.1 上去，支点压在顶点上就会顶出两个"肩上的气球"。
    shoulderY: 2.000, waistY: 1.520, hipY: 1.285, kneeY: 0.720, ankleY: 0.095,
    chestR: 0.205, waistR: 0.160, hipR: 0.226, shoulderR: 0.152, torsoZ: 0.72,
    // 截面从下往上：胯 → 腰（收）→ 胸（鼓）→ 肩（平）→ 斜方肌（缓收）→ 颈根
    torso: [[0.004, 1.150], [0.196, 1.200], [0.222, 1.270], [0.198, 1.380], [0.162, 1.520],
      [0.172, 1.650], [0.196, 1.800], [0.204, 1.880], [0.200, 1.945], [0.180, 2.000],
      [0.148, 2.045], [0.110, 2.080], [0.088, 2.105]],
    armPivotX: 0.196, armTilt: 0.19,
    upperArm: 0.330, foreArm: 0.340, handLen: 0.115,
    upR1: 0.084, upR2: 0.062, foreR1: 0.062, foreR2: 0.050,
    hipPivotX: 0.098, thigh: 0.565, shin: 0.625,
    thighR1: 0.126, thighR2: 0.100, shinR1: 0.094, shinR2: 0.062,
    footLen: 0.235, footH: 0.100, footW: 0.070,
  },
  // 女方：2.38 高 / 头 0.34 → 6.9 头身；肩窄、胯宽、腰更收
  f: {
    h: 2.380,
    headR: 0.142, headY: 2.205, headSZ: 1.02,
    headShape: [[0.004, -0.168], [0.064, -0.156], [0.100, -0.118], [0.122, -0.058],
      [0.134, 0.004], [0.132, 0.064], [0.118, 0.118], [0.086, 0.156], [0.038, 0.172], [0.004, 0.176]],
    neckR: 0.070, neckTopR: 0.052, neckBot: 1.900, neckTop: 2.075,
    shoulderY: 1.890, waistY: 1.455, hipY: 1.215, kneeY: 0.675, ankleY: 0.088,
    chestR: 0.186, waistR: 0.140, hipR: 0.212, shoulderR: 0.126, torsoZ: 0.74,
    torso: [[0.004, 1.085], [0.182, 1.130], [0.208, 1.200], [0.196, 1.310], [0.144, 1.455],
      [0.156, 1.580], [0.180, 1.720], [0.186, 1.800], [0.182, 1.855], [0.164, 1.900],
      [0.132, 1.932], [0.098, 1.955], [0.078, 1.968]],
    armPivotX: 0.172, armTilt: 0.19,
    upperArm: 0.310, foreArm: 0.322, handLen: 0.105,
    upR1: 0.072, upR2: 0.054, foreR1: 0.054, foreR2: 0.044,
    hipPivotX: 0.094, thigh: 0.540, shin: 0.587,
    thighR1: 0.112, thighR2: 0.088, shinR1: 0.082, shinR2: 0.055,
    footLen: 0.215, footH: 0.090, footW: 0.062,
  },
};
const SKIN = '#f0c9ae';
const HAIR_BASE = '#3a3038';   // 只作初值，applyOutfit 会按发色覆盖


/* ── 款式表：每项自带颜色，UI 直接由这张表生成，加衣服只改这里 ──────── */
const GARMENTS = {
  top: [
    { id: 'tee-pink', label: '粉 T 恤', kind: 'tee', color: '#f2a3b7' },
    { id: 'tee-blue', label: '蓝 T 恤', kind: 'tee', color: '#8db8e6' },
    { id: 'hoodie-cream', label: '奶油卫衣', kind: 'hoodie', color: '#f5e5cd' },
    { id: 'shirt-white', label: '白衬衫', kind: 'shirt', color: '#fbfaf7' },
    { id: 'dress-rose', label: '玫瑰连衣裙', kind: 'dress', color: '#e58b9c' },
  ],
  bottom: [
    { id: 'pants-navy', label: '藏蓝长裤', kind: 'pants', color: '#4a5a7a' },
    { id: 'pants-ink', label: '墨黑长裤', kind: 'pants', color: '#3a3a44' },
    { id: 'shorts-sand', label: '米色短裤', kind: 'shorts', color: '#ddcdb4' },
    { id: 'skirt-lilac', label: '藕粉短裙', kind: 'skirt', color: '#b39ac4' },
  ],
  shoes: [
    { id: 'sneaker-white', label: '小白鞋', kind: 'sneaker', color: '#fbfbfb' },
    { id: 'sneaker-ink', label: '黑帆布', kind: 'sneaker', color: '#3d3a40' },
    { id: 'shoe-latte', label: '奶茶色', kind: 'shoe', color: '#c8a686' },
  ],
  hair: [
    { id: 'bangs', label: '齐刘海' },
    { id: 'twin', label: '双马尾' },
    { id: 'bob', label: '短发' },
  ],
  hairColor: [
    { id: 'ink', label: '墨黑', color: '#3a3038' },
    { id: 'chestnut', label: '栗棕', color: '#6d4a35' },
    { id: 'honey', label: '蜜金', color: '#b98a56' },
    { id: 'sakura', label: '樱粉', color: '#dc9fb4' },
    { id: 'mist', label: '雾蓝', color: '#6f7fae' },
  ],
};

/* 两个人默认穿不一样，一进来就能看出是"我们俩" */
const DEFAULT_A = { top: 'tee-pink', bottom: 'pants-navy', shoes: 'sneaker-white', hair: 'bangs', hairColor: 'ink' };
const DEFAULT_B = { top: 'tee-blue', bottom: 'skirt-lilac', shoes: 'sneaker-white', hair: 'twin', hairColor: 'chestnut' };

/* ── 建模小工具 ────────────────────────────────────────────────── */

/** 旋转成型：给一条横截面曲线 [(半径, 高度), ...]，绕 Y 转一圈。
 *  躯干、脑袋、裙摆、裤腰全靠它——圆柱和球拼不出人体的连续过渡。
 *  ⚠️ 点的顺序决定法线朝向：LatheGeometry 按顺序绕行，y 递减时整个面会翻到背面，
 *  外面看不见、里面看得见（裙子曾经像一片侧着插在胯上的三角形，就是这个）。
 *  所有截面都是"从下往上"写的自然顺序，这里兜底排一次，调用方不用记。 */
function lathe(points, seg = 44) {
  const pts = points[points.length - 1][1] < points[0][1] ? [...points].reverse() : points;
  return new THREE.LatheGeometry(pts.map(([r, y]) => new THREE.Vector2(r, y)), seg);
}

/** 上粗下细的圆台（local -Y 是往下，所以第一个参数是肩/髋那头）。 */
function taper(rTop, rBottom, len, m, seg = 20) {
  return new THREE.Mesh(new THREE.CylinderGeometry(rTop, rBottom, len, seg), m);
}

/** 椭球：球被压成任意比例，做手、脚、鞋底这些"没有明显棱"的部件最省事。 */
function blob(rx, ry, rz, m, seg = 18) {
  const mesh = new THREE.Mesh(new THREE.SphereGeometry(1, seg, Math.max(10, seg - 4)), m);
  mesh.scale.set(rx, ry, rz);
  return mesh;
}

function shade(hex, k) {
  return '#' + new THREE.Color(hex).multiplyScalar(k).getHexString();
}

function byId(list, id) {
  return list.find((x) => x.id === id) || list[0];
}

/* ── 接地阴影：一张径向渐变的圆片，比真的开 shadowMap 便宜得多 ──────── */
function shadowTexture() {
  const size = 128;
  const cv = document.createElement('canvas');
  cv.width = cv.height = size;
  const ctx = cv.getContext('2d');
  const g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  g.addColorStop(0, 'rgba(60,40,50,0.30)');
  g.addColorStop(0.55, 'rgba(60,40,50,0.13)');
  g.addColorStop(1, 'rgba(60,40,50,0)');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, size, size);
  const tex = new THREE.CanvasTexture(cv);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

/* ══════════════════════ 角色构建 ══════════════════════ */

function buildCharacter(d) {
  const root = new THREE.Group();
  const R = d.headR;
  const mat = (color, extra = {}) => new THREE.MeshStandardMaterial({ color, roughness: 0.88, metalness: 0, ...extra });
  const skinMat = mat(SKIN, { roughness: 0.80 });
  const hairMat = mat(HAIR_BASE, { roughness: 0.55, metalness: 0.02 });
  const latheMesh = (points, m, z = 1, seg = 44) => {
    const mesh = new THREE.Mesh(lathe(points, seg), m);
    mesh.scale.z = z;
    return mesh;
  };

  /* —— 上身：以腰为支点，倾身时头、手臂、上衣一起动 —— */
  const upper = new THREE.Group();
  upper.position.y = d.waistY;
  const upperInner = new THREE.Group();
  upperInner.position.y = -d.waistY;
  upper.add(upperInner);
  root.add(upper);

  // 躯干：一条横截面曲线绕 Y 转一圈，肩—胸—腰—胯是连续过渡的。
  // 圆柱+球拼不出这个过渡，接缝一定会露出来。再横向压扁，因为人是前后薄、左右宽。
  upperInner.add(latheMesh(d.torso, skinMat, d.torsoZ, 48));

  // 脖子：下粗上细，顶端插进下颌里。插进去才不会在转头时露出缝。
  const neck = taper(d.neckTopR, d.neckR, d.neckTop - d.neckBot, skinMat, 24);
  neck.position.y = (d.neckTop + d.neckBot) / 2;
  upperInner.add(neck);

  /* —— 手臂：肩 → 肘两段，带三角肌 —— */
  const armL = new THREE.Group();
  const armR = new THREE.Group();
  const elbowL = new THREE.Group();
  const elbowR = new THREE.Group();
  for (const [g, elbow, side] of [[armL, elbowL, -1], [armR, elbowR, 1]]) {
    g.position.set(side * d.armPivotX, d.shoulderY, 0);
    g.rotation.z = side * d.armTilt;
    // 三角肌：缺了这一坨，手臂和躯干之间会有一道缝。
    // 但别做得比袖口还大——大了就顶穿袖子，肩头露出一颗肉球。
    const delt = blob(d.upR1 * 1.06, d.upR1 * 0.86, d.upR1 * 1.02, skinMat, 20);
    delt.position.y = -0.030;
    g.add(delt);
    g.add(taper(d.upR1, d.upR2, d.upperArm, skinMat).translateY(-d.upperArm / 2));
    elbow.position.y = -d.upperArm;
    // 关节球只做"填缝"：必须比两端管子略粗（共面会闪锯齿环），
    // 但也就粗 7%，再大就在关节上顶出一圈硬边
    const elbowR = Math.max(d.upR2, d.foreR1) * 1.035;
    elbow.add(blob(elbowR, elbowR * 0.86, elbowR, skinMat, 18));
    elbow.add(taper(d.foreR1, d.foreR2, d.foreArm, skinMat).translateY(-d.foreArm / 2));
    // 手：扁椭球，比小臂略宽一点
    const hand = blob(d.foreR2 * 1.34, d.handLen * 0.74, d.foreR2 * 0.62, skinMat, 18);
    hand.position.set(0, -d.foreArm - d.handLen * 0.48, 0);
    elbow.add(hand);
    g.add(elbow);
    upperInner.add(g);
  }

  /* —— 腿：髋 → 膝两段，带膝盖和脚 —— */
  const legL = new THREE.Group();
  const legR = new THREE.Group();
  const kneeL = new THREE.Group();
  const kneeR = new THREE.Group();
  const shinTube = d.shin - d.footH * 0.30;
  for (const [g, knee, side] of [[legL, kneeL, -1], [legR, kneeR, 1]]) {
    g.position.set(side * d.hipPivotX, d.hipY, 0);
    g.add(taper(d.thighR1, d.thighR2, d.thigh, skinMat).translateY(-d.thigh / 2));
    knee.position.y = -d.thigh;
    const kneeR = Math.max(d.thighR2, d.shinR1) * 1.045;
    knee.add(blob(kneeR, kneeR * 0.90, kneeR, skinMat, 18));
    knee.add(taper(d.shinR1, d.shinR2, shinTube, skinMat).translateY(-shinTube / 2));
    // 脚：踝下一只脚背，脚尖朝 +z
    const foot = blob(d.footW * 0.92, d.footH * 0.46, d.footLen * 0.52, skinMat, 18);
    foot.position.set(0, -d.shin + d.footH * 0.40, d.footLen * 0.26);
    knee.add(foot);
    g.add(knee);
    root.add(g);
  }

  /* —— 头：整颗头一个 Group，点头/歪头一起动 —— */
  const head = new THREE.Group();
  head.position.y = d.headY;
  upperInner.add(head);
  // 头颅也是旋转成型：额头、颧骨、下颌的收分靠曲线，球做不出来
  const skull = latheMesh(d.headShape, skinMat, d.headSZ, 40);
  head.add(skull);

  /* —— 五官：按头半径 R 摆，换体型不用重算坐标 —— */
  const eyeWhiteMat = new THREE.MeshStandardMaterial({ color: '#fffdfa', roughness: 0.35 });
  const irisMat = mat('#3b2b33', { roughness: 0.42 });
  const shineMat = new THREE.MeshBasicMaterial({ color: '#ffffff' });
  const blushMat = new THREE.MeshBasicMaterial({ color: '#eda2ab', transparent: true, opacity: 0.30 });
  const mouthMat = mat('#b96a73', { roughness: 0.55 });
  const browMat = mat('#4e3c46', { roughness: 0.6 });
  for (const side of [-1, 1]) {
    const white = blob(0.21 * R, 0.13 * R, 0.062 * R, eyeWhiteMat, 18);
    white.position.set(side * 0.41 * R, 0.005 * R, 0.905 * R);
    head.add(white);

    const iris = blob(0.125 * R, 0.125 * R, 0.045 * R, irisMat, 16);
    iris.position.set(side * 0.41 * R, 0.0, 0.945 * R);
    head.add(iris);

    const shine = blob(0.042 * R, 0.042 * R, 0.02 * R, shineMat, 10);
    shine.position.set(side * 0.355 * R, 0.055 * R, 0.968 * R);
    head.add(shine);

    // 上眼睑：一道细弧压住眼白上沿，眼睛立刻有"眼皮"而不是一颗球
    const lid = new THREE.Mesh(new THREE.CapsuleGeometry(0.017 * R, 0.30 * R, 4, 10), irisMat);
    lid.position.set(side * 0.41 * R, 0.115 * R, 0.925 * R);
    lid.rotation.set(0.15, 0, Math.PI / 2 + side * 0.10);
    head.add(lid);

    const brow = new THREE.Mesh(new THREE.CapsuleGeometry(0.014 * R, 0.34 * R, 4, 10), browMat);
    brow.position.set(side * 0.40 * R, 0.335 * R, 0.905 * R);
    brow.rotation.set(0.12, side * 0.16, Math.PI / 2 - side * 0.05);
    brow.scale.z = 0.7;
    head.add(brow);

    const blush = blob(0.16 * R, 0.10 * R, 0.03 * R, blushMat, 14);
    blush.position.set(side * 0.62 * R, -0.30 * R, 0.80 * R);
    blush.rotation.y = side * 0.62;
    head.add(blush);
  }
  // 鼻子：只要一点起伏，多了就是另一个画风
  const nose = blob(0.075 * R, 0.075 * R, 0.055 * R, mat(shade(SKIN, 0.95), { roughness: 0.8 }), 14);
  nose.position.set(0, -0.285 * R, 0.965 * R);
  head.add(nose);

  const mouth = blob(0.135 * R, 0.045 * R, 0.045 * R, mouthMat, 16);
  mouth.position.set(0, -0.625 * R, 0.885 * R);
  head.add(mouth);

  /* —— 头发：球面片按发型显隐 ——
     ⚠️ 不能只按 R（横向半径）缩放：头是竖长的蛋形，顶点比 R 高出近四分之一，
     只用 R 缩放的球壳盖到一半就没了，正上方会秃一块。横向按 R、纵向按头高 H
     分别缩放，发壳才真的贴着颅骨。 */
  const H = Math.max(...d.headShape.map((p) => Math.abs(p[1])));
  const HW = R * 1.085;
  const HH = H * 1.075;
  const hairParts = {};
  /* grow 让每片发壳半径略有差异：三片用同一半径会完全共面，正面上方那一条会闪烁。
     phi 是绕 Y 的角度，正前方 = 0.5π。back 给到 0.72π..2.28π，两侧鬓角才不漏头皮。 */
  const addHair = (key, grow, phiStart, phiLen, thetaStart, thetaLen, segW = 36, segH = 24) => {
    const geo = new THREE.SphereGeometry(1, segW, segH, phiStart, phiLen, thetaStart, thetaLen);
    const m = new THREE.Mesh(geo, hairMat);
    m.scale.set(HW * grow, HH * grow, HW * grow);
    m.visible = false;
    head.add(m);
    hairParts[key] = m;
    return m;
  };
  addHair('cap', 1.00, 0, Math.PI * 2, 0, Math.PI * 0.34);
  addHair('back', 1.02, Math.PI * 0.72, Math.PI * 1.56, Math.PI * 0.20, Math.PI * 0.68, 36, 22);
  addHair('bangs', 1.015, Math.PI * 0.26, Math.PI * 0.48, Math.PI * 0.28, Math.PI * 0.16, 32, 10);
  addHair('bangs2', 1.032, Math.PI * 0.34, Math.PI * 0.30, Math.PI * 0.34, Math.PI * 0.10, 26, 10);
  // 鬓发用胶囊而不是球面片：球面片在脸上会切出方角
  for (const side of [-1, 1]) {
    const lock = new THREE.Mesh(new THREE.CapsuleGeometry(0.16 * R, 1.30 * R, 6, 14), hairMat);
    lock.position.set(side * 0.88 * R, -0.10 * R, 0.42 * R);
    lock.rotation.z = side * 0.05;
    lock.visible = false;
    head.add(lock);
    hairParts[side < 0 ? 'sideL' : 'sideR'] = lock;
  }
  for (const side of [-1, 1]) {
    const g = new THREE.Group();
    g.position.set(side * 0.92 * R, -0.30 * R, -0.22 * R);
    g.rotation.z = side * 0.28;
    g.visible = false;
    g.add(new THREE.Mesh(new THREE.CapsuleGeometry(0.17 * R, 1.0 * R, 6, 14), hairMat).translateY(-0.55 * R));
    g.add(new THREE.Mesh(new THREE.SphereGeometry(0.20 * R, 14, 12), hairMat).translateY(0.04 * R));
    head.add(g);
    hairParts[side < 0 ? 'tailL' : 'tailR'] = g;
  }

  /* —— 小道具：单膝下跪时右手那枚戒指 —— */
  // 稍微做大一点也不过分：跪姿的取景里它只有十几个像素，太小就只是一粒黄点
  const ring = new THREE.Mesh(new THREE.TorusGeometry(0.056, 0.013, 10, 26), mat('#e9c86b', { roughness: 0.32, metalness: 0.55 }));
  ring.position.set(0, -d.foreArm - d.handLen * 0.30, d.foreR2 * 1.5);
  ring.rotation.x = 0.40;
  ring.visible = false;
  elbowR.add(ring);

  /* ══════════════ 服装：一次性建好，靠 visible 切换 ══════════════ */
  const garments = {};
  const own = (id, parent, m) => {
    (garments[id] ||= []).push(m);
    parent.add(m);
    return m;
  };
  const bodyOf = (id, m) => own(id, upperInner, m);
  const clothZ = d.torsoZ * 1.12;   // 衣服比身体圆一点，不然像画上去的

  // 上衣横截面：从下摆到领口。肩到胸的过渡直接用躯干曲线的同一套逻辑。
  /* 上衣横截面：直接拿躯干曲线加一圈余量。
     手写半径（肩宽 + 0.036 之类）在改过身材之后会和躯干对不上——
     领口比肩膀窄一块，正面就露出一大片光肩膀，看着像衣服掉到胸口。
     从躯干推出来，身体怎么改衣服都跟着合身。 */
  const torsoTop = d.torso[d.torso.length - 1];
  const topProfile = (hemY, pad = 0) => {
    const inner = d.torso.filter(([, y]) => y > hemY + 0.01);
    return [
      [inner[0][0] + 0.026 + pad, hemY],
      ...inner.map(([r, y]) => [r + 0.030 + pad, y]),
      [torsoTop[0] + 0.028 + pad * 0.5, torsoTop[1]],
    ];
  };

  // 袖：肩上一只球盖 + 一段圆台。只给圆台会在肩头留一道硬边。
  // 球盖半径只能比手臂粗一点点——放大到 1.6 倍就成了复古泡泡袖，
  // 整条手臂看着像从气球里插出来的一根棍。
  const sleeve = (id, side, len, rEnd, color, withCap = true) => {
    const g = side === 'l' ? armL : armR;
    const sr = d.upR1 * 1.28;
    own(id, g, taper(sr * 0.97, rEnd, len, color, 22).translateY(-len / 2 + 0.010));
    if (withCap) {
      // 球盖压扁到 0.62：整球的话球顶比肩线高出一截，看着像肩上顶了个气球
      const cap = new THREE.Mesh(new THREE.SphereGeometry(sr, 22, 14, 0, Math.PI * 2, 0, Math.PI / 2), color);
      cap.scale.y = 0.62;
      cap.position.y = -0.012;
      own(id, g, cap);
    }
  };
  const foreSleeve = (id, side, color) => own(id, side === 'l' ? elbowL : elbowR,
    taper(d.foreR1 * 1.40, d.foreR2 * 1.28, d.foreArm + 0.02, color, 20).translateY(-d.foreArm / 2));

  for (const g of GARMENTS.top) {
    const m = mat(g.color);
    const darker = mat(shade(g.color, 0.93));
    if (g.kind === 'tee') {
      bodyOf(g.id, latheMesh(topProfile(d.hipY + 0.075), m, clothZ));
      sleeve(g.id, 'l', d.upperArm * 0.52, d.upR1 * 1.14, darker);
      sleeve(g.id, 'r', d.upperArm * 0.52, d.upR1 * 1.14, darker);
    } else if (g.kind === 'hoodie') {
      bodyOf(g.id, latheMesh(topProfile(d.hipY - 0.02, 0.012), m, clothZ));
      const hood = blob(d.shoulderR * 1.16, d.shoulderR * 0.92, d.shoulderR * 0.86, m, 22);
      hood.position.set(0, d.shoulderY + 0.045, -d.shoulderR * 0.62);
      bodyOf(g.id, hood);
      sleeve(g.id, 'l', d.upperArm + 0.02, d.foreR1 * 1.22, darker);
      sleeve(g.id, 'r', d.upperArm + 0.02, d.foreR1 * 1.22, darker);
      foreSleeve(g.id, 'l', darker);
      foreSleeve(g.id, 'r', darker);
    } else if (g.kind === 'shirt') {
      bodyOf(g.id, latheMesh(topProfile(d.hipY + 0.055, 0.004), m, clothZ));
      for (const side of [-1, 1]) {
        const collar = new THREE.Mesh(new THREE.BoxGeometry(d.neckR * 1.5, d.neckR * 1.15, 0.016), m);
        collar.position.set(side * d.neckR * 0.86, d.neckBot + 0.045, d.chestR * 0.52);
        collar.rotation.set(-0.32, side * 0.34, side * 0.52);
        bodyOf(g.id, collar);
      }
      // 门襟纽扣：三颗小圆点，比一片空白耐看
      for (let i = 0; i < 3; i += 1) {
        const btn = blob(0.014, 0.014, 0.008, mat(shade(g.color, 0.86)), 10);
        btn.position.set(0, d.shoulderY - 0.10 - i * 0.14, d.chestR + 0.046);
        bodyOf(g.id, btn);
      }
      sleeve(g.id, 'l', d.upperArm + 0.02, d.foreR1 * 1.22, darker);
      sleeve(g.id, 'r', d.upperArm + 0.02, d.foreR1 * 1.22, darker);
      foreSleeve(g.id, 'l', darker);
      foreSleeve(g.id, 'r', darker);
    } else if (g.kind === 'dress') {
      bodyOf(g.id, latheMesh(topProfile(d.waistY + 0.060), m, clothZ));
      // 同样开口，不收锥尖——理由见上面短裙那段
      const skirt = latheMesh([
        [d.waistR + 0.038, d.waistY + 0.065],
        [d.hipR + 0.030, d.hipY - 0.060],
        [d.hipR + 0.092, d.hipY - 0.360],
      ], m, clothZ * 1.04, 48);
      bodyOf(g.id, skirt);
      sleeve(g.id, 'l', d.upperArm * 0.42, d.upR1 * 1.16, darker);
      sleeve(g.id, 'r', d.upperArm * 0.42, d.upR1 * 1.16, darker);
    }
  }

  for (const g of GARMENTS.bottom) {
    const m = mat(g.color);
    if (g.kind === 'pants' || g.kind === 'shorts') {
      const isPants = g.kind === 'pants';
      // 裤腰挂上身：倾身时跟着躯干走，不会和上衣错开
      // 一直包到胯下：只到胯骨的话，两条裤腿之间那道 V 口会漏出肉色的骨盆，
      // 正面看就是一个说不清的凸起。最后一点收窄到 0.03 = 把裆封上。
      // 裤腰挂上身：倾身时跟着躯干走，不会和上衣错开。
      // 骨盆这段不能用「漏斗收到小半径」——那个高度躯干本身还有 0.19 宽，
      // 一收就把整个骨盆从裤子里捅出来（正面看就是一团肉）。
      // 照短裤的构造来：先贴着胯，到裆部才水平封口，腿从下面出来。
      bodyOf(g.id, latheMesh([
        [d.waistR + 0.012, d.waistY + 0.055],
        [d.hipR + 0.008, d.hipY + 0.020],
        [d.hipR + 0.004, d.hipY - 0.050],
        [d.hipR - 0.036, d.hipY - 0.105],
        [d.hipR - 0.090, d.hipY - 0.128],
        [0.030, d.hipY - 0.136],
      ], m, clothZ));
      for (const [g2, knee, side] of [[legL, kneeL, 'l'], [legR, kneeR, 'r']]) {
        if (isPants) {
          // 长裤分两段：大腿管 + 小腿管，跟着膝关节折
          const plen = d.thigh + 0.02;
          own(g.id, g2, taper(d.thighR1 + 0.010, d.thighR2 + 0.014, plen, m, 22)
            .translateY(-plen / 2));
          // 小腿这段要往上多包一截，盖过膝关节：只到下口的话，
          // 一跪下（膝盖折 1.5 弧度）裤腿就裂开一道缝，露出膝盖上的肉。
          /* ⚠️ 但这截不能靠"把圆台往上移"来做：膝盖折 80° 的时候，
             圆台的上盖会横向顶出去，正面看是一块方板（像护膝）。
             改用一颗布料球盖住关节——球在任何角度都是圆的，
             两个管口都缩回球里面，怎么折都不会露出上盖。 */
          const shinLen = shinTube + 0.03;
          own(g.id, knee, taper(d.shinR1 + 0.020, d.shinR2 + 0.018, shinLen, m, 22)
            .translateY(-shinLen / 2 + 0.015));
          const padR = Math.max(d.thighR2 + 0.014, d.shinR1 + 0.020) + 0.014;
          own(g.id, knee, blob(padR, padR * 0.92, padR, m, 20));
        } else {
          // 短裤不过膝，单段挂在髋上，膝盖动它不动
          own(g.id, g2, taper(d.thighR1 + 0.018, d.thighR2 + 0.024, d.thigh * 0.62, m, 22)
            .translateY(-d.thigh * 0.31));
        }
      }
    } else if (g.kind === 'skirt') {
      /* 裙摆的形状是跟"被上衣盖住的那一段"绑死的：
         上衣的下摆都落在胯骨附近（tee 1.29 / 衬衫 1.27 / 卫衣 1.195），
         裙腰如果在那儿就已经张到比下摆宽，两片曲面会有很长一段几乎重合，
         正面就会闪出一块锯齿（衬衣色或裙色，取决于谁的深度先赢）——
         用 polygonOffset 硬压只会把穿帮换个方向。
         正确做法：裙子在被盖住的那一段明显更窄（藏在衣服里面），
         出了下摆才开始张开，两者只在竖直方向"钻出来"，不产生大面积共面。

         ⚠️ 裙摆必须是"下端开口的圆台"，不能收成锥尖。收尖的话那条从裙摆
         收到尖点的面会横穿两条大腿：腿从它下面穿出去，就在裙子正面切出
         一块肉色楔形（2026-10-25 踩坑，采样确认是皮肤色，不是裙色）。
         裙腰比上衣窄、胯下直接敞开，腿是"从裙口出去"而不是"从裙面穿出"。 */
      bodyOf(g.id, latheMesh([
        [d.waistR + 0.004, d.waistY + 0.060],
        // 裙腰只有 hipR+0.014 的话，比大腿外侧只宽 0.02：躯干一前倾（裙挂在上身，
        // 腿挂在根节点，两者会错开）就在裙面上切出一小块肉色。留到 0.04 才稳。
        [d.hipR + 0.038, d.hipY - 0.030],
        [d.hipR + 0.085, d.hipY - 0.300],
      ], m, clothZ * 1.04, 48));
    }
  }

  for (const g of GARMENTS.shoes) {
    const m = mat(g.color, { roughness: 0.72 });
    for (const knee of [kneeL, kneeR]) {
      // 鞋：脚背一只椭球 + 鞋底一块扁片，比单个球更像鞋
      const shoe = blob(d.footW * 1.02, d.footH * 0.52, d.footLen * 0.56, m, 20);
      shoe.position.set(0, -d.shin + d.footH * 0.42, d.footLen * 0.27);
      own(g.id, knee, shoe);
      const sole = blob(d.footW * 1.04, d.footH * 0.16, d.footLen * 0.57, mat(shade(g.color, 0.82), { roughness: 0.8 }), 20);
      sole.position.set(0, -d.shin + d.footH * 0.09, d.footLen * 0.27);
      own(g.id, knee, sole);
    }
  }

  return {
    root, upper, upperInner, head, dims: d,
    armL, armR, elbowL, elbowR, legL, legR, kneeL, kneeR,
    hairParts, hairMat, garments, props: { ring },
  };
}

/* ══════════════════════ 换装 ══════════════════════ */

function applyOutfit(char, outfit) {
  const top = byId(GARMENTS.top, outfit.top);
  const isDress = top.kind === 'dress';
  // 连衣裙盖住下装：下装整组不显示，但用户的选择留着，脱下裙子还是原来那条裤子
  const showBottom = !isDress;

  for (const g of GARMENTS.top) {
    for (const m of char.garments[g.id] || []) m.visible = g.id === outfit.top;
  }
  for (const g of GARMENTS.bottom) {
    for (const m of char.garments[g.id] || []) m.visible = showBottom && g.id === outfit.bottom;
  }
  for (const g of GARMENTS.shoes) {
    for (const m of char.garments[g.id] || []) m.visible = g.id === outfit.shoes;
  }

  const hp = char.hairParts;
  const hairStyle = outfit.hair;
  hp.cap.visible = hp.back.visible = hp.bangs.visible = hp.bangs2.visible = true;
  hp.sideL.visible = hp.sideR.visible = hairStyle === 'bangs' || hairStyle === 'twin';
  hp.tailL.visible = hp.tailR.visible = hairStyle === 'twin';
  char.hairMat.color.set(byId(GARMENTS.hairColor, outfit.hairColor).color);

  return { isDress };
}

/* ══════════════════════ 姿势 ══════════════════════
 * 每个姿势只管两件事：两位角色的 holder 放哪、各个关节转多少。
 * 关节角度都是试出来的——改之前先看截图，别凭直觉调。 */

function resetActor(actor) {
  const { holder, char } = actor;
  holder.position.set(0, 0, 0);
  holder.rotation.set(0, 0, 0);
  char.root.position.set(0, char.groundY, 0);
  char.root.rotation.set(0, 0, 0);
  char.upper.rotation.set(0, 0, 0);
  char.head.rotation.set(0, 0, 0);
  char.armL.rotation.set(0, 0, -char.dims.armTilt);
  char.armR.rotation.set(0, 0, char.dims.armTilt);
  char.elbowL.rotation.set(0, 0, 0);
  char.elbowR.rotation.set(0, 0, 0);
  char.legL.rotation.set(0, 0, 0);
  char.legR.rotation.set(0, 0, 0);
  char.kneeL.rotation.set(0, 0, 0);
  char.kneeR.rotation.set(0, 0, 0);
  char.props.ring.visible = false;
}

/* ── 手臂：给"手要落在哪"，反解关节角 ────────────────────────────
 * 为什么要这一层：肩关节离身体中线只有 0.2，手臂却有 0.67 长。手写 rotation.z
 * 很容易把整条上臂转进躯干里——正面看只剩一截小臂浮在肚子上（牵手姿势就这么崩的）。
 * 直接给目标点，肩膀朝向和肘部弯曲都算出来，换身材也不用重新试角度。
 *
 * 反解用的是 rotation.set 的 XYZ 序（Rz 先作用）：
 *   手臂方向 dir = (sin z, −cos z·cos x, −cos z·sin x)
 * 于是 z = asin(dir.x)、x = atan2(−dir.z, −dir.y)。
 */
function aimArm(arm, dir) {
  const d = dir.clone().normalize();
  const z = Math.asin(THREE.MathUtils.clamp(d.x, -1, 1));
  const cz = Math.max(Math.cos(z), 0.16);   // 手臂完全横平的时候 x 无意义，兜一个下限免得除爆
  arm.rotation.set(Math.atan2(-d.z / cz, -d.y / cz), 0, z);
}

/** 让 side（−1 左 / 1 右）那只手尽量落到 target（角色自身坐标，与 upperInner 同系）。
 *
 *  ⚠️ 不能"肩膀对着目标 + 按余弦定理掰肘"就完事：肘一弯，手腕就离开了
 *  肩膀→目标那条射线，手会飘到目标上方去（下跪时她的手就飞到头顶了）。
 *  这里改成迭代：摆一次 → 量手腕实际在哪 → 按误差修方向 → 再摆，三次就收敛。
 *  每只手臂只在切姿势时算一次，代价可以忽略。
 *
 *  目标放在臂展之外是合法用法（"尽量往那边伸"）：肘角会被 clamp 到 0 = 伸直。
 *  垂着手、够不着的手，正是这么写的。 */
function reachTo(char, side, target) {
  const arm = side < 0 ? char.armL : char.armR;
  const elbow = side < 0 ? char.elbowL : char.elbowR;
  const shoulder = new THREE.Vector3(side * char.dims.armPivotX, char.dims.shoulderY, 0);
  const a = char.dims.upperArm;
  const b = char.dims.foreArm;
  const d = target.clone().sub(shoulder);
  // 肘弯多少由"目标离肩膀多远"定死：余弦定理，超过臂展就伸直
  const cos = (d.lengthSq() - a * a - b * b) / (2 * a * b);
  elbow.rotation.x = -Math.acos(THREE.MathUtils.clamp(cos, -1, 1));

  const dir = d.clone().normalize();
  const wrist = new THREE.Vector3();
  for (let i = 0; i < 3; i += 1) {
    aimArm(arm, dir);
    arm.updateWorldMatrix(true, true);
    wrist.set(0, -b, 0);
    elbow.localToWorld(wrist);            // 手腕的世界位置
    char.upperInner.worldToLocal(wrist);  // 换回角色坐标
    dir.add(target.clone().sub(wrist)).normalize();
  }
}

/** 同上，target 用"舞台坐标"（couple 那一层）——两人之间交握、搭肩这种都要用它。
 *
 * ⚠️ 不能用世界坐标。fitCamera 为了让人物绕自身中心转，每换一个姿势都会把
 * couple 整体平移一次（couple.position = -包围盒中心），平移量随姿势变。
 * 目标点如果写死成世界坐标，人和目标就会被这一下平移错开：
 * 同一个姿势点两次，手会落在两个不同的地方（实测差过 0.09）。
 * 舞台坐标跟着 couple 一起走，两个人之间的相对关系才是稳的。 */
function reachWorld(actor, side, target) {
  actor.holder.updateWorldMatrix(true, true);
  const couple = actor.holder.parent;
  const world = couple.localToWorld(target.clone());
  reachTo(actor.char, side, actor.char.upperInner.worldToLocal(world));
}

/* reach 表里一项是 [谁, 哪只手, 目标]。目标有两种写法：
 *   · 数组 [x, y, z]  → 那个人的自身坐标（跟着他的身高和接地走，跪下也不会指空）
 *   · 函数 (actors)=>V3 → 舞台坐标（两人之间握手、托着对方身体这种必须用这个）
 * 自动接地会让同一个人在不同姿势里高度差出 0.7，全身都写世界坐标必崩。 */

/* 关节角度的约定（改动作前先看这里，凭直觉调会拧成麻花）：
 *   arm.rotation.x  负 = 往前抬（朝镜头），正 = 往后
 *   arm.rotation.z  正负号跟 side 一致 = 往外张；反号 = 往身体中线收
 *   elbow.rotation.x  负 = 小臂往前折
 *   leg.rotation.x   负 = 大腿往前，正 = 往后
 *   knee.rotation.x  正 = 小腿往后折（膝盖弯的正常方向）
 *   upper.rotation.x 正 = 上身往前俯
 *   head.rotation.x  正 = 低头
 * 手臂优先用 reach 写（[谁, 哪只手, 世界坐标目标]），比手掰角度稳。
 * yaw 是这只姿势最上相的默认机位（用户仍可自己拖）：
 *   公主抱从正面看就是一坨，必须给到接近侧面的角度才读得出来。
 */
const NO_SINK = [0, 0];
const V = (x, y, z) => new THREE.Vector3(x, y, z);

/** 把"某人自身坐标里的一个点"换算成舞台坐标。姿势里描述两人的相对位置
 *  （我的戒指举到哪、她的手就跟到哪）时最常用——一个人的接地高度会变，
 *  但"我身上的某个点"永远跟着我走。 */
const on = (actor, x, y, z) => actor.holder.parent.worldToLocal(
  actor.char.upperInner.localToWorld(V(x, y, z)),
);

const POSES = [
  {
    id: 'side', label: '并肩', yaw: -0.16,
    apply(A, B) {
      A.holder.position.set(-0.52, 0, 0.04);
      A.holder.rotation.y = 0.17;
      B.holder.position.set(0.52, 0, -0.04);
      B.holder.rotation.y = -0.17;
      A.char.head.rotation.y = -0.16;
      A.char.head.rotation.z = 0.04;
      B.char.head.rotation.y = 0.16;
      B.char.head.rotation.z = -0.04;
    },
    /* 靠得近的那只手垂下去、略往对方那边偏，像随时要牵上。
       这里的点故意放在**臂展之外**（他臂展 0.67，这个点要 0.74）：够不到，
       IK 就把手臂放直，正好是"垂着手"的样子。反过来把它改到 1.45 那种
       够得到的高度，肘会折起来、手往前伸——两个人像端着看不见的托盘。 */
    reach: [
      [0, 1, () => V(-0.12, 1.24, 0.24)],
      [1, -1, () => V(0.12, 1.22, 0.22)],
    ],
  },
  {
    id: 'hand', label: '牵手', yaw: -0.22,
    apply(A, B) {
      A.holder.position.set(-0.40, 0, 0.02);
      A.holder.rotation.y = 0.30;
      B.holder.position.set(0.40, 0, 0.02);
      B.holder.rotation.y = -0.30;
      A.char.head.rotation.y = -0.26;
      B.char.head.rotation.y = 0.26;
      A.char.head.rotation.z = 0.06;
      B.char.head.rotation.z = -0.06;
    },
    /* 两人内侧的手在两人中间、胯侧高处交握。差 0.02 是让手腕错开，
       不然两个椭球完全重叠。高度就是"垂手能牵到"的那一点：他 1.38 / 她 1.35，
       到这个高度手臂只剩十几度弯，看着才是自然垂着的手。 */
    reach: [
      [0, 1, () => V(0.0, 1.38, 0.26)],
      [1, -1, () => V(0.02, 1.35, 0.24)],
    ],
  },
  {
    id: 'kneel', label: '单膝下跪', yaw: -0.72, sink: [0.06, 0],
    /* 构图：两个人一左一右，各自斜 30° 朝镜头 / 朝对方。
       他跪着只剩 1.35 高（头顶），肩膀 1.39；她站着肩膀 1.89。
       所以"戒指举到她腰间"是做不到的——她的手臂只有 0.63，从 1.89 的手
       往下够不到 1.5 以下（中间还隔着 0.3 的水平距离）。旧版就是硬给的
       低目标，IK 够不到就把手臂拉成一根笔直的棍子横在他面前像要击掌。
       现在把戒指点定在两人中间偏他那一侧、高度 1.5 左右：他抬一点手就够到，
       她垂下手也够到，两个人的肘都是自然弯的。 */
    apply(A, B) {
      A.holder.position.set(-0.52, 0, 0.06);
      A.holder.rotation.y = 1.25;          // 转过 70°，面向她
      A.char.upper.rotation.x = 0.05;
      // 左腿跪地：大腿竖直，小腿向后平放
      A.char.legL.rotation.x = 0.10;
      A.char.kneeL.rotation.x = 1.58;
      // 右腿撑在身前：大腿抬平，小腿竖直落地
      A.char.legR.rotation.x = -1.42;
      A.char.kneeR.rotation.x = 1.38;
      A.char.props.ring.visible = true;
      A.char.head.rotation.x = -0.20;   // 抬头看她
      A.char.head.rotation.y = 0.10;
      // 身子朝镜头，头扭过去看他——两侧脸都留在取景里
      B.holder.position.set(0.42, 0, 0.04);
      B.holder.rotation.y = -0.05;
      B.char.upper.rotation.x = 0.16;
      B.char.head.rotation.x = 0.26;
      // 只扭 0.28：再大就把整张脸转成侧影，正面只剩一把头发
      B.char.head.rotation.y = -0.28;
    },
    reach: [
      /* 他的右手：他自己坐标系里"齐肩、往前伸"。跪下去整体矮 0.46，
         y=1.98 落到世界约 1.52 —— 正好是她的腰线，也是求婚该举的高度。
         z=0.50 让上臂斜着向前，肘弯约 75°；只写 y 不写 z 的话手会停在
         耳朵边上，看着像在打电话。 */
      [0, 1, [0.06, 1.98, 0.50]],
      /* 她的左手：同一个点再往上偏她自己那侧一点。用 on() 从"他的戒指点"
         换算过去，是唯一不会被接地高度带偏的写法——戒指举多高，她的手就跟到多高。 */
      [1, -1, (a) => on(a[0], 0.06, 1.98, 0.50).add(V(0.07, 0.14, 0.03))],
    ],
  },
  {
    id: 'carry', label: '抱起来', yaw: -0.06, ground: [true, false],
    /* 这一条试过两次都不成立，记下来免得再走回头路：
       ① 原来的"公主抱"（她横躺在他臂弯里）——裙子跟着髋一起横过来，
          变成一片斜插在胯上的紫色"帆"，腿一折就穿出裙面。裙子是刚性锥面，
          不会随重力垂，除非上布料模拟，否则这个姿势永远有洞。
       ② "面对面举起来"——她被举高之后整个人正好糊在他前面，把他的脸和
          上半身全挡住，画面读起来是"一个女人站在他面前"。
       现在这版是"从背后把她抱起来"：两个人朝同一个方向，他从后面环住她的腰
       往上提，她的脚离地。两张脸都在取景里、遮挡最少、"被抱起来"这个动作
       靠脚离地和两条小臂同时说清楚，而且穿裙子穿裤子都成立。 */
    apply(A, B) {
      // A 站在后面，双臂从两侧环过去
      A.holder.position.set(-0.02, 0, 0);
      A.holder.rotation.y = 0.04;
      A.char.upper.rotation.x = -0.06;   // 微微后仰当配重
      A.char.head.rotation.x = -0.06;
      A.char.head.rotation.z = 0.10;     // 头往她那边靠

      /* B 在他前面，离地 0.26。ground:[true,false] 只给他接地，
         她的高度就是这里写的——写了就固定，不会被自动接地改掉。
         离地 0.26 是折中：再高她的头就窜到他头顶上去，看着像被举在杆子上；
         再低脚没离开地面，读不出"抱起来"。 */
      B.holder.position.set(0.20, 0.26, 0.30);
      B.holder.rotation.y = -0.16;
      B.char.upper.rotation.x = 0.04;
      B.char.head.rotation.x = 0.04;
      B.char.head.rotation.z = -0.22;    // 头歪向他
      /* 手臂就自然垂在身侧（只比站姿张开一点点）。张到 0.6 以上会像被吊起来，
         而且袖子的球盖会从肩头翘起来露出腋下的缝。 */
      B.char.armL.rotation.set(0.02, 0, -0.26);
      B.char.armR.rotation.set(0.05, 0, 0.24);
      B.char.elbowL.rotation.x = -0.20;
      B.char.elbowR.rotation.x = -0.15;
      // 腿自然垂着，膝盖往后折一点
      B.char.legL.rotation.x = 0.12;
      B.char.legR.rotation.x = 0.20;
      B.char.kneeL.rotation.x = 0.46;
      B.char.kneeR.rotation.x = 0.62;
    },
    reach: [
      /* 他的手扣在她的胯侧（托着提起来），这是"举起来"最直接的视觉信号。
         ⚠️ 位置只能落在胯骨这一层：她腰上的衣服半径是 0.177、裙子在胯上
         是 0.25。手要是按腰宽去摆（±0.12）就会整个埋进上衣里，只剩两个
         椭圆贴在肚子上——像贴了两个手掌印；按胯宽摆（±0.255）才是
         "从两侧扣住"的样子，小臂也露在剪影外面。 */
      [0, -1, (a) => on(a[1], -0.255, 1.25, 0.02)],
      [0, 1, (a) => on(a[1], 0.255, 1.27, 0.02)],
    ],
  },
];

function applyPose(poseId, actors) {
  const pose = POSES.find((p) => p.id === poseId) || POSES[0];
  /* 姿势里写的世界坐标（"手落在两点中间"这种）都是"场景没被转过"时的坐标。
     用户拖动过视角之后场景整体转了一个角度，不归零就会按转过的坐标系去指手，
     表现为"拖一下再换姿势，手臂全歪"。算完再还原。 */
  const spin = actors[0].holder.parent?.parent;
  const spinYaw = spin ? spin.rotation.y : 0;
  if (spin) spin.rotation.y = 0;

  for (const actor of actors) resetActor(actor);
  pose.apply(actors[0], actors[1]);
  /* 自动接地：按姿势摆完后量一下世界包围盒，把最低点压到 y=0。
     手写 holder.position.y 永远差一点——换个身高、换个鞋就跟地面脱开，
     之前"站着的那位浮在半空"就是这么来的。被抱起的那位不接地（ground:[true,false]）。 */
  const grounded = pose.ground || [true, true];
  actors.forEach((actor, i) => {
    if (!grounded[i]) return;
    actor.holder.updateWorldMatrix(true, true);
    const box = new THREE.Box3().setFromObject(actor.char.root);
    actor.holder.position.y -= box.min.y;
    // sink[i]：接地之后再往下压。跪姿的膝盖受力，重心比"脚掌刚好碰地"更低，
    // 不压的话人看着像踮着脚半蹲。脚陷进地面看不见（场景里没有地面，只有一层影子）。
    // ⚠️ 必须按人分开：写成单个数字会把站着的那位一起压下去，两人就一样高了。
    const sink = pose.sink || NO_SINK;
    actor.holder.position.y -= sink[i] || 0;
  });
  /* 手臂最后再摆：接地会改 holder.y，早摆的话所有"手要落在某个世界坐标"的目标都会指歪。
     先把两个人的世界矩阵刷一遍——目标点可能是"对方的肩膀"这种跨角色的位置。 */
  if (pose.reach) {
    for (const [who, side, at] of pose.reach) {
      // ⚠️ 每条之前都要刷矩阵：上一条 reach 可能刚把某只手转过去，
      // 而"她把手搭在他的戒指上"这种目标读的就是那只手的实时位置，不刷就是旧值。
      for (const actor of actors) actor.holder.updateWorldMatrix(true, true);
      if (Array.isArray(at)) reachTo(actors[who].char, side, V(at[0], at[1], at[2]));
      else reachWorld(actors[who], side, at(actors));
    }
  }
  if (spin) {
    spin.rotation.y = spinYaw;
    spin.updateWorldMatrix(true, true);
  }
  // 记下姿势给定的头/上身角度，呼吸动画以此为基准做叠加，不会把姿势冲掉
  for (const actor of actors) {
    actor.base = {
      headY: actor.char.head.rotation.y,
      headZ: actor.char.head.rotation.z,
      phase: actor === actors[0] ? 0 : 1.7,
    };
  }
  return pose;
}

/* ══════════════════════ 挂载 / 卸载 ══════════════════════ */

let scene = null; // 当前挂载的运行时；pause() 之后仍然保留，用来把 canvas 接回来

function outfitRowsHtml(outfit) {
  const row = (key, title, items, withColor) => {
    const buttons = items.map((it) => {
      const active = outfit[key] === it.id;
      const dot = withColor && it.color ? `<i class="dressup-dot" style="background:${it.color}"></i>` : '';
      return `<button type="button" class="dressup-chip${active ? ' active' : ''}" data-dressup="${key}" data-value="${it.id}" aria-pressed="${active}">${dot}${it.label}</button>`;
    }).join('');
    return `<div class="dressup-row"><span class="dressup-label">${title}</span><div class="dressup-chips">${buttons}</div></div>`;
  };
  return `
    ${row('top', '上装', GARMENTS.top, true)}
    <div data-row-lock>
      ${row('bottom', '下装', GARMENTS.bottom, true)}
    </div>
    ${row('shoes', '鞋子', GARMENTS.shoes, true)}
    ${row('hair', '发型', GARMENTS.hair, false)}
    ${row('hairColor', '发色', GARMENTS.hairColor, true)}`;
}

function poseRowHtml(poseId) {
  return POSES.map((p) => `<button type="button" class="dressup-chip${p.id === poseId ? ' active' : ''}"
    data-pose="${p.id}" aria-pressed="${p.id === poseId}">${p.label}</button>`).join('');
}

/**
 * 挂载造型间。可以重复调用：上一次 pause() 留下的 canvas 会被接回 DOM，
 * 相机角度和 WebGL 上下文都不会丢（页面被 SSE 触发重渲染时靠这个）。
 */
export function mount(host, opts = {}) {
  const storeKey = 'dressup:' + (opts.userId || 'me');

  // 旧版本只存了一个人的搭配；读到摊平的 outfit 就当成 A 的，B 用默认
  let st = { a: { ...DEFAULT_A }, b: { ...DEFAULT_B }, pose: 'side', editing: 'a' };
  try {
    const saved = JSON.parse(localStorage.getItem(storeKey) || '{}');
    if (saved && saved.top) st.a = { ...DEFAULT_A, ...saved };
    else {
      if (saved.a) st.a = { ...DEFAULT_A, ...saved.a };
      if (saved.b) st.b = { ...DEFAULT_B, ...saved.b };
      if (saved.pose && POSES.some((p) => p.id === saved.pose)) st.pose = saved.pose;
      if (saved.editing === 'b') st.editing = 'b';
    }
  } catch { /* 存的东西坏了就当没存过 */ }

  host.innerHTML = `
    <div class="dressup-wrap">
      <section class="card dressup-stage">
        <div class="dressup-chips dressup-poses" id="dressup-poses">${poseRowHtml(st.pose)}</div>
        <div class="dressup-canvas-host" id="dressup-canvas-host"></div>
        <p class="small-note dressup-hint">按住拖动，可以绕着转一圈</p>
        <div class="inline-actions">
          <button type="button" class="button small soft" data-dressup="random">换个搭配</button>
          <button type="button" class="button small secondary" data-dressup="mirror">两人穿一样</button>
          <button type="button" class="button small secondary" data-dressup="reset">回到默认</button>
        </div>
      </section>
      <section class="card dressup-controls">
        <div class="dressup-chips dressup-who" id="dressup-who">
          <button type="button" class="dressup-chip" data-who="a">我</button>
          <button type="button" class="dressup-chip" data-who="b">TA</button>
        </div>
        <div class="section-heading"><h2 id="dressup-title">我在穿什么</h2></div>
        <div id="dressup-rows">${outfitRowsHtml(st.a)}</div>
        <p class="small-note">现在只是原型：搭配存在这台设备的浏览器里，还不会同步给 TA。</p>
      </section>
    </div>`;

  const canvasHost = host.querySelector('#dressup-canvas-host');

  // ── 建场景（首次）或复用（回到本页） ──
  if (!scene) {
    let renderer;
    try {
      renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    } catch {
      canvasHost.innerHTML = '<p class="hint">这台设备的浏览器没有开启 3D（WebGL），换装暂时看不到。</p>';
      return;
    }
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setClearAlpha(0);
    // 标准材质不像 toon 那样自带高对比色阶，稍加曝光补偿压住白衣服的高光
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.05;

    const sc = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 60);

    /* 灯光按「摄影棚三点光」配：标准材质的光衰减是物理的，强度要跟 toon 差一个量级。
       天光补冷、主光从右上前方、轮廓光从左后方把肩线勾出来——
       少了轮廓光，深色头发和背景会糊成一片。 */
    sc.add(new THREE.HemisphereLight(0xffffff, 0xe0cdd6, 1.15));
    const key = new THREE.DirectionalLight(0xfff4ee, 2.35);
    key.position.set(2.4, 4.2, 3.0);
    sc.add(key);
    const fill = new THREE.DirectionalLight(0xffffff, 0.55);
    fill.position.set(-3.2, 1.8, 2.2);
    sc.add(fill);
    const rim = new THREE.DirectionalLight(0xffe7ef, 0.85);
    rim.position.set(-2.2, 1.6, -2.2);
    sc.add(rim);

    const spin = new THREE.Group();   // 拖动转的是这一层
    sc.add(spin);
    const couple = new THREE.Group(); // 两个人的共同父节点
    spin.add(couple);

    const actors = [];
    for (let i = 0; i < 2; i += 1) {
      const char = buildCharacter(i === 0 ? BODIES.m : BODIES.f);   // 0 = 我，1 = TA；男方高一点
      const box = new THREE.Box3().setFromObject(char.root);
      char.groundY = -box.min.y;      // 脚踩到 y=0
      char.root.position.y = char.groundY;
      const holder = new THREE.Group(); // 姿势只动 holder，root 只负责接地偏移
      holder.add(char.root);
      couple.add(holder);
      actors.push({ holder, char, base: { headY: 0, headZ: 0, phase: i * 1.7 } });
    }

    const shadow = new THREE.Mesh(
      new THREE.CircleGeometry(1.0, 44),
      new THREE.MeshBasicMaterial({ map: shadowTexture(), transparent: true, depthWrite: false }),
    );
    shadow.rotation.x = -Math.PI / 2;
    shadow.position.y = 0.004;
    // 挂在 spin 上而不是 couple 上：couple 会被 fitCamera 平移去居中，
    // 阴影跟着平移就会离开脚下（地上一片影子，人在旁边）
    spin.add(shadow);

    scene = { renderer, scene: sc, camera, spin, couple, shadow, actors, raf: 0, running: false };
  }

  const { renderer, camera, couple, actors } = scene;
  canvasHost.appendChild(renderer.domElement);

  /* ── 取景：按当前偏航下的投影算，人物填满画面 ──
     坑：按包围球半径算距离，球半径是"半对角线"，比实际宽高都大，
     结果人只占画面一半。改成分别算横向投影和纵向高度，取更紧的那个。 */
  const fitCamera = () => {
    // 量尺寸时先把偏航归零：否则量到的是"转过去之后"的盒子，取景会跟着角度抖
    const yaw = scene.spin.rotation.y;
    scene.spin.rotation.y = 0;
    couple.position.set(0, 0, 0);
    couple.updateWorldMatrix(true, true);
    const box = new THREE.Box3().setFromObject(couple);
    const c = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    // 把两人的几何中心挪到转轴原点：拖动才是绕人转，不是绕世界原点转。
    // y 不挪 —— 接地阴影要留在 y≈0。
    couple.position.set(-c.x, 0, -c.z);
    scene.spin.rotation.y = yaw;
    scene.spin.updateWorldMatrix(true, true);

    const vHalf = Math.tan(THREE.MathUtils.degToRad(camera.fov / 2));
    const hHalf = vHalf * camera.aspect;
    // 横向量"当前角度下的实际投影宽度"，转侧身时会变窄，取景就能自动收紧
    const spanX = size.x * Math.abs(Math.cos(yaw)) + size.z * Math.abs(Math.sin(yaw));
    const dist = Math.max(spanX / 2 / hHalf, size.y / 2 / vHalf) * 1.14;
    // 阴影跟着人的脚印放大：两个人站着时它不是一个小圆点
    scene.shadow.scale.setScalar(Math.max(spanX / 2, 0.85));
    camera.position.set(0, c.y + size.y * 0.03, dist);
    camera.lookAt(0, c.y, 0);
  };

  /* ── 尺寸自适应 ── */
  const resize = () => {
    const w = canvasHost.clientWidth || 1;
    const h = canvasHost.clientHeight || 1;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    fitCamera();  // 竖屏/横屏可用宽度不同，取景要跟着重算
  };
  resize();
  const ro = new ResizeObserver(resize);
  ro.observe(canvasHost);

  /* ── 拖动转圈 ── */
  const cv = renderer.domElement;
  let dragging = false;
  let lastX = 0;
  const onDown = (ev) => {
    dragging = true;
    lastX = ev.clientX;
    cv.setPointerCapture?.(ev.pointerId);
  };
  const onMove = (ev) => {
    if (!dragging) return;
    scene.spin.rotation.y += (ev.clientX - lastX) * 0.012;
    lastX = ev.clientX;
  };
  const onUp = () => {
    if (!dragging) return;
    dragging = false;
    // 转到侧面后投影变窄，松手时重新取景，把空出来的地方填上
    fitCamera();
  };
  cv.addEventListener('pointerdown', onDown);
  cv.addEventListener('pointermove', onMove);
  cv.addEventListener('pointerup', onUp);
  cv.addEventListener('pointercancel', onUp);

  /* ── 渲染循环 ── */
  const clock = new THREE.Clock();
  // 用户在系统里关了动效（或空间设置关了动效），就不做呼吸/摆动，只画一帧静态画面
  const calm = document.documentElement.classList.contains('reduced-motion')
    || window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
  const tick = () => {
    if (!scene || !scene.running) return;
    if (!calm) {
      const t = clock.getElapsedTime();
      for (const actor of scene.actors) {
        const { char, base } = actor;
        // 呼吸 + 微摆：静止的 3D 模型看着像一张贴图，一点微小位移就"活"了
        char.root.position.y = char.groundY + Math.sin(t * 1.7 + base.phase) * 0.009;
        char.head.rotation.z = base.headZ + Math.sin(t * 0.9 + base.phase) * 0.020;
        char.head.rotation.y = base.headY + Math.sin(t * 0.62 + base.phase) * 0.040;
      }
    }
    renderer.render(scene.scene, camera);
    scene.raf = requestAnimationFrame(tick);
  };
  scene.running = true;
  cancelAnimationFrame(scene.raf);
  scene.raf = requestAnimationFrame(tick);

  /* ── 交互 ── */
  const save = () => {
    try { localStorage.setItem(storeKey, JSON.stringify(st)); } catch { /* 隐私模式写不进去，忽略 */ }
  };

  const current = () => st[st.editing];
  const rowsEl = host.querySelector('#dressup-rows');
  const titleEl = host.querySelector('#dressup-title');
  const lockEl = host.querySelector('[data-row-lock]');

  const syncPanel = () => {
    // 两位角色的外观各自刷新
    const a = applyOutfit(actors[0].char, st.a);
    const b = applyOutfit(actors[1].char, st.b);
    // 只有正在编辑的那一位需要锁下装提示
    const locked = st.editing === 'a' ? a.isDress : b.isDress;
    lockEl?.classList.toggle('is-locked', locked);
    if (lockEl) lockEl.title = locked ? '穿连衣裙时下装不显示' : '';
    // 高亮当前编辑对象
    host.querySelectorAll('[data-who]').forEach((btn) => {
      const on = btn.dataset.who === st.editing;
      btn.classList.toggle('active', on);
      btn.setAttribute('aria-pressed', String(on));
    });
    titleEl.textContent = st.editing === 'a' ? '我在穿什么' : 'TA 在穿什么';
    // 高亮衣服
    const o = current();
    host.querySelectorAll('[data-dressup][data-value]').forEach((btn) => {
      const on = o[btn.dataset.dressup] === btn.dataset.value;
      btn.classList.toggle('active', on);
      btn.setAttribute('aria-pressed', String(on));
    });
    refit();
  };

  const refit = () => {
    scene.couple.updateWorldMatrix(true, true);
    fitCamera();
  };

  const setPose = (id) => {
    const pose = applyPose(id, actors);
    st.pose = pose.id;
    scene.spin.rotation.y = pose.yaw; // 每个姿势自带一个最上相的机位
    host.querySelectorAll('[data-pose]').forEach((btn) => {
      const on = btn.dataset.pose === st.pose;
      btn.classList.toggle('active', on);
      btn.setAttribute('aria-pressed', String(on));
    });
    refit();
  };

  const onClick = (ev) => {
    const poseBtn = ev.target.closest('[data-pose]');
    if (poseBtn && host.contains(poseBtn)) {
      setPose(poseBtn.dataset.pose);
      save();
      return;
    }
    const whoBtn = ev.target.closest('[data-who]');
    if (whoBtn && host.contains(whoBtn)) {
      st.editing = whoBtn.dataset.who;
      rowsEl.innerHTML = outfitRowsHtml(current());
      syncPanel();
      save();
      return;
    }
    const btn = ev.target.closest('[data-dressup]');
    if (!btn || !host.contains(btn)) return;
    const key = btn.dataset.dressup;
    const o = current();
    if (key === 'random') {
      for (const k of Object.keys(DEFAULT_A)) {
        o[k] = GARMENTS[k][Math.floor(Math.random() * GARMENTS[k].length)].id;
      }
    } else if (key === 'mirror') {
      // 两人穿一样的：把当前这位的搭配复制过去
      const copy = { ...current() };
      st[st.editing === 'a' ? 'b' : 'a'] = copy;
    } else if (key === 'reset') {
      Object.assign(o, st.editing === 'a' ? DEFAULT_A : DEFAULT_B);
    } else if (key && btn.dataset.value) {
      o[key] = btn.dataset.value;
    }
    rowsEl.innerHTML = outfitRowsHtml(current());
    syncPanel();
    save();
  };
  host.addEventListener('click', onClick);

  setPose(st.pose);
  syncPanel();

  /* ── 卸载：只解绑，不动 canvas（要留给下一次挂载） ── */
  scene.detach = () => {
    cancelAnimationFrame(scene.raf);
    scene.running = false;
    ro.disconnect();
    cv.removeEventListener('pointerdown', onDown);
    cv.removeEventListener('pointermove', onMove);
    cv.removeEventListener('pointerup', onUp);
    cv.removeEventListener('pointercancel', onUp);
    host.removeEventListener('click', onClick);
  };
}

/** 页面要重渲染（或用户离开）前调用：暂停循环并把 canvas 摘下，避免上下文丢失。 */
export function pause() {
  if (!scene) return;
  scene.detach?.();
  scene.detach = null;
  scene.renderer.domElement.remove();
}
