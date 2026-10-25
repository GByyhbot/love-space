/* 人体模型 · 男女分开的卡通人体
 *
 * 和造型间的区别：
 *   - 这是一个独立页面，只渲染静止的人体本身；没有衣服、没有姿势、没有动画；
 *   - 男女各一套身材表（BODY_M / BODY_F），分别搭，不共用一张表；
 *   - 参考 QQ 秀的画风（圆润、Q 版、讨喜），但保留男女身体特征：
 *     男方肩宽胸阔、臀窄；女方肩窄腰收、胯宽、有乳房曲线和更丰满的臀部。
 *
 * 躯干为什么不用 lathe：
 *   lathe 是"截面绕 Y 转一圈"，截面只能是圆（或统一压扁的椭圆），
 *   于是正面和背面剪影一模一样——胸和背分不出来，看着就是一根管子。
 *   这里改成 revolve()：每个高度的截面可以前后不等深、还能整体前移，
 *   胸往前顶、背压平、臀往后翘，正侧两面的剪影才分开。
 */
import * as THREE from './vendor/three.module.min.js';

const SKIN = '#f0c9ae';

/** 左右对称的一对起伏（乳房/胸肌/臀瓣/腹肌列/V 线都是成对的）。
 *  ⚠️ 必须在身材表之前定义：表里的 feats 是模块加载时就要算出来的常量，
 *  放在表后面会撞 TDZ（Cannot access 'pair' before initialization）。
 *  phi 是绕身体的角度：0 = 正前(+z)，π = 正后(−z)，π/2 = 右侧。
 *  phi0→phi1 随高度插值，能画出斜线（马甲线、人鱼线）。 */
const pair = (phi0, phi1, sigma, y0, y1, amp, k, skew) => ([
  { phi0, phi1, sigma, y0, y1, amp, k, skew },
  { phi0: -phi0, phi1: -phi1, sigma, y0, y1, amp, k, skew },
]);

/* ══════════════════════════ 身材表：男女各一套 ══════════════════════════
   torso 每项是 [y, halfW, frontK, backK]：
     y      高度
     halfW  该高度躯干半宽（左右）
     frontK 胸腹一侧（前）的深度 = halfW * frontK
     backK  背臀一侧（后）的深度 = halfW * backK
   前深 > 后深 = 胸往前；后深 > 前深 = 臀往后。 */

// 男方：肩宽、胸阔、腰略收、胯窄、臀扁平；头大颈短（QQ 秀比例，约 5 头身）
const BODY_M = {
  gender: 'm',
  h: 2.560,
  headR: 0.152, headSZ: 1.02,
  /* headScale：整颗头（颅骨+五官+头发）统一放大倍数。
     1.30 是 QQ 秀的 Q 版（5.4 头身）；用户要求"尽量往真实方向做"，
     0.95 ≈ 7 头身（真实人体 7~7.5，James 假人实测 7.7），
     头宽/肩宽 ≈ 0.52（真实比例），配合更细的解剖起伏整体往写实走。 */
  headScale: 0.95,
  /* 头颅截面沿用造型间 v85：最宽点在额骨(0.146@0.070)，下颌从颧骨开始收，
     颏部收到 0.080 —— 旧版最宽点在眼线，正面是一颗上窄下宽的梨。 */
  headShape: [[0.004, -0.172], [0.044, -0.162], [0.080, -0.130], [0.112, -0.065],
    [0.134, 0.000], [0.146, 0.070], [0.140, 0.125], [0.115, 0.168], [0.060, 0.192], [0.004, 0.196]],
  hairColor: '#3a3038',
  hairBackLen: Math.PI * 0.32,   // 短发：后脑一片到耳上（长发片会读成女生）
  /* 脖子短而略粗：大头配长脖是"外星人"，QQ 秀的脖子几乎只露一小截。 */
  neckR: 0.085, neckTopR: 0.062, neckBot: 2.040, neckTop: 2.175,   // 头缩到真实头身比后脖子也要相应收细
  shoulderY: 2.000, waistY: 1.575, hipY: 1.360, kneeY: 0.755, ankleY: 0.095,   // 髋点 1.36 = 黄金比腿长
  shoulderR: 0.152, chestR: 0.208, waistR: 0.156, hipR: 0.226,
  /* 男体 = 倒三角：肩最宽 → 胸 → 腰收 → 胯最窄。
     ⚠️ 裸模不能沿用造型间穿衣服时的数值（那时 hipR 0.226 > chestR，
     裤子把胯撑宽了看不出）；裸着的男人肩必须明显宽于胯，不然读成女的。
     胸的前凸和臀的后翘直接做进 frontK/backK 曲线（1.87 胸峰 / 1.29 臀峰），
     不靠外面贴球——贴球一定有一圈"贴纸边"。鼓包要"圆"：
     峰值和两侧邻点的高差别拉开太大，样条才鼓成馒头而不是尖包。 */
  /* 基础截面只给"躯干本身的厚薄"，胸/腹/臀的体积交给下面的 feats：
     曲线只留一点起伏，鼓包全由沿法线的位移出，才鼓得圆而不鼓成桶。 */
  /* 黄金比例：以肚脐分界，下半身 : 身高 ≈ 0.618。但头是 QQ 秀大头（占身高 19%），
     躯干放不下完整的黄金躯干，所以按"去头后的身体"套：
     腿(髋点→脚底) / 身体(下巴→脚底) = 0.618 → 男髋点抬到 1.36（原 1.29）。
     腰线、胯底、所有下半身 feat 跟着一起抬，胸以上不动。 */
  torso: [
    [1.235, 0.080, 0.80, 0.78],
    [1.290, 0.190, 0.70, 0.74],   // 臀底对齐大腿背线（同女体）
    [1.360, 0.215, 0.72, 0.84],   // 胯最宽——⚠️ 男胯必须窄于胸(0.24)，宽过胸就读成女体
    [1.450, 0.205, 0.74, 0.84],
    [1.520, 0.192, 0.78, 0.76],
    [1.575, 0.185, 0.80, 0.72],   // 腰（男腰只微收：腰/胯 0.86，掐成 0.74 就是沙漏女腰）
    [1.660, 0.190, 0.82, 0.72],
    [1.780, 0.240, 0.88, 0.72],   // 胸最宽最厚：男体胸 > 胯（倒梯形）
    [1.870, 0.238, 0.90, 0.74],
    [1.940, 0.232, 0.86, 0.76],   // 上胸削薄——厚度顶到锁骨就是"胸太高"
    [2.000, 0.238, 0.78, 0.78],   // 肩线
    [2.030, 0.222, 0.80, 0.76],   // 斜方肌缓收——肩坡要平滑，别出"肩章"台阶
    [2.065, 0.172, 0.76, 0.72],
    [2.090, 0.128, 0.74, 0.70],
    [2.105, 0.099, 0.68, 0.64],   // 颈根
  ],
  /* 男体解剖起伏：胸肌两瓣 + 胸骨沟 + 下缘褶；腹肌两列 + 白线沟 +
     三道横褶（六块）；人鱼线（V）从髋骨斜收到小腹；臀两瓣 + 臀沟。
     amp 单位是米（位移量），0.03 ≈ 3cm 级，Q 版身上正好。 */
  feats: [
    /* 胸肌：中心外移到 ±0.48、σ 0.62 让两瓣连成"一整块宽而厚的胸壁"——
       σ 0.42 那版是两座分开的尖包，中间还被深沟切开，读出来就是尖的。
       竖向拉到 1.76-1.98，整片胸廓都有厚度，不是胸前挂两个包。 */
    /* 胸肌定位：肩线 2.00、腰线 1.52，胸中点 1.76；最鼓处取 1.78（中点略上）。
       1.71-1.94 那版最鼓在 1.825 还是偏高，再下移到 1.66-1.90。
       同时把最宽/最厚的截面行也压到 1.78 一带（见 torso），两者要一起动。 */
    /* 胸肌定位：肩线 2.00、腰线 1.575，胸中点 1.76；最鼓处取 1.78。
       ⚠️ σ 0.62 那版两瓣连成整片，但鼓包环绕到躯干侧面，正面是一条
       "救生圈"横杠（头缩小后暴露无遗）——胸腔厚度交给基础截面 frontK
       平缓过渡，lobe 只做浅浅的定义（amp 0.014/σ 0.42），乳点负责朝向。 */
    /* 胸肌定位：肩线 2.00、腰线 1.575，胸中点 1.7875，但用户两轮都说偏高，
       峰取 1.73。⚠️ skew 方向别搞反：峰值在带内 t = 0.5^(1/skew)
       —— skew>1 是"峰下移"，skew<1（0.756）才是"峰上移到 40%"。
       这里取 skew 0.756 + 带 1.62-1.90 → 峰 1.732。 */
    ...pair(0.48, 0.48, 0.38, 1.62, 1.90, 0.020, 2.0, 0.756),
    { phi0: 0, phi1: 0, sigma: 0.11, y0: 1.64, y1: 1.88, amp: -0.013 },  // 胸骨沟：中线要可见
    { phi0: 0, phi1: 0, sigma: 0.95, y0: 1.598, y1: 1.622, amp: -0.009 },  // 胸肌下缘褶
    /* 锁骨：男浅一点（女体参考图里的锁骨是女性信号，男性有但不抢戏） */
    ...pair(0.15, 0.52, 0.10, 1.925, 1.965, 0.004),
    { phi0: 0, phi1: 0, sigma: 0.10, y0: 1.915, y1: 1.95, amp: -0.005 },  // 胸骨上窝
    ...pair(0.30, 0.30, 0.30, 1.46, 1.81, 0.016),                 // 腹肌两列
    { phi0: 0, phi1: 0, sigma: 0.14, y0: 1.46, y1: 1.81, amp: -0.013 },  // 腹白线
    { phi0: 0, phi1: 0, sigma: 1.10, y0: 1.585, y1: 1.608, amp: -0.010 },
    { phi0: 0, phi1: 0, sigma: 1.10, y0: 1.675, y1: 1.698, amp: -0.010 },
    { phi0: 0, phi1: 0, sigma: 1.10, y0: 1.755, y1: 1.778, amp: -0.010 },
    { phi0: 0, phi1: 0, sigma: 0.07, y0: 1.505, y1: 1.548, amp: -0.010 },  // 肚脐（小凹）
    ...pair(0.95, 0.95, 0.22, 1.53, 1.68, 0.008),                 // 腹外斜肌（腰侧两道）
    ...pair(0.72, 0.24, 0.20, 1.35, 1.57, -0.011),                // 人鱼线
    /* 背部（真实方向）：旧版背面是完全平的，只有脊柱沟一道。
       加背阔肌（从腋下斜向脊柱的两片）+ 肩胛骨，背面才有解剖层次。 */
    { phi0: Math.PI, phi1: Math.PI, sigma: 0.10, y0: 1.62, y1: 1.98, amp: -0.012 },  // 脊柱沟
    ...pair(Math.PI - 0.75, Math.PI - 0.45, 0.35, 1.60, 1.86, 0.010, 1.5),  // 背阔肌（斜的 V）
    ...pair(Math.PI - 0.62, Math.PI - 0.62, 0.30, 1.86, 1.98, 0.006, 1.8),  // 肩胛骨
    /* 臀：男性扁，但同样要圆顶不要尖顶——范围拉宽 + k 1.4 + σ 加大。 */
    ...pair(Math.PI - 0.55, Math.PI - 0.55, 0.80, 1.23, 1.53, 0.030, 1.4),
    { phi0: Math.PI, phi1: Math.PI, sigma: 0.32, y0: 1.27, y1: 1.45, amp: -0.009, k: 1.4 },
  ],
  /* 乳点：胸肌下外象限的小凸点（参考 T-pose 男体图明确有）——
     没有它，一片鼓起的胸读不出朝向和性别。位置由 surfacePoint 贴到曲面上。 */
  nipple: { y: 1.720, phi: 0.55, r: 0.013 },   // 跟着胸肌峰下移到 1.72（原来 1.79 偏高）
  /* 三角肌：男大（肩头方阔） */
  delt: [1.06, 0.62, 1.04],
  deltDrop: 0,
  armPivotX: 0.185, armTilt: 0.19,   // 肩加宽后臂根外移（James 校准：肩 +8%）
  upperArm: 0.372, foreArm: 0.382, handLen: 0.180,
  upR1: 0.084, upR2: 0.062, foreR1: 0.062, foreR2: 0.050,
  /* 腿要"分得开"：旧版髋支点 0.080 < 大腿半径 0.100，两腿内缘跨过中线互相重叠，
     正面看就是并成一条。髋支点 0.110 后内缘 +0.006，两腿之间留出了缝。 */
  hipPivotX: 0.110, thigh: 0.605, shin: 0.660,   // 腿加长：髋点抬到 1.36 后腿要接得到地(1.265)
  thighR1: 0.104, thighR2: 0.086, shinR1: 0.082, shinR2: 0.050,
  footLen: 0.235, footH: 0.100, footW: 0.070,
};

// 女方：肩窄、腰更收、胯宽、乳房圆润、臀更翘；头大颈短（QQ 秀比例）
const BODY_F = {
  gender: 'f',
  h: 2.380,
  headR: 0.142, headSZ: 1.02,
  headScale: 0.95,   // 同男体：往真实方向，≈7 头身
  headShape: [[0.004, -0.158], [0.040, -0.149], [0.074, -0.120], [0.104, -0.058],
    [0.124, 0.002], [0.134, 0.065], [0.129, 0.118], [0.104, 0.158], [0.054, 0.180], [0.004, 0.184]],
  hairColor: '#6b4a3a',
  hairBackLen: Math.PI * 0.74,   // 长发：后脑一片到后颈
  /* 脖颈参考用户给的女体截图：长而细的脖颈是优雅感的核心，
     QQ 秀短脖那版是给大头配的，女体改回修长（男体维持短脖）。 */
  neckR: 0.074, neckTopR: 0.054, neckBot: 1.895, neckTop: 2.030,   // 0.165 太长像模特夸张版，收回到修长但不夸张
  shoulderY: 1.890, waistY: 1.500, hipY: 1.260, kneeY: 0.698, ankleY: 0.088,   // 髋点 1.26 = 黄金比腿长
  shoulderR: 0.126, chestR: 0.192, waistR: 0.136, hipR: 0.216,
  /* 女体 = 沙漏：肩窄 → 胸峰 → 腰最收 → 胯最宽（明显比肩宽）。
     乳房的体积主体做进 frontK 曲线（1.78 处 frontK 1.06 的圆鼓包），
     侧影是自然的胸线；球只负责把鼓包分成左右两瓣 + 中间一道沟。 */
  /* 基础截面同样只管厚薄：乳房和臀的体积在 feats 里沿法线鼓出来，
     鼓成两瓣球而不是"胸前多一块"。 */
  /* 黄金比例（同男体）：腿 / 去头后的身体 = 0.618 → 女髋点抬到 1.26（原 1.215）。
     腰线、胯底、下半身 feat 同步上移，胸以上不动。 */
  torso: [
    [1.145, 0.060, 0.80, 0.78],   // 胯底不收到点：留小圆台藏在大腿之间（锥尖会在臀下拖出楔形尖）
    [1.195, 0.152, 0.68, 0.74],   // 臀底高度 ≈ 大腿背线：下缘流进大腿不露锥面
    [1.260, 0.208, 0.70, 0.84],   // 胯最宽；臀峰在 1.29 一带（体积交给 feats）
    [1.355, 0.196, 0.72, 0.86],
    [1.435, 0.160, 0.76, 0.80],
    [1.500, 0.124, 0.80, 0.72],   // 腰最收（沙漏的腰）；骶骨略凹 = 腰臀间 S 曲线
    [1.575, 0.132, 0.82, 0.70],
    [1.680, 0.158, 0.86, 0.72],   // 胸下沿
    [1.780, 0.172, 0.96, 0.74],   // 胸峰（乳房主体在 feats）
    [1.855, 0.172, 0.92, 0.74],
    [1.878, 0.162, 0.88, 0.72],   // 溜肩过渡（排序兜底会处理顺序）
    [1.900, 0.145, 0.82, 0.72],   // 肩线：加宽（原 0.126 太窄，肩/身高只有 0.175）
    [1.922, 0.128, 0.80, 0.70],   // 肩坡平滑（女肩要溜）
    [1.945, 0.112, 0.76, 0.64],
    [1.960, 0.092, 0.70, 0.58],
    [1.968, 0.082, 0.62, 0.54],
  ],
  /* 女体解剖起伏：乳房两瓣（大、圆、有乳沟）+ 马甲线（两条斜沟 + 白线沟 +
     两侧小腹的饱满）+ 臀两瓣（比男的更饱满）+ 臀沟。 */
  feats: [
    /* 乳房：整体下移——肩线 1.89 / 腰 1.50，胸中点 1.695，峰取 1.72。
       skew 1.35 → 峰在带内 60%（下垂感）：带 1.54-1.84 → 峰 1.72。 */
    ...pair(0.34, 0.34, 0.44, 1.54, 1.84, 0.048, 1.4, 1.35),      // 乳房（更饱满；峰下移 = 下垂感）
    { phi0: 0, phi1: 0, sigma: 0.08, y0: 1.60, y1: 1.84, amp: -0.024 },  // 乳沟（加深：浅了读成一块）
    /* 锁骨：从胸骨窝斜向外上到肩的两条浅脊——上半身最重要的女性信号。
       phi0→phi1 斜线 + 细 σ，浅浅一条；中间配胸骨上窝的浅凹。 */
    ...pair(0.16, 0.55, 0.10, 1.80, 1.85, 0.005),                 // 锁骨
    { phi0: 0, phi1: 0, sigma: 0.10, y0: 1.79, y1: 1.825, amp: -0.006 },  // 胸骨上窝
    ...pair(0.72, 0.24, 0.20, 1.305, 1.545, -0.012),              // 马甲线（斜的 V）
    { phi0: 0, phi1: 0, sigma: 0.13, y0: 1.395, y1: 1.655, amp: -0.010 },  // 白线沟
    ...pair(0.30, 0.30, 0.28, 1.355, 1.615, 0.014),               // 小腹两侧的饱满
    { phi0: 0, phi1: 0, sigma: 0.07, y0: 1.425, y1: 1.468, amp: -0.009 },  // 肚脐（小凹）
    { phi0: Math.PI, phi1: Math.PI, sigma: 0.10, y0: 1.55, y1: 1.82, amp: -0.007 },  // 脊柱沟（女浅）
    /* 臀：圆弧感来自"宽而缓"——σ 0.85、y 一直铺到大腿上段，
         amp 收到 0.032：深度沿高度缓慢起落才是圆，猛起猛落就是尖。 */
    ...pair(Math.PI - 0.55, Math.PI - 0.55, 0.85, 1.195, 1.565, 0.032, 1.4),   // 臀瓣
    { phi0: Math.PI, phi1: Math.PI, sigma: 0.32, y0: 1.225, y1: 1.465, amp: -0.008, k: 1.4 },
  ],
  nipple: { y: 1.700, phi: 0.42, r: 0.012 },
  /* 三角肌：男大（肩头方阔）；女小且低（溜肩，方肩是"衣架肩"） */
  delt: [0.94, 0.54, 0.92],
  deltDrop: 0.014,
  armPivotX: 0.180, armTilt: 0.19,   // 臂根外移：女肩/身高 0.175 → 0.20（原来太窄）
  upperArm: 0.352, foreArm: 0.364, handLen: 0.166,
  upR1: 0.072, upR2: 0.054, foreR1: 0.054, foreR2: 0.044,
  /* 同男体：髋支点外移到 0.104，两腿之间留缝不再并成一条。 */
  hipPivotX: 0.104, thigh: 0.562, shin: 0.610,   // 髋点抬到 1.26 后腿加长，仍接到 ankleY 0.088
  thighR1: 0.098, thighR2: 0.078, shinR1: 0.072, shinR2: 0.044,
  footLen: 0.215, footH: 0.090, footW: 0.062,
};

/* ══════════════════════════ 图元 ══════════════════════════ */

/** 旋转成型。
 *  ⚠️ 点的顺序决定法线朝向：LatheGeometry 按顺序绕行，y 递减时整个面会翻到背面，
 *  外面看不见、里面看得见。这里兜底排一次，调用方不用记。 */
function lathe(points, seg = 44) {
  const pts = points[points.length - 1][1] < points[0][1] ? [...points].reverse() : points;
  return new THREE.LatheGeometry(pts.map(([r, y]) => new THREE.Vector2(r, y)), seg);
}

/** 上粗下细的圆台（local -Y 是往下，所以第一个参数是肩/髋那头）。 */
function taper(rTop, rBottom, len, m, seg = 20) {
  return new THREE.Mesh(new THREE.CylinderGeometry(rTop, rBottom, len, seg), m);
}

/** 椭球。 */
function blob(rx, ry, rz, m, seg = 18) {
  const mesh = new THREE.Mesh(new THREE.SphereGeometry(1, seg, Math.max(10, seg - 4)), m);
  mesh.scale.set(rx, ry, rz);
  return mesh;
}

/** 一段肢体：半径随长度走样条曲线，连续过渡（圆台会"数得出节"）。 */
function limb(profile, m, seg = 30, samples = 20) {
  const curve = new THREE.SplineCurve(profile.map(([y, r]) => new THREE.Vector2(r, y)));
  const pts = curve.getPoints(samples).map((v) => [Math.max(0.001, v.x), v.y]);
  return new THREE.Mesh(lathe(pts, seg), m);
}

/** 广义旋转体：每一层的横截面是一个"前后不等深 + 可前移"的椭圆。
 *  ⚠️ lathe 只能出正圆截面 → 正面/背面剪影一模一样（胸背不分）。
 *  profile: [[y, halfW, frontK, backK], ...]（y 从下往上）
 *  在高度 y 处：宽 halfW，前深 = halfW*frontK，后深 = halfW*backK
 *  → 截面中心 z0=(前深-后深)/2，z 方向半径 bR=(前深+后深)/2
 *  于是 z 最大 = z0+bR = 前深，z 最小 = z0-bR = −后深。 */
/** 把身材表插成连续的截面序列。
 *  revolve() 用它建网格，胸/臀定位也用它取表面 z——两边共用同一条曲线，
 *  不会出现"按线性插值摆零件、按样条建曲面"对不上的情况。 */
function revolveRings(profile, samples = 30) {
  const pts = [...profile].sort((a, b) => a[0] - b[0]);
  /* 三个通道各建一条样条：宽度、前深系数、后深系数。
     按同一个参数 t 采样，三条曲线的第 i 个点互相对应。 */
  const cw = new THREE.SplineCurve(pts.map(([y, w]) => new THREE.Vector2(y, w)));
  const cf = new THREE.SplineCurve(pts.map(([y, , f]) => new THREE.Vector2(y, f)));
  const cb = new THREE.SplineCurve(pts.map(([y, , , b]) => new THREE.Vector2(y, b)));
  const ring = [];
  for (let i = 0; i <= samples; i += 1) {
    const t = i / samples;
    const pw = cw.getPoint(t);
    const w = Math.max(0.001, pw.y);
    const front = w * Math.max(0.05, cf.getPoint(t).y);
    const back = w * Math.max(0.05, cb.getPoint(t).y);
    ring.push({ y: pw.x, a: w, bR: (front + back) / 2, z0: (front - back) / 2 });
  }
  return ring;
}

/** 躯干表面（含 feats 位移）在给定 (高度 y, 方位角 phi) 处的坐标。
 *  乳点这类"钉在表面上的小件"用它定位，和曲面完全贴合不悬空。 */
function surfacePoint(d, y, phi) {
  const ring = revolveRings(d.torso, 30);
  const at = (k) => {
    if (y <= ring[0].y) return ring[0][k];
    for (let i = 1; i < ring.length; i += 1) {
      if (y <= ring[i].y) {
        const t = (y - ring[i - 1].y) / (ring[i].y - ring[i - 1].y || 1);
        return ring[i - 1][k] + (ring[i][k] - ring[i - 1][k]) * t;
      }
    }
    return ring[ring.length - 1][k];
  };
  const a = at('a');
  const bR = at('bR');
  const zc = at('z0');
  let nx = Math.sin(phi) / a;
  let nz = Math.cos(phi) / bR;
  const nl = Math.hypot(nx, nz) || 1;
  nx /= nl; nz /= nl;
  let dsp = 0;
  for (const f of d.feats) {
    const t = (y - f.y0) / (f.y1 - f.y0);
    if (t <= 0 || t >= 1) continue;
    const phic = f.phi0 + (f.phi1 - f.phi0) * t;
    dsp += f.amp * Math.exp(-(angularGap(phi, phic) ** 2) / (2 * f.sigma * f.sigma))
      * Math.pow(Math.sin(Math.PI * t), f.k || 2);
  }
  return { x: a * Math.sin(phi) + dsp * nx, y, z: zc + bR * Math.cos(phi) + dsp * nz };
}

/** 手：手掌 + 四指 + 拇指（拇指是"读成手"的关键那一根）。 */
function makeHand(d, side, m) {
  const H = d.handLen;
  const g = new THREE.Group();
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
  const fingers = new THREE.Group();
  fingers.rotation.x = -0.20;
  const fr = H * 0.086;
  const flen = H * 0.18;
  for (let i = 0; i < 4; i += 1) {
    const k = i - 1.5;
    const f = new THREE.Mesh(new THREE.CapsuleGeometry(fr, flen - Math.abs(k) * H * 0.022, 3, 10), m);
    f.position.set(k * H * 0.163, -H * 0.60 - flen * 0.42, 0);
    f.rotation.z = -k * 0.07;
    fingers.add(f);
  }
  g.add(fingers);
  const thumb = new THREE.Mesh(new THREE.CapsuleGeometry(H * 0.095, H * 0.17, 3, 10), m);
  thumb.position.set(-side * H * 0.245, -H * 0.50, H * 0.075);
  thumb.rotation.set(0.34, 0, -side * 0.98);
  g.add(thumb);
  return g;
}

/* ══════════════════════════ 躯干曲面 + 解剖起伏 ══════════════════════════
   光靠"每层一个椭圆"只能做出峰，做不出左右结构：乳房是两瓣、臀是两瓣中间
   一条沟、胸肌两瓣中间胸骨沟、腹肌是两列 + 白线沟 + 横向分段。
   所以在椭圆截面上再叠一层"沿外法线的位移"：
     - 横向（绕身体一圈）用高斯扩散，边缘自然渐隐，不会有一圈硬棱；
     - 竖向用 sin² 鼓包，两端斜率为 0，和躯干平滑相接；
     - amp < 0 就是"沟"（胸骨沟/臀沟/马甲线/白线）。
   位移沿的是椭圆外法线，不是简单加半径，胸才鼓成球而不是撑成桶。 */
function angularGap(phi, phic) {
  let dphi = Math.abs(phi - phic) % (Math.PI * 2);
  if (dphi > Math.PI) dphi = Math.PI * 2 - dphi;
  return dphi;
}

function revolveSkin(profile, feats, m, seg = 72, samples = 44) {
  const ring = revolveRings(profile, samples);
  const pos = [];
  const idx = [];
  for (let i = 0; i <= samples; i += 1) {
    const { y, a, bR, z0 } = ring[i];
    for (let j = 0; j <= seg; j += 1) {
      const phi = (j / seg) * Math.PI * 2;
      let x = a * Math.sin(phi);
      let z = z0 + bR * Math.cos(phi);
      // 椭圆 (x/a)² + ((z-z0)/bR)² = 1 的外法线 ∝ (sinφ/a, cosφ/bR)
      let nx = Math.sin(phi) / a;
      let nz = Math.cos(phi) / bR;
      const nl = Math.hypot(nx, nz) || 1;
      nx /= nl; nz /= nl;
      let dsp = 0;
      for (const f of feats) {
        const t = (y - f.y0) / (f.y1 - f.y0);
        if (t <= 0 || t >= 1) continue;
        const phic = f.phi0 + (f.phi1 - f.phi0) * t;   // φ 随高度插值 → 斜的线（马甲线/V 线）
        const g = Math.exp(-(angularGap(phi, phic) ** 2) / (2 * f.sigma * f.sigma));
        /* k 是竖向鼓包的"饱满度"：sin²(πt) 两端斜率为 0（和躯干平滑相接），
           但腰部收得快、鼓出来是"尖顶"；指数降到 1.4 就是圆顶馒头。
           skew 把峰值在带内偏移：skew = ln0.5/ln(t峰值位置)。
           胸肌要上厚下紧（skew 1.26 → 峰在 40% 高度），乳房要下垂感（skew 1.35 → 峰在 60%）。 */
        dsp += f.amp * g * Math.pow(Math.sin(Math.PI * Math.pow(t, f.skew || 1)), f.k || 2);
      }
      pos.push(x + dsp * nx, y, z + dsp * nz);
    }
  }
  for (let i = 0; i < samples; i += 1) {
    for (let j = 0; j < seg; j += 1) {
      const a0 = i * (seg + 1) + j;
      const b0 = a0 + seg + 1;
      idx.push(a0, a0 + 1, b0, b0, a0 + 1, b0 + 1);
    }
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  geo.setIndex(idx);
  geo.computeVertexNormals();
  /* 接缝焊接：φ=0（正前中央）那一圈，j=0 和 j=seg 是两个重复顶点，
     computeVertexNormals 各算各的，正面正中会留一条穿胸而过的明暗缝。
     把每圈首尾顶点的法线取平均写回去，缝就没了。 */
  const nrm = geo.attributes.normal;
  for (let i = 0; i <= samples; i += 1) {
    const a0 = i * (seg + 1);
    const b0 = a0 + seg;
    const nx = (nrm.getX(a0) + nrm.getX(b0)) / 2;
    const ny = (nrm.getY(a0) + nrm.getY(b0)) / 2;
    const nz = (nrm.getZ(a0) + nrm.getZ(b0)) / 2;
    nrm.setXYZ(a0, nx, ny, nz);
    nrm.setXYZ(b0, nx, ny, nz);
  }
  nrm.needsUpdate = true;
  const mesh = new THREE.Mesh(geo, m);
  mesh.castShadow = true;
  mesh.receiveShadow = true;
  return mesh;
}

function shade(hex, k) {
  return '#' + new THREE.Color(hex).multiplyScalar(k).getHexString();
}

/* ── 接地阴影：径向渐变的圆片，比真的开 shadowMap 便宜 ── */
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

/* ── 腮红：径向渐变，边缘渐到 0 才不露边界 ── */
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

/** 头颅表面在给定高度、横向位置处的 z（脸是旋转曲面，z 不能手写）。 */
function surfZ(d, y, x) {
  const pts = [...d.headShape].sort((a, b) => a[1] - b[1]);
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
}

/* ══════════════════════════ 头（含五官与头发） ══════════════════════════
   沿用造型间 v85 的脸：五官 z 一律用 faceAt 现算，旋转体改过脸型后不会浮出来。 */
function buildHead(d, skinMat, hairMat, blushMat) {
  const R = d.headR;
  const head = new THREE.Group();
  const latheMesh = (points, m, z = 1, seg = 44) => {
    const mesh = new THREE.Mesh(lathe(points, seg), m);
    mesh.scale.z = z;
    return mesh;
  };
  const skull = latheMesh(d.headShape, skinMat, d.headSZ, 40);
  head.add(skull);

  const faceAt = (yR, xR) => surfZ(d, yR * R, xR * R);

  const eyeWhiteMat = new THREE.MeshStandardMaterial({ color: '#fffdfa', roughness: 0.30 });
  const irisMat = mat(d, '#54403f', { roughness: 0.38 });
  const pupilMat = mat(d, '#2a1e22', { roughness: 0.30 });
  const shineMat = new THREE.MeshBasicMaterial({ color: '#ffffff' });
  const lashMat = mat(d, '#4a3a40', { roughness: 0.55 });
  const browMat = mat(d, '#5a4650', { roughness: 0.6 });
  for (const side of [-1, 1]) {
    const ex = side * 0.40 * R;
    const ey = -0.015 * R;
    const ez = faceAt(-0.015, side * 0.40);

    /* 眼睛（v85）：旧版大白饼几乎被虹膜盖满，再压一根黑胶囊当眼皮 →
       正面两颗黑玻璃珠。现在眼白缩一号、虹膜坐下睑、瞳孔/高光分层、
       上睑只留一条细睫毛线，才读得出"在看人"。 */
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

    const lash = new THREE.Mesh(new THREE.CapsuleGeometry(0.013 * R, 0.26 * R, 4, 10), lashMat);
    lash.position.set(ex, ey + 0.088 * R, ez + 0.046 * R);
    lash.rotation.set(0.10, 0, Math.PI / 2 + side * 0.06);
    lash.scale.z = 0.55;
    head.add(lash);

    // 双眼皮：睫毛上方的浅色褶线（参考女体截图——没有它眼睛是"贴"上去的）
    const lid = new THREE.Mesh(new THREE.CapsuleGeometry(0.008 * R, 0.24 * R, 4, 10), mat(d, shade(SKIN, 0.93), { roughness: 0.7 }));
    lid.position.set(ex, ey + 0.135 * R, ez + 0.043 * R);
    lid.rotation.set(0.10, 0, Math.PI / 2 + side * 0.06);
    lid.scale.z = 0.5;
    head.add(lid);

    // 眉：拉回眼睛正上方，眉眼距离近了表情才挂在脸上
    const brow = new THREE.Mesh(new THREE.CapsuleGeometry(0.015 * R, 0.24 * R, 4, 10), browMat);
    brow.position.set(side * 0.40 * R, 0.155 * R, faceAt(0.155, side * 0.40) + 0.014 * R);
    brow.rotation.set(0.12, side * 0.20, Math.PI / 2 - side * 0.10);
    brow.scale.z = 0.6;
    head.add(brow);

    const blush = new THREE.Mesh(new THREE.PlaneGeometry(0.44 * R, 0.27 * R), blushMat);
    const bz = faceAt(-0.30, side * 0.50);
    blush.position.set(side * 0.50 * R, -0.30 * R, bz + 0.010 * R);
    blush.rotation.y = side * 0.52;
    head.add(blush);
  }
  /* 耳朵：耳窝（pit）必须整个缩进耳廓里，否则侧影上是一个深色蘑菇凸起。 */
  for (const side of [-1, 1]) {
    const ear = blob(0.075 * R, 0.165 * R, 0.105 * R, skinMat, 14);
    ear.position.set(side * 0.895 * R, -0.045 * R, -0.035 * R);
    ear.rotation.z = side * 0.12;
    head.add(ear);
    const pit = blob(0.032 * R, 0.082 * R, 0.050 * R, mat(d, shade(SKIN, 0.945), { roughness: 0.86 }), 12);
    pit.position.set(side * 0.90 * R, -0.050 * R, 0.005 * R);
    head.add(pit);
  }

  /* 鼻子（v85 重做）：旧版只有一个几乎贴脸的小球（前凸 ~0.01），侧影看不出鼻子。
     现在 = 一条从眉心顺下来的鼻梁细脊 + 一个明显前凸的圆鼻头。 */
  const noseMat = mat(d, shade(SKIN, 0.95), { roughness: 0.82 });
  const noseTip = blob(0.050 * R, 0.060 * R, 0.110 * R, noseMat, 18);
  noseTip.position.set(0, -0.40 * R, faceAt(-0.40, 0) + 0.055 * R);
  head.add(noseTip);
  const bridge = new THREE.Mesh(new THREE.CapsuleGeometry(0.024 * R, 0.26 * R, 4, 10), noseMat);
  bridge.position.set(0, -0.30 * R, faceAt(-0.30, 0) + 0.020 * R);
  head.add(bridge);

  /* 嘴（v85 重做）：上下唇合拢 + 一道深色嘴缝线，
     不再是两片分离的粉色贴纸。 */
  const lipTopMat = mat(d, '#bd6b74', { roughness: 0.46 });
  const lipLowMat = mat(d, '#c8767f', { roughness: 0.44 });
  const mouthY = -0.62 * R;
  const mz = faceAt(-0.62, 0);
  const lipUp = blob(0.132 * R, 0.022 * R, 0.034 * R, lipTopMat, 16);
  lipUp.position.set(0, mouthY + 0.016 * R, mz + 0.006 * R);
  head.add(lipUp);
  const lipLow = blob(0.140 * R, 0.032 * R, 0.038 * R, lipLowMat, 16);
  lipLow.position.set(0, mouthY - 0.012 * R, mz + 0.006 * R);
  head.add(lipLow);
  const seam = new THREE.Mesh(new THREE.CapsuleGeometry(0.009 * R, 0.20 * R, 4, 10), mat(d, '#8a4a52', { roughness: 0.5 }));
  seam.position.set(0, mouthY, mz + 0.014 * R);
  seam.rotation.set(0, 0, Math.PI / 2);
  head.add(seam);

  /* 头发：球面片按发型显隐；这里只留一套（男短发 / 女长发），不再做发型切换。
     ⚠️ cap 用 fit=1.045 的蛋形贴合（见 revolve 上方注释）：头最宽点在额骨，
     纯球壳在 θ28°..54° 会被颅骨顶穿露出头皮。 */
  const H = Math.max(...d.headShape.map((p) => Math.abs(p[1])));
  const HW = R * 1.085;
  const HH = H * 1.075;
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
          const rEgg0 = surfZ(d, HH * grow * y, 0) * fit;
          /* 颅顶以上 surfZ 会钳在发顶半径上，直接用会顶出小凸起；
             按 √(1-u²) 收回 0，发顶收成圆头而不是锥尖。 */
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
        if (taper && t < taper) {
          const f = t / taper;
          const s = (1.002 / grow) + (1 - 1.002 / grow) * (f * f * (3 - 2 * f));
          pos.setX(i, x * s);
          pos.setZ(i, z * s);
        }
        if (wave && t > 0.05) {
          const k = Math.pow(Math.min(1, t), 2.2);
          const phi = Math.atan2(z, x);
          const lobe = 0.58 + 0.30 * Math.sin(phi * 3 + 0.6) + 0.12 * Math.sin(phi * 9 - 1.1);
          const pull = k * wave * lobe;
          pos.setY(i, y - pull);
          const s = 1 + pull * 0.30;
          pos.setX(i, pos.getX(i) * s);
          pos.setZ(i, pos.getZ(i) * s);
        }
      }
      geo.computeVertexNormals();
    }
    const m = new THREE.Mesh(geo, hairMat);
    m.scale.set(HW * grow, HH * grow, HW * grow);
    m.castShadow = true;
    m.receiveShadow = true;
    head.add(m);
    return m;
  };
  addHair('cap', 0.963, 0, Math.PI * 2, 0, Math.PI * 0.40, 48, 26, 0, 0, 1.045);
  // 后脑/后颈的一片：男短（到耳下）、女长（到后颈）
  addHair('back', 1.022, Math.PI * 0.70, Math.PI * 1.60, Math.PI * 0.18, d.hairBackLen, 48, 28, 0.10);
  // 刘海：下沿停在眉毛上方，加波浪刚好垂到眉梢
  addHair('bangs', 1.045, Math.PI * 0.22, Math.PI * 0.56, Math.PI * 0.26, Math.PI * 0.15, 52, 22, 0.115, 0.45);
  return head;
}

function mat(d, color, extra = {}) {
  return new THREE.MeshStandardMaterial({ color, roughness: 0.88, metalness: 0, ...extra });
}

/* ══════════════════════════ 躯干 ══════════════════════════ */
function buildTorso(d, skinMat) {
  const g = new THREE.Group();
  g.add(revolveSkin(d.torso, d.feats, skinMat, 72, 44));
  return g;
}

/* ══════════════════════════ 人体（不含头） ══════════════════════════ */
function buildBody(d, skinMat) {
  const root = new THREE.Group();
  const torso = buildTorso(d, skinMat);
  root.add(torso);

  // 脖子：下粗上细，顶端插进下颌里（插进去才不会在转头时露出缝）
  const neck = taper(d.neckTopR, d.neckR, d.neckTop - d.neckBot, skinMat, 24);
  neck.position.y = (d.neckTop + d.neckBot) / 2;
  root.add(neck);

  /* ── 胸 / 腹 / 臀 ──
     全部由 revolveSkin 的 feats 沿截面外法线鼓出来：乳房是两瓣球（带乳沟）、
     胸肌两瓣带胸骨沟、腹肌两列带白线与横褶、臀两瓣带臀沟、男女都有 V 线。
     这里不再有任何贴球——球贴在曲面上必有一圈法线突变的"贴纸边"。 */

  /* 乳点：贴在胸口曲面上的小凸点（surfacePoint 定位）。
     参考 T-pose 男体图明确有；没有它，一片鼓起的胸读不出朝向。 */
  const nipMat = mat(d, shade(SKIN, 0.87), { roughness: 0.55 });
  for (const side of [-1, 1]) {
    const p = surfacePoint(d, d.nipple.y, side * d.nipple.phi);
    const dot = blob(d.nipple.r, d.nipple.r * 0.72, d.nipple.r * 0.55, nipMat, 12);
    dot.position.set(p.x, p.y, p.z);
    root.add(dot);
  }

  /* ── 手臂：肩 → 肘两段，半径走曲线（造型间第 4 轮定的结构） ── */
  const jointOver = (J) => J * 0.18;
  const elbowJ = (d.upR2 + d.foreR1) / 2;
  const wristR = d.foreR2 * 0.88;
  const armUpperProfile = [
    [0.020, d.upR1 * 1.01],
    [-0.10 * d.upperArm, d.upR1 * 1.10],   // 二头肌最鼓
    [-0.34 * d.upperArm, d.upR1 * 0.97],
    [-0.62 * d.upperArm, d.upR2 * 1.18],
    [-0.88 * d.upperArm, elbowJ * 1.02],
    [-(d.upperArm + jointOver(elbowJ)), elbowJ],   // 恒定半径直段越过关节中心
  ];
  const armForeProfile = [
    [jointOver(elbowJ), elbowJ],
    [-0.13 * d.foreArm, d.foreR1 * 1.05],
    [-0.44 * d.foreArm, d.foreR1 * 0.87],
    [-0.76 * d.foreArm, wristR * 1.10],
    [-d.foreArm, wristR],
  ];
  for (const side of [-1, 1]) {
    const g = new THREE.Group();
    g.position.set(side * d.armPivotX, d.shoulderY, 0);
    g.rotation.z = side * d.armTilt;     // 静止时略微外张，手不会贴在胯上
    // 三角肌：缺了它手臂和躯干之间会有一道缝；大小/高低按性别（女溜肩）
    const [deltR, deltY, deltZ] = d.delt;
    const delt = blob(d.upR1 * deltR, d.upR1 * deltY, d.upR1 * deltZ, skinMat, 20);
    delt.position.y = -0.030 - (d.deltDrop || 0);
    delt.castShadow = true;
    g.add(delt);
    g.add(limb(armUpperProfile, skinMat));
    const elbow = new THREE.Group();
    elbow.position.y = -d.upperArm;
    // 关节球加大 2.5%，从外面完整包住两个管口
    elbow.add(blob(elbowJ * 1.025, elbowJ * 1.025, elbowJ * 1.025, skinMat, 40));
    elbow.add(limb(armForeProfile, skinMat));
    const hand = makeHand(d, side, skinMat);
    hand.position.y = -d.foreArm;
    elbow.add(hand);
    g.add(elbow);
    root.add(g);
  }

  /* ── 腿：髋 → 膝两段，同样走曲线（小腿肚那段是"这是条腿"的关键） ── */
  /* 膝关节要"细"：取上下两段里较细的一根再收 3%，膝盖处才是明显的收腰，
     而不是上下一样粗的一根管子（旧版取平均值，膝盖反而是最粗的地方之一）。 */
  const kneeJ = Math.min(d.thighR2, d.shinR1) * 0.97;
  const shinTube = d.shin - d.footH * 0.30;
  const ankleR = d.shinR2 * 0.90;
  /* 腿的线条：大腿上段饱满 → 中段缓收 → 膝上明显收 → 膝；
     小腿肚（腓肠肌）是一段有峰的鼓包，往下顺到比目鱼肌再收踝。
     控制点给密一点，样条才拉得出"有起伏的曲线"而不是两根锥子。 */
  const thighProfile = [
    [0.020, d.thighR1 * 1.02],
    [-0.08 * d.thigh, d.thighR1 * 1.10],   // 大腿最饱满处（大腿要粗）
    [-0.26 * d.thigh, d.thighR1 * 1.00],
    [-0.50 * d.thigh, d.thighR1 * 0.90],
    [-0.72 * d.thigh, d.thighR1 * 0.80],
    [-0.88 * d.thigh, kneeJ * 1.02],
    [-(d.thigh + jointOver(kneeJ)), kneeJ],
  ];
  /* 小腿线条：腓肠肌在上 1/5 鼓成一个明显的峰 → 中段顺下 → 比目鱼肌末段
     再收到踝。旧版控制点太疏（7 点），样条拉出的峰只有 1.14 倍、几乎读不出
     "小腿肚"；现在 9 点、峰值 1.20、踝收到 0.90×shinR2，粗→细的曲线才出来。 */
  const shinProfile = [
    [jointOver(kneeJ), kneeJ],          // 膝（最细）
    [-0.06 * d.shin, d.shinR1 * 1.08],
    [-0.16 * d.shin, d.shinR1 * 1.20],  // 腓肠肌峰
    [-0.30 * d.shin, d.shinR1 * 1.08],
    [-0.46 * d.shin, d.shinR1 * 0.86],
    [-0.64 * d.shin, d.shinR2 * 1.16],  // 比目鱼肌
    [-0.82 * d.shin, d.shinR2 * 0.98],
    [-shinTube, ankleR],                // 脚踝收细
  ];
  for (const side of [-1, 1]) {
    const g = new THREE.Group();
    g.position.set(side * d.hipPivotX, d.hipY, 0);
    g.add(limb(thighProfile, skinMat));
    const knee = new THREE.Group();
    knee.position.y = -d.thigh;
    knee.add(blob(kneeJ * 1.025, kneeJ * 1.025, kneeJ * 1.025, skinMat, 40));
    knee.add(limb(shinProfile, skinMat));
    /* 脚：裸模的脚不能沿用鞋里的尺寸——加长、压扁、脚尖朝前，再加个倾角
       （踝高掌低），平底椭圆读出来就是两个小肉垫。 */
    const foot = blob(d.footW * 1.02, d.footH * 0.30, d.footLen * 0.56, skinMat, 18);
    foot.position.set(0, -d.shin + d.footH * 0.10, d.footLen * 0.30);
    foot.rotation.x = 0.22;   // 前低后高：脚背的楔形
    knee.add(foot);
    g.add(knee);
    root.add(g);
  }
  return { root, torso };
}

/* ══════════════════════════ 场景与挂载 ══════════════════════════ */
let scene = null;

export function mount(host, opts = {}) {
  host.innerHTML = `
    <div class="body-wrap">
      <section class="card dressup-stage">
        <div class="dressup-chips" id="body-gender">
          <button type="button" class="dressup-chip active" data-gender="m">男生</button>
          <button type="button" class="dressup-chip" data-gender="f">女生</button>
        </div>
        <div class="dressup-chips" id="body-mode">
          <button type="button" class="dressup-chip active" data-mode="single">单人</button>
          <button type="button" class="dressup-chip" data-mode="couple">双人</button>
        </div>
        <div class="dressup-canvas-host" id="body-canvas-host"></div>
        <p class="small-note dressup-hint">按住拖动，可以绕着转一圈</p>
      </section>
      <section class="card">
        <div class="section-heading"><h2 id="body-title">男生 · 人体模型</h2></div>
        <p class="meta">先看形体本身：肩宽、腰线、胯宽、胸/乳房与臀的起伏。
          这一版只做静止人体，换装和动作后面再接。</p>
      </section>
    </div>`;

  const canvasHost = host.querySelector('#body-canvas-host');
  const titleEl = host.querySelector('#body-title');

  if (!scene) {
    let renderer;
    try {
      renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    } catch {
      canvasHost.innerHTML = '<p class="hint">这台设备的浏览器没有开启 3D（WebGL），人体模型暂时看不到。</p>';
      return;
    }
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setClearAlpha(0);
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.05;
    /* 自阴影：只给主光开一张投影图，做身上的接触阴影（下巴→脖子、
       手臂→躯干、头发→额头、大腿→胯）。没有这层，再准的形体也是一片
       均匀亮，看着就是"塑料人"。 */
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.VSMShadowMap;

    const sc = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 60);

    // 摄影棚三点光
    sc.add(new THREE.HemisphereLight(0xffffff, 0xe0cdd6, 1.55));
    const key = new THREE.DirectionalLight(0xfff4ee, 2.00);
    key.position.set(2.4, 4.2, 3.0);
    key.castShadow = true;
    key.shadow.mapSize.set(2048, 2048);
    const sc2 = key.shadow.camera;
    sc2.left = -2.8; sc2.right = 2.8; sc2.top = 2.8; sc2.bottom = -2.8;
    sc2.near = 0.5; sc2.far = 14;
    // ⚠️ 改完边界必须 updateProjectionMatrix，否则投影矩阵仍是默认 ±5/far 500，
    // 2048 张图摊在两倍面积上 → 阴影边缘一格一格、手臂上糊出暗斑。
    sc2.updateProjectionMatrix();
    key.shadow.bias = -0.0009;
    key.shadow.normalBias = 0.085;
    key.shadow.radius = 3.5;
    key.shadow.blurSamples = 12;
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

    // 男女各建一次，切换只改 visible（不重建几何体，省显存也快）
    const blushMat = new THREE.MeshBasicMaterial({ map: blushTexture(), transparent: true, depthWrite: false });
    const made = [BODY_M, BODY_F].map((d) => {
      const skinMat = mat(d, SKIN, { roughness: 0.80 });
      const hairMat = mat(d, d.hairColor, { roughness: 0.55, metalness: 0.02 });
      const body = buildBody(d, skinMat);
      const head = buildHead(d, skinMat, hairMat, blushMat);
      /* QQ 秀比例：整颗头统一放大 headScale，位置按"下巴埋进领口 0.035"算，
         不再用手写的 headY——改 headScale 或脖子高度头都不会悬空/插太深。 */
      head.scale.setScalar(d.headScale);
      const chin = Math.min(...d.headShape.map((p) => p[1])) * d.headSZ * d.headScale;
      head.position.y = d.neckTop - 0.035 - chin;
      body.root.add(head);
      const box = new THREE.Box3().setFromObject(body.root);
      const holder = new THREE.Group();
      holder.add(body.root);
      body.root.position.y = -box.min.y;   // 脚踩到 y=0
      couple.add(holder);
      return { key: d.gender, holder, head, root: body.root };
    });

    const shadow = new THREE.Mesh(
      new THREE.CircleGeometry(1.0, 44),
      new THREE.MeshBasicMaterial({ map: shadowTexture(), transparent: true, depthWrite: false }),
    );
    shadow.rotation.x = -Math.PI / 2;
    shadow.position.y = 0.004;
    // 挂在 spin 上：couple 会被 fitCamera 平移去居中，阴影跟着走就离开脚下了
    spin.add(shadow);

    scene = { renderer, scene: sc, camera, spin, couple, shadow, made, raf: 0, running: false };
  }

  const { renderer, camera, couple, made, shadow } = scene;
  canvasHost.appendChild(renderer.domElement);

  /* ── 取景：按当前偏航下的投影算，人物填满画面 ──
     坑：按包围球半径算距离，球半径是"半对角线"，人只占画面一半。
     改成分别算横向投影和纵向高度，取更紧的那个。 */
  const fitCamera = () => {
    const yaw = scene.spin.rotation.y;
    scene.spin.rotation.y = 0;          // 量尺寸时先归零，否则取景会跟着角度抖
    couple.position.set(0, 0, 0);
    couple.updateWorldMatrix(true, true);
    const box = new THREE.Box3();
    for (const a of made) if (a.holder.visible) box.expandByObject(a.root);
    const c = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    couple.position.set(-c.x, 0, -c.z);   // 几何中心挪到转轴原点；y 不动，阴影留在 y≈0
    scene.spin.rotation.y = yaw;
    scene.spin.updateWorldMatrix(true, true);

    const vHalf = Math.tan(THREE.MathUtils.degToRad(camera.fov / 2));
    const hHalf = vHalf * camera.aspect;
    const spanX = size.x * Math.abs(Math.cos(yaw)) + size.z * Math.abs(Math.sin(yaw));
    const dist = Math.max(spanX / 2 / hHalf, size.y / 2 / vHalf) * 1.14;
    shadow.scale.setScalar(Math.max(spanX / 2, 0.85));
    camera.position.set(0, c.y + size.y * 0.03, dist);
    camera.lookAt(0, c.y, 0);
  };

  let dirty = true;
  const invalidate = () => { dirty = true; };

  const resize = () => {
    const w = canvasHost.clientWidth || 1;
    const h = canvasHost.clientHeight || 1;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    fitCamera();
    invalidate();
  };
  resize();
  const ro = new ResizeObserver(resize);
  ro.observe(canvasHost);

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
    invalidate();
  };
  const onUp = () => {
    if (!dragging) return;
    dragging = false;
    fitCamera();      // 侧身后投影变窄，松手重新取景填上空处
    invalidate();
  };
  cv.addEventListener('pointerdown', onDown);
  cv.addEventListener('pointermove', onMove);
  cv.addEventListener('pointerup', onUp);
  cv.addEventListener('pointercancel', onUp);

  /* 静止模型：只在有变化（拖动/尺寸变化）时重画，不跑常驻动画。 */
  const tick = () => {
    if (!scene || !scene.running) return;
    if (dirty) {
      dirty = false;
      renderer.render(scene.scene, camera);
    }
    scene.raf = requestAnimationFrame(tick);
  };
  scene.running = true;
  cancelAnimationFrame(scene.raf);
  scene.raf = requestAnimationFrame(tick);

  /* ── 交互：性别 / 单双人 ── */
  let gender = 'm';
  let mode = 'single';
  const apply = () => {
    for (const a of made) a.holder.visible = mode === 'couple' || a.key === gender;
    // 单人时把人挪回转轴中心；双人时左右分开
    const gap = 0.46;
    for (const a of made) {
      if (!a.holder.visible) continue;
      a.holder.position.x = mode === 'couple' ? (a.key === 'm' ? -gap : gap) : 0;
    }
    titleEl.textContent = mode === 'couple'
      ? '男生 + 女生 · 人体模型'
      : (gender === 'm' ? '男生 · 人体模型' : '女生 · 人体模型');
    fitCamera();
    invalidate();
  };
  const onClick = (ev) => {
    const gbtn = ev.target.closest('[data-gender]');
    const mbtn = ev.target.closest('[data-mode]');
    if (!gbtn && !mbtn) return;
    if (!host.contains(ev.target)) return;
    if (gbtn) {
      gender = gbtn.dataset.gender;
      host.querySelectorAll('[data-gender]').forEach((b) => b.classList.toggle('active', b.dataset.gender === gender));
    }
    if (mbtn) {
      mode = mbtn.dataset.mode;
      host.querySelectorAll('[data-mode]').forEach((b) => b.classList.toggle('active', b.dataset.mode === mode));
    }
    apply();
  };
  host.addEventListener('click', onClick);

  apply();

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

export function pause() {
  if (!scene) return;
  scene.detach?.();
  scene.detach = null;
  scene.renderer.domElement.remove();
}
