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
    /* 头颅截面（2026-10-25 重排）：最宽点上移到额骨/太阳穴(0.146@0.070)，
       下颌从颧骨就开始明显收窄(0.112@-0.065)、颏部收到 0.080——
       旧版最宽点在眼线、下颌几乎不收，正面是一颗下宽上窄的"梨"。 */
    headShape: [[0.004, -0.172], [0.044, -0.162], [0.080, -0.130], [0.112, -0.065],
      [0.134, 0.000], [0.146, 0.070], [0.140, 0.125], [0.115, 0.168], [0.060, 0.192], [0.004, 0.196]],
    neckR: 0.086, neckTopR: 0.064, neckBot: 2.045, neckTop: 2.240,
    // shoulderY = 手臂支点。它必须比躯干顶点低一截：袖山是半个球，
    // 球顶会再抬 0.1 上去，支点压在顶点上就会顶出两个"肩上的气球"。
    shoulderY: 2.000, waistY: 1.520, hipY: 1.285, kneeY: 0.720, ankleY: 0.095,
    chestR: 0.208, waistR: 0.156, hipR: 0.226, shoulderR: 0.152, torsoZ: 0.80,
    /* 截面从下往上：胯 → 腰（收）→ 胸（鼓）→ 肩（平）→ 斜方肌（缓收）→ 颈根。
       2026-10-25 对照低模基础人体参考图校正：肩胸段加宽拉平（0.196→0.208），
       腰再收一档（0.162→0.156），1.65 处的腰肋略收——正面剪影才是
       "倒三角 + V 型收腰"，而不是一根上下一边粗的柱子。 */
    torso: [[0.004, 1.150], [0.196, 1.200], [0.226, 1.270], [0.200, 1.380], [0.156, 1.520],
      [0.166, 1.650], [0.196, 1.780], [0.208, 1.870], [0.206, 1.940], [0.188, 2.000],
      [0.152, 2.045], [0.112, 2.080], [0.088, 2.105]],
    armPivotX: 0.164, armTilt: 0.19,
    upperArm: 0.372, foreArm: 0.382, handLen: 0.180,
    upR1: 0.084, upR2: 0.062, foreR1: 0.062, foreR2: 0.050,
    hipPivotX: 0.098, thigh: 0.565, shin: 0.625,
    thighR1: 0.126, thighR2: 0.100, shinR1: 0.094, shinR2: 0.062,
    footLen: 0.235, footH: 0.100, footW: 0.070,
  },
  // 女方：2.38 高 / 头 0.34 → 6.9 头身；肩窄、胯宽、腰更收
  f: {
    h: 2.380,
    headR: 0.142, headY: 2.205, headSZ: 1.02,
    headShape: [[0.004, -0.158], [0.040, -0.149], [0.074, -0.120], [0.104, -0.058],
      [0.124, 0.002], [0.134, 0.065], [0.129, 0.118], [0.104, 0.158], [0.054, 0.180], [0.004, 0.184]],
    neckR: 0.073, neckTopR: 0.054, neckBot: 1.900, neckTop: 2.075,
    shoulderY: 1.890, waistY: 1.455, hipY: 1.215, kneeY: 0.675, ankleY: 0.088,
    chestR: 0.192, waistR: 0.136, hipR: 0.216, shoulderR: 0.126, torsoZ: 0.86,
    /* 2026-10-25 对照参考图：胸段加鼓（0.186→0.192）、腰收窄（0.144→0.136）、
       胯加宽（0.208→0.214），torsoZ 0.82→0.86 —— 车削体前后一起加深，
       侧影才有了胸和臀的起伏，正面腰臀反差拉大才是沙漏形。
       ⚠️ 衣服从这套曲线自动推出（topProfile/clothZ/裤腰），改这里衣服自动跟。 */
    torso: [[0.004, 1.085], [0.184, 1.130], [0.214, 1.200], [0.198, 1.310], [0.136, 1.455],
      [0.150, 1.580], [0.176, 1.715], [0.192, 1.795], [0.188, 1.855], [0.166, 1.900],
      [0.134, 1.932], [0.098, 1.955], [0.078, 1.968]],
    armPivotX: 0.147, armTilt: 0.19,
    upperArm: 0.352, foreArm: 0.364, handLen: 0.166,
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
const DEFAULT_A = { top: 'tee-pink', bottom: 'pants-navy', shoes: 'sneaker-white', hair: 'bob', hairColor: 'ink' };
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

/** 一段肢体：一条"半径随长度变化"的曲线绕轴成型。
 *  ⚠️ 别再用"圆台"做手臂腿——圆台就是一根锥子，从肩到肘一个斜率，
 *  弯起来能数出节、看侧面像套叠的管子。真实四肢是一条曲线：
 *  三角肌下鼓、上臂中段收、肘上细、前臂上段再鼓一次、到手腕明显收窄。
 *  手腕和脚踝那两处收窄是最出效果的，一眼就从"积木"变成"人"。
 *
 *  profile 写成 [[y, r], ...]，y 从 0（近端，插进躯干那头）到 −len（远端）。 */
function limb(profile, m, seg = 30, samples = 20) {
  /* ⚠️ 不能直接拿 profile 去 lathe：那样每两个控制点之间是一段圆锥，
     圆锥之间的斜率是断的，弯起来就"数得出节"（小腿上会有一圈硬折线）。
     用样条穿过这些点再密采样，四肢才是一条连续的曲线。
     seg=30：管子是 22 段时，多边形面片会和关节球面交替争深度，
     膝盖顶上有一圈淡色虚线（2026-10-25）；提到 30 交界就是一条细线。 */
  const curve = new THREE.SplineCurve(profile.map(([y, r]) => new THREE.Vector2(r, y)));
  const pts = curve.getPoints(samples).map((v) => [Math.max(0.001, v.x), v.y]);
  return new THREE.Mesh(lathe(pts, seg), m);
}

/** 手：手掌 + 四根并拢的手指 + 一根拇指。
 *  以前是一只压扁的椭球，正面看就是一把勺子。这个尺寸下（手长 0.18，
 *  桌面截图约 20 像素）指缝根本看不清，但只要手指的轮廓有起伏、拇指从
 *  侧面支出来，大脑就会把它读成手。拇指是"读成手"的关键那一根。
 *
 *  ⚠️ 手掌不能用一个椭球：椭球在手腕那一头是个圆顶，比前臂还细，
 *  接上去就是一圈"袖口"。手掌要用 lathe 收口（上端细、下端方），
 *  再把 z 压扁——手的横截面本来就是扁的。 */
function makeHand(d, side, m) {
  const H = d.handLen;
  const g = new THREE.Group();
  // 手掌：上端收进前臂里（0.038 < 腕 0.044），往下撑宽到 0.058，末端收方
  const palmProfile = [
    [0.020, H * 0.21],
    [-0.10 * H, H * 0.30],
    [-0.34 * H, H * 0.325],
    [-0.52 * H, H * 0.30],
    [-0.60 * H, H * 0.245],
    [-0.64 * H, H * 0.13],
  ];
  const palm = new THREE.Mesh(lathe(palmProfile.map(([y, r]) => [r, y]), 18), m);
  palm.scale.z = 0.46;            // 手掌是扁的
  g.add(palm);

  // 四指：并在一起的一排胶囊，整排往前倾一点（手指是松的，不会笔直朝下）
  const fingers = new THREE.Group();
  fingers.rotation.x = -0.20;
  const fr = H * 0.086;
  const flen = H * 0.18;
  for (let i = 0; i < 4; i += 1) {
    const k = i - 1.5;                       // −1.5 … 1.5
    const f = new THREE.Mesh(new THREE.CapsuleGeometry(fr, flen - Math.abs(k) * H * 0.022, 3, 10), m);
    f.position.set(k * H * 0.163, -H * 0.60 - flen * 0.42, 0);
    f.rotation.z = -k * 0.07;
    fingers.add(f);
  }
  g.add(fingers);

  // 拇指：从掌根内侧斜出去。两侧朝向相反，所以按 side 取号
  const thumb = new THREE.Mesh(new THREE.CapsuleGeometry(H * 0.095, H * 0.17, 3, 10), m);
  thumb.position.set(-side * H * 0.245, -H * 0.50, H * 0.075);
  thumb.rotation.set(0.34, 0, -side * 0.98);
  g.add(thumb);
  return g;
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

/* ── 腮红：径向渐变的贴图 ────────────────────────────────────────
   以前是一个半透明椭球，边缘一圈硬边，像脸上贴了张粉色圆贴纸。
   渐变到 0 才不会露出边界——脸上没有"腮红的边"。 */
function blushTexture() {
  const size = 64;
  const cv = document.createElement('canvas');
  cv.width = cv.height = size;
  const ctx = cv.getContext('2d');
  const g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  g.addColorStop(0, 'rgba(230,120,135,0.50)');
  g.addColorStop(0.45, 'rgba(232,130,145,0.26)');
  g.addColorStop(1, 'rgba(236,150,160,0)');
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
  const blushMat = new THREE.MeshBasicMaterial({ map: blushTexture(), transparent: true, depthWrite: false });
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

  /* —— 手臂：肩 → 肘两段，半径走曲线（见 limb 的注释） —— */
  const armL = new THREE.Group();
  const armR = new THREE.Group();
  const elbowL = new THREE.Group();
  const elbowR = new THREE.Group();
  const wristR = d.foreR2 * 0.88;   // 真实手腕比前臂细一截
  /* 关节的"公称半径"：上下两段在关节处的半径取成同一个值（elbowJ / kneeJ）。
     ⚠️ 但"球和管相切就不会有折线"只对直筒成立——两段管在靠近关节时都在
     收窄（锥面），与球面近乎平行，间隙小于深度缓冲就会闪锯齿，见下面的
     jointOver 注释。 */
  const elbowJ = (d.upR2 + d.foreR1) / 2;
  const kneeJ = (d.thighR2 + d.shinR1) / 2;
  /* 关节两段的接法（照抄裤管膝盖验证过的结构，别再回到"两段锥面 + 切线球"）：
     两段管在关节处如果继续收窄，管面就和关节球面近乎平行地贴着走一长段，
     间隙小于深度缓冲精度，裸露的膝盖/手肘会闪出一圈针脚状锯齿。
     正确做法：上段管先收到关节公称半径，然后以**恒定半径的直段越过关节中心**；
     下段管也从中心上方同一半径接管。关节球加大 2.5%，从外面完整包住两个管口。
     管口直段越过的长度 ≤ 0.18*J，保证屈肘/屈膝 90° 时管口边缘仍然缩在球内
     （sqrt(J² + (0.18J)²) < 1.025J）。 */
  const jointOver = (J) => J * 0.18;
  const armUpperProfile = [
    [0.020, d.upR1 * 1.01],
    [-0.10 * d.upperArm, d.upR1 * 1.10],   // 二头肌最鼓（短袖以下全露，这段曲线管不管事一眼分明）
    [-0.34 * d.upperArm, d.upR1 * 0.97],
    [-0.62 * d.upperArm, d.upR2 * 1.18],
    [-0.88 * d.upperArm, elbowJ * 1.02],
    [-(d.upperArm + jointOver(elbowJ)), elbowJ],
  ];
  const armForeProfile = [
    [jointOver(elbowJ), elbowJ],
    [-0.13 * d.foreArm, d.foreR1 * 1.05],  // 前臂上段再鼓一次
    [-0.44 * d.foreArm, d.foreR1 * 0.87],
    [-0.76 * d.foreArm, wristR * 1.10],
    [-d.foreArm, wristR],
  ];
  for (const [g, elbow, side] of [[armL, elbowL, -1], [armR, elbowR, 1]]) {
    g.position.set(side * d.armPivotX, d.shoulderY, 0);
    g.rotation.z = side * d.armTilt;
    // 三角肌：缺了这一坨，手臂和躯干之间会有一道缝。
    // 但它必须整个缩在袖子里——大了就顶穿袖子，肩头露出一颗肉球。
    const delt = blob(d.upR1 * 1.06, d.upR1 * 0.62, d.upR1 * 1.04, skinMat, 20);
    delt.position.y = -0.030;
    g.add(delt);
    g.add(limb(armUpperProfile, skinMat));
    elbow.position.y = -d.upperArm;
    // 球加大 2.5% 从外面完整包住两个管口（结构见 jointOver 注释）
    elbow.add(blob(elbowJ * 1.025, elbowJ * 1.025, elbowJ * 1.025, skinMat, 40));
    elbow.add(limb(armForeProfile, skinMat));
    // 手：挂在手腕上（腕在 −foreArm），手掌再往下
    const hand = makeHand(d, side, skinMat);
    hand.position.y = -d.foreArm;
    elbow.add(hand);
    g.add(elbow);
    upperInner.add(g);
  }

  /* —— 腿：髋 → 膝两段，同样走曲线 —— */
  const legL = new THREE.Group();
  const legR = new THREE.Group();
  const kneeL = new THREE.Group();
  const kneeR = new THREE.Group();
  const shinTube = d.shin - d.footH * 0.30;
  const ankleR = d.shinR2 * 0.90;
  const thighProfile = [
    [0.020, d.thighR1 * 1.01],
    [-0.12 * d.thigh, d.thighR1 * 1.04],
    [-0.40 * d.thigh, d.thighR1 * 0.90],
    [-0.72 * d.thigh, d.thighR2 * 1.10],
    [-0.88 * d.thigh, kneeJ * 1.02],
    [-(d.thigh + jointOver(kneeJ)), kneeJ],   // 恒定半径直段越过膝关节中心
  ];
  const shinProfile = [
    [jointOver(kneeJ), kneeJ],                // 从关节中心上方以同一半径接管
    [-0.10 * d.shin, d.shinR1 * 1.12],     // 小腿肚（腓肠肌）：长裤裤脚以下全靠这段读出"这是条腿"
    [-0.30 * d.shin, d.shinR1 * 0.90],
    [-0.56 * d.shin, d.shinR2 * 1.30],
    [-0.82 * d.shin, d.shinR2 * 1.02],
    [-shinTube, ankleR],                   // 脚踝收窄
  ];
  for (const [g, knee, side] of [[legL, kneeL, -1], [legR, kneeR, 1]]) {
    g.position.set(side * d.hipPivotX, d.hipY, 0);
    g.add(limb(thighProfile, skinMat));
    knee.position.y = -d.thigh;
    // 球加大 2.5% 完整包住两个管口（结构见 jointOver 注释）
    knee.add(blob(kneeJ * 1.025, kneeJ * 1.025, kneeJ * 1.025, skinMat, 40));
    knee.add(limb(shinProfile, skinMat));
    // 脚：踝下一只脚背，脚尖朝 +z。要整个塞进鞋里，别比鞋还宽
    const foot = blob(d.footW * 0.88, d.footH * 0.22, d.footLen * 0.42, skinMat, 18);
    foot.position.set(0, -d.shin + d.footH * 0.17, d.footLen * 0.18);
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

  /* —— 五官：全部贴着头颅表面摆 ——
     ⚠️ 脸的 z 坐标不能手写。头是 headShape 绕 Y 转出来的曲面，改一次脸型
     （把下巴收窄）之后，手写的 z 要么浮在脸前面（一个肉球贴在鼻子上、腮红
     像一张贴纸），要么整个埋进头里（只剩一个白点）。这里按"高度 y + 横向 x"
     现算表面 z，每个零件再沿法线往外推一点点。 */
  const surfZ = (y, x) => {
    const pts = [...d.headShape].sort((a, b) => a[1] - b[1]);   // 按高度升序
    let r = pts[0][0];
    for (let i = 1; i < pts.length; i += 1) {
      if (y <= pts[i][1]) {
        const t = (y - pts[i - 1][1]) / (pts[i][1] - pts[i - 1][1] || 1);
        r = pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * Math.min(1, Math.max(0, t));
        break;
      }
      r = pts[i][0];
    }
    const rz = r * d.headSZ;
    const k = 1 - Math.min(1, (x / r) ** 2);
    return rz * Math.sqrt(Math.max(0, k));
  };
  const faceAt = (yR, xR) => surfZ(yR * R, xR * R);

  const eyeWhiteMat = new THREE.MeshStandardMaterial({ color: '#fffdfa', roughness: 0.30 });
  const irisMat = mat('#54403f', { roughness: 0.38 });
  const pupilMat = mat('#2a1e22', { roughness: 0.30 });
  const shineMat = new THREE.MeshBasicMaterial({ color: '#ffffff' });
  const lashMat = mat('#4a3a40', { roughness: 0.55 });
  const browMat = mat('#5a4650', { roughness: 0.6 });
  for (const side of [-1, 1]) {
    const ex = side * 0.40 * R;
    const ey = -0.015 * R;
    const ez = faceAt(-0.015, side * 0.40);

    /* 眼睛（2026-10-25 重做）：旧版 0.205R 的大白饼几乎被 0.122R 的虹膜盖满，
       再压一根 0.016R 的黑胶囊当眼皮——正面就是两颗黑玻璃珠。
       现在眼睛缩一号、虹膜坐在下睑上（y 低于眼白中心）左右各留一线眼白，
       瞳孔和高光分层，上睑只留一条细睫毛线，才读得出"在看人"。 */
    const white = blob(0.170 * R, 0.112 * R, 0.038 * R, eyeWhiteMat, 20);
    white.position.set(ex, ey, ez + 0.014 * R);
    head.add(white);

    const iris = blob(0.082 * R, 0.082 * R, 0.020 * R, irisMat, 18);
    iris.position.set(ex, ey - 0.008 * R, ez + 0.042 * R);
    head.add(iris);

    const pupil = blob(0.036 * R, 0.036 * R, 0.010 * R, pupilMat, 12);
    pupil.position.set(ex, ey - 0.008 * R, ez + 0.054 * R);
    head.add(pupil);

    const shine = blob(0.026 * R, 0.026 * R, 0.008 * R, shineMat, 10);
    shine.position.set(ex + side * 0.026 * R, ey + 0.030 * R, ez + 0.062 * R);
    head.add(shine);

    // 上睫毛：一条细弧贴着眼白上缘（替代旧版那根又粗又低的黑眼皮）
    const lash = new THREE.Mesh(new THREE.CapsuleGeometry(0.013 * R, 0.26 * R, 4, 10), lashMat);
    lash.position.set(ex, ey + 0.088 * R, ez + 0.046 * R);
    lash.rotation.set(0.10, 0, Math.PI / 2 + side * 0.06);
    lash.scale.z = 0.55;
    head.add(lash);

    // 眉：从发际线边(0.318R)拉回到眼睛正上方(0.155R)，眉眼距离近了表情才挂在脸上
    const brow = new THREE.Mesh(new THREE.CapsuleGeometry(0.015 * R, 0.24 * R, 4, 10), browMat);
    brow.position.set(side * 0.40 * R, 0.155 * R, faceAt(0.155, side * 0.40) + 0.014 * R);
    brow.rotation.set(0.12, side * 0.20, Math.PI / 2 - side * 0.10);
    brow.scale.z = 0.6;
    head.add(brow);

    /* 腮红：一张带径向渐变的方片。以前是一个半透明椭球，边缘是一圈硬边，
       看着像脸上贴了一张粉色圆贴纸。 */
    const blush = new THREE.Mesh(new THREE.PlaneGeometry(0.44 * R, 0.27 * R), blushMat);
    const bz = faceAt(-0.30, side * 0.50);
    blush.position.set(side * 0.50 * R, -0.30 * R, bz + 0.010 * R);
    blush.rotation.y = side * 0.52;
    head.add(blush);
  }
  /* 耳朵：这个尺寸下只有 4~5 个像素，但少了它脸就是一颗蛋。
     ⚠️ 耳窝（pit）必须整个缩进耳廓里：以前 pit 放在 0.995R、比头皮还凸出
     0.08R，侧影上就是一个深色蘑菇凸起。现在 ear/pit 都收到 0.90R 一带，
     只留耳廓一点点弧度露出头皮。 */
  for (const side of [-1, 1]) {
    const ear = blob(0.075 * R, 0.165 * R, 0.105 * R, skinMat, 14);
    ear.position.set(side * 0.895 * R, -0.045 * R, -0.035 * R);
    ear.rotation.z = side * 0.12;
    head.add(ear);
    const pit = blob(0.032 * R, 0.082 * R, 0.050 * R, mat(shade(SKIN, 0.945), { roughness: 0.86 }), 12);
    pit.position.set(side * 0.90 * R, -0.050 * R, 0.005 * R);
    head.add(pit);
  }

  /* 鼻子：从眉心顺到鼻尖的一条脊 + 一个圆润、明显前凸的鼻头。
     旧版只有一个几乎贴合脸面的小球（前凸仅 ~0.01），侧影看不出鼻子。
     现在鼻头明显探出脸面、鼻梁用一条细脊连到眉心：正面看是鼻梁竖线，
     侧面看是清楚的鼻型，鼻孔/鼻翼这种尺度留给更细的迭代。 */
  const noseMat = mat(shade(SKIN, 0.95), { roughness: 0.82 });
  const tipY = -0.40 * R;                              // 鼻尖高度
  const nz = faceAt(-0.40, 0);
  // 鼻头：小椭球，z 方向拉长 + 中心前移，明显探出脸面
  const noseTip = blob(0.050 * R, 0.060 * R, 0.110 * R, noseMat, 18);
  noseTip.position.set(0, tipY, nz + 0.055 * R);
  head.add(noseTip);
  // 鼻梁：从眉心到鼻头的一条细脊（沿 Y 站立、横向很窄、轻微前凸）
  const bridge = new THREE.Mesh(new THREE.CapsuleGeometry(0.024 * R, 0.26 * R, 4, 10), noseMat);
  bridge.position.set(0, -0.30 * R, faceAt(-0.30, 0) + 0.020 * R);
  head.add(bridge);

  /* 嘴：上下唇合成一条自然的嘴缝，而不是两片分离的粉色贴纸。
     上唇薄、下唇略厚，二者几乎相接；中间压一道细的深色嘴缝线。 */
  const lipTopMat = mat('#bd6b74', { roughness: 0.46 });
  const lipLowMat = mat('#c8767f', { roughness: 0.44 });
  const mouthY = -0.62 * R;
  const mz = faceAt(-0.62, 0);
  const lipUp = blob(0.132 * R, 0.022 * R, 0.034 * R, lipTopMat, 16);
  lipUp.position.set(0, mouthY + 0.016 * R, mz + 0.006 * R);
  head.add(lipUp);
  const lipLow = blob(0.140 * R, 0.032 * R, 0.038 * R, lipLowMat, 16);
  lipLow.position.set(0, mouthY - 0.012 * R, mz + 0.006 * R);
  head.add(lipLow);
  // 嘴缝：一条细的深色弧线压在上下唇之间
  const seam = new THREE.Mesh(new THREE.CapsuleGeometry(0.009 * R, 0.20 * R, 4, 10), mat('#8a4a52', { roughness: 0.5 }));
  seam.position.set(0, mouthY, mz + 0.014 * R);
  seam.rotation.set(0, 0, Math.PI / 2);
  head.add(seam);

  /* —— 头发：球面片按发型显隐 ——
     ⚠️ 不能只按 R（横向半径）缩放：头是竖长的蛋形，顶点比 R 高出近四分之一，
     只用 R 缩放的球壳盖到一半就没了，正上方会秃一块。横向按 R、纵向按头高 H
     分别缩放，发壳才真的贴着颅骨。 */
  const H = Math.max(...d.headShape.map((p) => Math.abs(p[1])));
  const HW = R * 1.085;
  const HH = H * 1.075;
  const hairParts = {};
  /* grow 让每片发壳半径不同：同半径的三片会完全共面，正面上方那一条会闪锯齿。
     phi 是绕 Y 的角度，正前方 = 0.5π。back 给到 0.70π..2.30π，两侧鬓角才不漏头皮。

     ⚠️ 发片的下沿必须是"波浪"的。球面片在固定 theta 处收边，那一圈是正圆，
     正面看就是一条笔直的水平线——也就是"戴了顶锅盖"。以前靠再叠一片更外面的
     发壳来打散，结果那片自己的上沿又成了另一条硬边（男生的刘海看着像被剃刀
     刮平）。现在改成建完几何体之后按 phi 做正弦偏移，把靠近下沿的顶点往下拉：
     边缘自己就成了参差的发梢，一片就够，不用再叠。 */
  const addHair = (key, grow, phiStart, phiLen, thetaStart, thetaLen, segW = 40, segH = 24, wave = 0, taper = 0, fit = 0) => {
    const geo = new THREE.SphereGeometry(1, segW, segH, phiStart, phiLen, thetaStart, thetaLen);
    if (fit || wave || taper) {
      const pos = geo.attributes.position;
      for (let i = 0; i < pos.count; i += 1) {
        let x = pos.getX(i);
        const y = pos.getY(i);
        let z = pos.getZ(i);
        const th = Math.acos(Math.min(1, Math.max(-1, y)));
        const t = (th - thetaStart) / thetaLen;   // 0 = 发顶，1 = 下沿
        if (fit) {
          /* 蛋形贴合：把球壳的圆截面半径换成头颅曲线在同高度的半径。
             头是竖长蛋形、最宽点在额骨——球壳在 θ 28°..54° 一带比头颅瘦，
             会被颅骨顶穿，露出一条头皮（"秃了一圈发箍"）。按头颅曲线重算
             横向半径后，发壳永远贴着任意头型，以后改 headShape 不用再调发壳。 */
          const rEgg0 = surfZ(HH * grow * y, 0) * fit;
          // 颅顶以上 surfZ 会钳在发顶半径上，直接用会顶出一个小凸起；
          // 按 √(1-u²) 收回 0（球面轮廓），发顶收成圆头而不是锥尖
          const topY = H * d.headSZ;
          const yHead = HH * grow * y;
          let rEgg = rEgg0;
          if (yHead > topY) {
            const u = (yHead - topY) / (HH * grow - topY);
            rEgg *= Math.sqrt(Math.max(0, 1 - u * u));
          }
          const cur = Math.hypot(x, z);
          if (cur > 1e-4) {
            const s = rEgg / (HW * grow * cur);
            x *= s;
            z *= s;
            pos.setX(i, x);
            pos.setZ(i, z);
          }
        }
        /* taper：上沿半径渐变收到 1.002（贴住 cap 那层的半径）。
           两片发壳半径不同时，交界处是一圈径向台阶，正对光源就是一条横贯
           头顶的亮线（女生的刘海缝）。收进去之后台阶归零，缝就没了。 */
        if (taper && t < taper) {
          const f = t / taper;
          const s = (1.002 / grow) + (1 - 1.002 / grow) * (f * f * (3 - 2 * f));
          pos.setX(i, x * s);
          pos.setZ(i, z * s);
        }
        if (wave && t > 0.05) {
          const k = Math.pow(Math.min(1, t), 2.2);
          // 两条不同频率的波叠起来，才不像一条规律的荷叶边；
          // 低频占大头，高频只做一点点毛边——全给高频会变成一排毛刺。
          const phi = Math.atan2(z, x);
          const lobe = 0.58 + 0.30 * Math.sin(phi * 3 + 0.6) + 0.12 * Math.sin(phi * 9 - 1.1);
          const pull = k * wave * lobe;
          pos.setY(i, y - pull);
          const s = 1 + pull * 0.30;               // 顺带往外撑一点，发梢才有厚度
          pos.setX(i, pos.getX(i) * s);
          pos.setZ(i, pos.getZ(i) * s);
        }
      }
      geo.computeVertexNormals();
    }
    const m = new THREE.Mesh(geo, hairMat);
    m.scale.set(HW * grow, HH * grow, HW * grow);
    m.visible = false;
    head.add(m);
    hairParts[key] = m;
    return m;
  };
  /* cap：蛋形贴合（fit 1.045 = 发壳离头皮 4.5%），θ 一直压到 0.40π（72°，
     眉弓上方）——最宽点移到额骨之后，旧球壳在头顶会秃一圈，egg-fit 后
     发顶永远贴着颅骨；grow 0.963 让壳顶只高出颅顶 ~0.003，收口不显凸；
     下沿藏在 bangs/back 外壳之下，露不出硬边。 */
  addHair('cap', 0.963, 0, Math.PI * 2, 0, Math.PI * 0.40, 48, 26, 0, 0, 1.045);
  // 长发（到后颈）与短发（到耳下）各一片，靠 visible 切换
  addHair('back', 1.022, Math.PI * 0.70, Math.PI * 1.60, Math.PI * 0.18, Math.PI * 0.74, 48, 28, 0.10);
  addHair('backS', 1.022, Math.PI * 0.70, Math.PI * 1.60, Math.PI * 0.18, Math.PI * 0.40, 48, 20, 0.09);
  /* 刘海：比内层再往外 4.5%，压出一点厚度和一道投在额头上的阴影。
     下沿停在眉毛上方（θ≈72°），再加波浪刚好垂到眉梢。
     segH 给足一点：下沿的波浪是靠竖向分段表现弧度的，段少就是锯齿。 */
  addHair('bangs', 1.045, Math.PI * 0.22, Math.PI * 0.56, Math.PI * 0.26, Math.PI * 0.15, 52, 22, 0.115, 0.45);
  /* 鬓发用胶囊而不是球面片：球面片在脸上会切出方角。
     短的到颧骨（短发用），长的到下颌（长发用）——两套都建好，靠 visible 切。 */
  for (const side of [-1, 1]) {
    /* 鬓发顶端必须藏在 backS（发壳下沿 ≈0.41R）之下，否则会在太阳穴
       钻出一颗暗色凸起。整体下移 + 内收后，上沿 0.28R 安全藏住，
       下沿 -0.32R 仍然盖到耳→下颌。 */
    const short = new THREE.Mesh(new THREE.CapsuleGeometry(0.14 * R, 0.60 * R, 6, 14), hairMat);
    short.position.set(side * 0.86 * R, -0.02 * R, 0.30 * R);
    short.rotation.z = side * 0.05;
    short.visible = false;
    head.add(short);
    hairParts[side < 0 ? 'sideL' : 'sideR'] = short;

    const long = new THREE.Mesh(new THREE.CapsuleGeometry(0.155 * R, 1.26 * R, 6, 14), hairMat);
    long.position.set(side * 0.90 * R, -0.14 * R, 0.32 * R);
    long.rotation.z = side * 0.05;
    long.visible = false;
    head.add(long);
    hairParts[side < 0 ? 'longL' : 'longR'] = long;
  }
  /* 双马尾：发根挪到耳上方偏后，整条用 limb 收成尖。
     以前是"一根胶囊 + 顶上顶个球"，末端是个圆头，像挂了两串香肠。 */
  for (const side of [-1, 1]) {
    const g = new THREE.Group();
    // 发根要露在头的轮廓外面，不然两条尾巴看着是"浮在脑后"的两只角
    g.position.set(side * 1.00 * R, 0.26 * R, -0.52 * R);
    g.rotation.set(0.26, 0, side * 0.34);
    g.visible = false;
    const tie = new THREE.Mesh(new THREE.TorusGeometry(0.135 * R, 0.040 * R, 8, 16), hairMat);
    tie.rotation.x = Math.PI / 2;
    tie.position.y = -0.04 * R;
    g.add(tie);
    g.add(limb([
      [0.02 * R, 0.09 * R],
      [-0.20 * R, 0.20 * R],
      [-0.72 * R, 0.235 * R],
      [-1.24 * R, 0.185 * R],
      [-1.66 * R, 0.105 * R],
      [-1.86 * R, 0.020 * R],
    ], hairMat, 20));
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

  /* 袖：一根带肩峰的曲线管，顶端收成小圆头缩进斜方肌下面。
     以前是"圆台 + 一个压扁的半球盖"：半球的赤道和圆台口几乎重合，
     交界处一道硬折，肩上就像顶了个球（左右两个肩膀都能看见那颗球）。
     现在整条一次成型，肩峰只是曲线里的一处鼓包，没有交界线。 */
  const sleeve = (id, side, len, rEnd, color) => {
    const g = side === 'l' ? armL : armR;
    const R0 = d.upR1;
    /* ⚠️ 袖子的半径在肩头那段必须一直大于手臂本身。
       手臂管的顶端（+0.02R，半径 1.01R0）是齐口切开的，只要袖子在同一个
       高度比它细一点点，那圈肉色就会从袖口上沿顶出来——肩上一块米色三角，
       看着像袖子破了。 */
    /* 顶点的半径写 0：这才是把袖子"封口"。留 0.05R0 的话顶上是一个
       小洞，从上往下看能看见袖子内壁，肩上就有一道深色小缺口。 */
    /* ⚠️ 截面的 y 必须一路递减（袖子总长可变）：以前肩峰写死 -0.075、
       下一控制点写 -0.22*len，短袖（len≈0.19）时 -0.05 比 -0.075 还高，
       曲线在肩头折返一次，轮廓上就挑出两片三角尖。现在全部用绝对高度，
       峰 → 缓收 → 袖口，任何 len 都单调。 */
    own(id, g, limb([
      [0.058, 0.0],
      [0.048, R0 * 0.56],
      [0.018, R0 * 1.10],
      [-0.060, R0 * 1.24],        // 肩峰
      [-0.140, R0 * 1.16],
      [-len, rEnd],
    ], color, 26));
  };
  const foreSleeve = (id, side, color) => own(id, side === 'l' ? elbowL : elbowR, limb([
    [0.000, d.foreR1 * 1.40],
    [-0.34 * d.foreArm, d.foreR1 * 1.34],
    [-0.72 * d.foreArm, d.foreR2 * 1.30],
    [-(d.foreArm + 0.02), d.foreR2 * 1.26],
  ], color, 24));

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
      // ⚠️ 截面必须全程比躯干大 ~1cm（z 已同样压到 torsoZ，只比 x 半径），
      // 哪怕一段比躯干瘦，皮肤就会从裤子里透出一条肉色横带（1.20 处踩过坑）。
      // 收口要到 hipY-0.155：躯干皮肤在 hipY-0.135 才闭合，收早了裆部露一坨肉。
      bodyOf(g.id, latheMesh([
        [d.waistR + 0.012, d.waistY + 0.055],
        [d.hipR + 0.006, d.hipY + 0.000],
        [d.hipR + 0.000, d.hipY - 0.045],
        [d.hipR - 0.020, d.hipY - 0.085],
        [d.hipR - 0.086, d.hipY - 0.115],
        [d.hipR - 0.136, d.hipY - 0.135],
        [0.030, d.hipY - 0.155],
      ], m, d.torsoZ));
      for (const [g2, knee, side] of [[legL, kneeL, 'l'], [legR, kneeR, 'r']]) {
        if (isPants) {
          // 长裤分两段：大腿管 + 小腿管，跟着膝关节折
          const plen = d.thigh + 0.02;
          // 裤管在膝盖处的公称半径：上下两段和中间的补缝球都用它（同 skin 的 elbowJ 一个道理）
          const pantJ = Math.max(d.thighR2 + 0.012, d.shinR1 + 0.024);
          // 左右裤管半径错开 1.5mm：两条管在裆下相切处几乎共面，深度缓冲
          // 分不出谁前谁后，整条裆缝闪成一排虚线。错开之后相交处是一条
          // 稳定的曲线，缝就实了（1.5mm 肉眼分不出粗细差）。
          const eps = side === 'l' ? 0 : 0.0015;
          // 裤管也走样条：圆台是一根锥子，套在腿上就是一圈直筒，
          // 走起路来像两根管子。带一点大腿撑、膝盖收的曲线才有布的意思。
          own(g.id, g2, limb([
            [0.010, d.thighR1 + 0.012 + eps],
            [-0.28 * plen, d.thighR1 + 0.004 + eps],
            [-0.70 * plen, d.thighR2 + 0.016 + eps],
            [-plen, pantJ + eps],
          ], m, 24).translateY(0));
          // 小腿这段要往上多包一截，盖过膝关节：只到下口的话，
          // 一跪下（膝盖折 1.5 弧度）裤腿就裂开一道缝，露出膝盖上的肉。
          /* ⚠️ 但这截不能靠"把圆台往上移"来做：膝盖折 80° 的时候，
             圆台的上盖会横向顶出去，正面看是一块方板（像护膝）。
             改用一颗布料球盖住关节——球在任何角度都是圆的，
             两个管口都缩回球里面，怎么折都不会露出上盖。
             球只比裤管粗 2%：以前给到 14%，站着不动时膝盖上就像绑了护膝。 */
          const shinLen = shinTube + 0.03;
          own(g.id, knee, limb([
            [0.020, pantJ + eps],
            [-0.22 * shinLen, d.shinR1 + 0.018 + eps],
            [-0.58 * shinLen, d.shinR2 + 0.026 + eps],
            [-shinLen, d.shinR2 + 0.008 + eps],
          ], m, 24));
          /* 补缝球只比管口大 0.4% 时，样条在控制点附近外凸的半径会追平球面，
             一圈针脚似的锯齿就闪出来了（管口球面互相 z-fight）。留 2% 间隙，
             球完整包住两段管口，膝盖圆润又没有锯齿。 */
          own(g.id, knee, blob((pantJ + eps) * 1.02, (pantJ + eps) * 1.02, (pantJ + eps) * 1.02, m, 26));
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

  /* 鞋：一只鞋要能看出"鞋"来——平鞋底、圆鞋头、后跟高一块。
     以前是两只压扁的椭球叠在一起（鞋身 + 鞋底），看着像两只白煮蛋，
     而且比裤脚还窄，小腿就像一根柱子插进一颗蛋里。 */
  for (const g of GARMENTS.shoes) {
    const m = mat(g.color, { roughness: 0.68 });
    const dark = mat(shade(g.color, 0.76), { roughness: 0.78 });
    for (const knee of [kneeL, kneeR]) {
      const W = d.footW;
      const L = d.footLen;
      const H = d.footH;
      const y0 = -d.shin;                        // 脚踝
      /* 鞋底：圆柱压成椭圆板。底面必须是平的——椭球的底面是圆的，
         人就成了踮着脚尖站在地上，接地的位置也会算错。 */
      const sole = new THREE.Mesh(new THREE.CylinderGeometry(1, 1, 1, 26), dark);
      sole.scale.set(W * 1.42, H * 0.20, L * 0.64);
      sole.position.set(0, y0 + H * 0.10, L * 0.22);
      own(g.id, knee, sole);
      // 鞋头：前低后高的椭球，脚尖微微下压
      const upper = blob(W * 1.34, H * 0.34, L * 0.62, m, 22);
      upper.position.set(0, y0 + H * 0.26, L * 0.20);
      upper.rotation.x = 0.09;
      own(g.id, knee, upper);
      // 后跟：比鞋头高一块，侧面才有鞋的剪影
      const heel = blob(W * 1.28, H * 0.40, L * 0.26, m, 20);
      heel.position.set(0, y0 + H * 0.30, -L * 0.34);
      own(g.id, knee, heel);
    }
  }

  /* 投影：整套几何一次性打开自阴影。之前全场景没有一颗投影，全身亮度均匀——
     这正是画面"像塑料模型"的头号原因：下巴不压脖子、手臂不压躯干、头发不压额头，
     再精细的形体也立不住。透明材质（腮红）不投，否则脸上会糊一片灰。 */
  root.traverse((o) => {
    if (!o.isMesh) return;
    o.castShadow = !o.material.transparent;
    o.receiveShadow = true;
  });

  return {
    root, upper, upperInner, head, dims: d,
    armL, armR, elbowL, elbowR, legL, legR, kneeL, kneeR,
    hairParts, hairMat, garments, props: { ring },
  };}

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
  /* 三种发型现在真的不一样了：
     短发 = 后脑收在耳下（backS）+ 鬓角到颧骨 + 刘海斜一点（偏分）；
     齐刘海 = 后脑到后颈（back）+ 鬓角到下颌；
     双马尾 = 齐刘海的底子 + 两条收尖的尾巴。 */
  const crop = hairStyle === 'bob';
  hp.cap.visible = hp.bangs.visible = true;
  hp.back.visible = !crop;
  hp.backS.visible = crop;
  hp.sideL.visible = hp.sideR.visible = crop || hairStyle === 'twin';
  hp.longL.visible = hp.longR.visible = hairStyle === 'bangs';
  hp.tailL.visible = hp.tailR.visible = hairStyle === 'twin';
  // 偏分：整片刘海绕 Z 斜一点。绕的是头的中心，所以它仍然贴在那层壳上。
  hp.bangs.rotation.z = crop ? 0.15 : 0;
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
    /* 自阴影：只给主光开一张投影图，用来做身上的接触阴影（下巴→脖子、
       手臂→躯干、头发→额头、大腿→裙内）。没有这层，再准的形体也是一片
       均匀亮，看着就是"塑料人"。PCFSoft 让边缘软一点，才有皮肤的意思。 */
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.VSMShadowMap;

    const sc = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 60);

    /* 灯光按「摄影棚三点光」配：标准材质的光衰减是物理的，强度要跟 toon 差一个量级。
       天光补冷、主光从右上前方、轮廓光从左后方把肩线勾出来——
       少了轮廓光，深色头发和背景会糊成一片。 */
    sc.add(new THREE.HemisphereLight(0xffffff, 0xe0cdd6, 1.55));
    const key = new THREE.DirectionalLight(0xfff4ee, 2.00);
    key.position.set(2.4, 4.2, 3.0);
    key.castShadow = true;
    key.shadow.mapSize.set(2048, 2048);
    /* 阴影相机是正交的，范围要正好罩住两个人的包围盒（±2.8 足够，
       再大就摊薄精度，脸上会出来一格一格的锯齿）。 */
    const sc2 = key.shadow.camera;
    sc2.left = -2.8; sc2.right = 2.8; sc2.top = 2.8; sc2.bottom = -2.8;
    sc2.near = 0.5; sc2.far = 14;
    // ⚠️ 改完 left/right/top/bottom 必须 updateProjectionMatrix：
    // 不然投影矩阵还是默认的 ±5 / far 500，同样 2048 张图摊在两倍面积上，
    // 阴影边缘一格一格的，还会在手臂上糊出一片一片的暗斑（像沾了脏东西）。
    sc2.updateProjectionMatrix();
    // 曲面上最容易出条纹（shadow acne）：靠 normalBias 沿法线抬一点采样点
    key.shadow.bias = -0.0009;
    key.shadow.normalBias = 0.085;
    /* VSM 才认 radius：PCFSoft 是固定核，边缘只有一两像素宽，
       在脸上、手臂上就是一条硬边，看着像脏。给一个大一点的模糊半径，
       接触阴影才像真的环境光遮蔽。 */
    key.shadow.radius = 3.5;
    key.shadow.blurSamples = 12;
    /* 半透明的影子：真实环境里有反弹光，被挡住的那块不会黑掉一大片。
       全黑的阴影会把"裤子自己压出来的那道褶"变成一条脏印子。
       （LightShadow.intensity 是 r157+ 的接口） */
    key.shadow.intensity = 0.55;
    sc.add(key);
    const fill = new THREE.DirectionalLight(0xffffff, 0.72);
    fill.position.set(-3.2, 1.8, 2.2);
    sc.add(fill);
    const rim = new THREE.DirectionalLight(0xffe7ef, 0.95);
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
