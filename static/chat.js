'use strict';

/* ── 私聊 / 气泡 / 贴纸（自 app.js 拆出）────────────────────────────────
   消息流渲染、壁纸与皮肤、表情包、相册多选、表情气泡、位置。

   ⚠️ 和 app.js 共享全局作用域（两个都是 classic script，没走 ES module），
   $ / esc / api / state / icon / openModal 直接用。不用 module 的原因见 app.js 首部。
   ⚠️ 必须排在 app.js 之前加载：app.js 末尾的 boot() 会调 messagesPage()/chatRows()。
   ⚠️ 新增本类文件要同步 static/sw.js 的 BUNDLES，否则旧 worker 拿不到。

   留在 app.js 的两段（有意为之，别搬过来）：
   · 歌单播放器（songAudio / paintSong / sendSong …）——音频状态机，不止聊天的；
   · 顶部两个 document.addEventListener（收起表情面板 / 存自定义贴纸）——顶层可执行，
     搬走就破坏了「本文件只有声明、与加载顺序无关」这条不变量。 */

function pendingChats() {try{return JSON.parse(localStorage.getItem('pending-chat:'+state.me.user.id)||'[]');}catch{return [];}}
function setPending(chats) {localStorage.setItem('pending-chat:'+state.me.user.id,JSON.stringify(chats));}
/* 微信式时间分隔：间隔超过 5 分钟或跨天时，在消息流中插入居中时间条 */
function chatTimeLabel(ts,last){
 if(last!=null&&ts-last<=300&&new Date(ts*1000).toDateString()===new Date(last*1000).toDateString())return '';
 const d=new Date(ts*1000),n=new Date(),hm=String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0');
 if(d.toDateString()===n.toDateString())return hm;
 if(d.toDateString()===new Date(n.getTime()-864e5).toDateString())return '昨天 '+hm;
 return (d.getFullYear()===n.getFullYear()?'':d.getFullYear()+'年')+(d.getMonth()+1)+'月'+d.getDate()+'日 '+hm;
}
function chatRows() {
 /* 页内搜索只筛已加载的最近 200 条：聊天会无限增长，全量搜索得走后端，
    这里的定位是"刚聊过的东西翻不到了"，够用又不加接口。 */
 const q=(state.chatSearch||'').trim().toLowerCase();
 const all=recordsOf('chat').sort((a,b)=>a.created-b.created);
 const chats=q?all.filter(r=>!r.body.recalled&&(((r.body.content||'').toLowerCase().includes(q))||(((r.body.reply_to||{}).text||'').toLowerCase().includes(q)))):all;
 const pending=pendingChats().filter(p=>!all.some(c=>c.client_id===p.client_id));
 let lastTs=null;
 const rows=chats.map(r=>{
  const tl=chatTimeLabel(r.created,lastTs);lastTs=r.created;
  if(r.body.recalled)return `${tl?`<div class="chat-day">${tl}</div>`:''}<div class="chat-recall" id="msg-${r.id}">${r.author===state.me.user.id?'你':'对方'}撤回了一条消息</div>`;
  const mine=r.author===state.me.user.id,hasText=!!(r.body.content||'').trim(),voiceOnly=(r.media||[]).some(m=>m.mime.startsWith('audio/'))&&!hasText;
  const sticker=r.body.sticker;
  /* 引用块只存"那条的 id + 当时那句话"，点一下跳回原消息；原消息被撤回也还看得懂上下文 */
  const quote=r.body.reply_to?`<button type="button" class="chat-quote" data-action="chat-jump" data-id="${esc(r.body.reply_to.id)}"><span>${esc((r.body.reply_to.text||'原消息').slice(0,60))}</span></button>`:'';
  const ops=(mine&&Date.now()/1000-r.created<120?`<button data-action="recall-chat" data-id="${r.id}">撤回</button>`:'')
   +`<button data-action="chat-reply" data-id="${r.id}">引用</button>`
   +`<button data-action="chat-pin" data-id="${r.id}">${r.body.pinned?'取消置顶':'置顶'}</button>`
   +`<button data-action="chat-to-draft" data-id="${r.id}">记入时光</button>`;
  /* 位置消息：body.location = {lat,lng}，点开用高德 URI 打开地图（不依赖任何 KEY） */
  const loc=r.body.location&&typeof r.body.location.lat==='number'&&typeof r.body.location.lng==='number'?r.body.location:null;
  const locCard=loc?`<button type="button" class="chat-loc" data-action="chat-open-map" data-lat="${loc.lat}" data-lng="${loc.lng}" title="用高德地图打开"><span class="cl-ico">${icon('location')}</span><span class="cl-body"><b>位置</b><small>点开用高德地图看</small></span><span class="cl-go">${icon('arrow')}</span></button>`:'';
  /* 分享的歌：body.song = {title,artist,mid,src,art,dur}。mid 指向歌单里的音频媒体，
     src 是在线搜来的 30 秒试听地址（走同源 /api/music/stream 转发）。两个都有就优先本地文件。 */
  const song=r.body.song&&r.body.song.title?r.body.song:null;
  const songCard=song?songCardMarkup(song):'';
  const inner=songCard?`<div class="chat-bubble song">${quote}${songCard}</div>`:locCard?`<div class="chat-bubble loc">${quote}${locCard}</div>`:sticker?`<div class="chat-sticker${sticker.endsWith('.webm')?' video':''}">${sticker.endsWith('.webm')?`<video src="${esc(sticker)}" autoplay loop muted playsinline></video>`:`<img src="${esc(sticker)}" alt="贴纸" loading="lazy">`}</div>`:`<div class="chat-bubble${voiceOnly?' voice':''}${r.body.pinned?' pinned':''}">${quote}<span style="white-space:pre-wrap">${esc(r.body.content)}</span>${mediaMarkup(r.media)}</div>`;
  return `${tl?`<div class="chat-day">${tl}</div>`:''}<div class="chat-line ${mine?'mine':''}" id="msg-${r.id}">${avatar(r.author)}<div>${inner}${ops?`<div class="chat-time">${ops}</div>`:''}</div></div>`;
 }).join('');
 const pend=pending.map(p=>`<div class="chat-line mine pending">${avatar(state.me.user.id)}<div><div class="chat-bubble">${esc(p.body.content||'一个附件')}</div><div class="chat-time">尚未发送 <button data-action="retry-chat" data-id="${p.client_id}">点击重试</button></div></div></div>`).join('');
 if(q&&!chats.length)return `<div class="chat-no-match">最近 200 条里没有「${esc(state.chatSearch)}」，试试清掉筛选。</div>`;
 return rows+pend||empty('今天，有什么想对 TA 说？','说说日常，也说说想念。');
}
/* 聊天列表的增量重绘：按 id 原地对账，只动真正变了的行。
   以前每个刷新点都写 `log.innerHTML = chatRows()`，整段重建会把每一行的
   <img>/<video> 一起销毁重造——200 条消息里的图全部重新解码、正在循环的贴纸
   从头播、滚动位置也跟着跳，附件还要全部重新走一遍网络。
   这里按 id 对账：内容没变的行一个节点都不碰（位置也对得上就 continue），
   只有真的变了才插入新节点。**不要**改成"先摘进 frag 再整体塞回"——
   <video> 被摘下再挂回会重新解析 poster，等于白拿一次网络请求。 */
function chatRowKey(node) {
 if (node.id && node.id.indexOf('msg-') === 0) return node.id;
 if (node.classList && node.classList.contains('chat-day')) return 'day:' + node.textContent;
 return null; /* 「尚未发送」这类临时行没有稳定 id：直接重建，它不含图片，代价可忽略 */
}
function paintChat(log) {
 if (!log) return;
 /* 必须用 <template> 解析，不能用游离的 <div>：div 里解析出来的 <video poster="…">
    会立刻开始预取封面、<img> 也会开始下载——每重绘一次就凭空多出一整屏媒体请求
    （实测 8 个视频 = 8 次 /media?poster=true）。template.content 是惰性的，
    解析完一个请求都不发，节点搬进文档才激活。 */
 const tpl = document.createElement('template');
 tpl.innerHTML = chatRows();
 const prev = new Map();
 for (const node of Array.prototype.slice.call(log.children)) {
  const k = chatRowKey(node);
  if (k && !prev.has(k)) prev.set(k, node);
 }
 const want = [];
 for (const node of Array.prototype.slice.call(tpl.content.children)) {
  const k = chatRowKey(node);
  const old = k && prev.get(k);
  if (old && old.outerHTML === node.outerHTML) { prev.delete(k); want.push(old); }
  else want.push(node);
 }
 /* 逐个就位：已经在正确位置的行直接跳过（不摘不挂，附件不重新请求） */
 for (let i = 0; i < want.length; i++) {
  if (log.children[i] === want[i]) continue;
  log.insertBefore(want[i], log.children[i] || null);
 }
 /* 多出来的行（撤回、搜索过滤后消失）从尾部删掉 */
 while (log.children.length > want.length) log.removeChild(log.lastChild);
}
/* 聊天壁纸：预设用 CSS 渐变/纹理，'photo' 用自己上传的照片。
   dim 是压在图上的遮罩强度（百分比）——它存在的意义只有一个：保证气泡文字在任何底图上都读得清。
   壁纸写在 space 设置里（/api/space → db.setting('space')），所以是**两个人共用一份**：
   谁改都对双方同时生效，不需要各设各的。 */
const CHAT_BG_PRESETS=[['','默认'],['sakura','樱粉'],['cream','奶油'],['mint','薄荷'],['stars','星光'],['night','夜幕'],['photo','用照片']];
/* 聊天背景是**每人一份**的（space.chat_bg_users[用户 id]），谁都能替对方设；
   自己没单独设过时才退回空间级的共同默认值。所以两边可以各看各的背景图。 */
function chatBgOf(uid){
 const s=state.me?.space||{};
 return (s.chat_bg_users||{})[uid] || {bg:s.chat_bg||'', media:s.chat_bg_media||'', dim:s.chat_bg_dim??35};
}
function myChatBg(){return chatBgOf(state.me?.user?.id);}
function wallpaperDim(){return Math.min(80,Math.max(0,Number(myChatBg().dim)||0));}
/* 只有真照片才进"沉浸式"：气泡/标题栏/输入栏换成半透明深色，让照片透出来。
   预设渐变本来就是浅色的，套深色气泡反而突兀，所以保持原来的浅色排版。 */
function chatBgIsPhoto(){const b=myChatBg();return b.bg==='photo'&&!!b.media;}
/* 壁纸层挂在 .chat-panel 上而不是消息区内部：这样背景是**整屏**的，标题栏和输入栏
   也压在图上（像聊天 App 那样），而不是只铺消息列表那块。 */
function chatWallpaper(){
 const bg=myChatBg().bg||'';
 if(!bg)return '';
 const style=`--chat-bg-dim:${wallpaperDim()/100}`;
 return bg==='photo'
  ? `<div class="chat-wallpaper photo" id="chat-wallpaper" aria-hidden="true" style="${style}"></div>`
  : `<div class="chat-wallpaper" id="chat-wallpaper" data-bg="${esc(bg)}" aria-hidden="true" style="${style}"></div>`;
}

/* ── 背景照片本地缓存 ──
   /media/ 是 no-store（私密媒体不该留在任何共享缓存里），后果是每次进聊天都要重新下载
   背景图，App 上尤其明显。这里按 media id 把图片 Blob 存进 IndexedDB：
   id 没变 → 直接用本地副本，一次网络请求都不发；换图后 id 变 → 新 key 重新下载，旧副本自动清掉。
   IndexedDB 不可用（隐私模式 / 老 WebView）时静默降级为每次联网。 */
const BG_DB='love-space-bg',BG_STORE='wallpaper';
let bgObjectUrl='';
function bgIDB(){
 return new Promise((resolve,reject)=>{
  if(!window.indexedDB)return reject(new Error('no indexedDB'));
  const req=indexedDB.open(BG_DB,1);
  req.onupgradeneeded=()=>{const db=req.result;if(!db.objectStoreNames.contains(BG_STORE))db.createObjectStore(BG_STORE);};
  req.onsuccess=()=>resolve(req.result);
  req.onerror=()=>reject(req.error||new Error('open failed'));
 });
}
async function bgCacheRead(key){
 try{
  const db=await bgIDB();
  return await new Promise((res,rej)=>{const rq=db.transaction(BG_STORE,'readonly').objectStore(BG_STORE).get(key);rq.onsuccess=()=>res(rq.result||null);rq.onerror=()=>rej(rq.error);});
 }catch{return null;}
}
async function bgCacheWrite(key,blob){
 try{
  const db=await bgIDB();
  await new Promise((res,rej)=>{const tx=db.transaction(BG_STORE,'readwrite');tx.objectStore(BG_STORE).put(blob,key);tx.oncomplete=res;tx.onerror=()=>rej(tx.error);});
 }catch{}
}
/* 只留当前这张：换了背景，旧图不该继续占着本地空间 */
async function bgCacheTrim(keep){
 try{
  const db=await bgIDB();
  await new Promise(res=>{
   const tx=db.transaction(BG_STORE,'readwrite'),store=tx.objectStore(BG_STORE),rq=store.getAllKeys();
   rq.onsuccess=()=>{(rq.result||[]).forEach(k=>{if(k!==keep)store.delete(k);});};
   tx.oncomplete=res;tx.onerror=res;
  });
 }catch{}
}
function paintWallpaper(layer,blob){
 if(bgObjectUrl){URL.revokeObjectURL(bgObjectUrl);bgObjectUrl='';}
 bgObjectUrl=URL.createObjectURL(blob);
 layer.style.backgroundImage=`url("${bgObjectUrl}")`;
 layer.dataset.ready='1';
}
async function applyWallpaper(){
 // body 上的 chat-immersive 是布局用的（原生 App 里决定聊天气泡页要不要铺到状态栏后面），
 // 在这里同步一份：换背景不必等整页重渲染，下次进聊天页也一定是对的。
 document.body.classList.toggle('chat-immersive', chatBgIsPhoto());
 const layer=$('#chat-wallpaper');
 if(!layer)return;
 if(!chatBgIsPhoto()){layer.dataset.ready='';bgCacheTrim('');return;}
 const mid=myChatBg().media,key='bg:'+mid;
 const cached=await bgCacheRead(key);
 if(cached&&cached.size){paintWallpaper(layer,cached);bgCacheTrim(key);return;}
 try{
  const res=await fetch(`/media/${mid}?preview=true`,{credentials:'same-origin'});
  if(!res.ok)return;
  const blob=await res.blob();
  if(!blob.size)return;
  paintWallpaper(layer,blob);
  await bgCacheWrite(key,blob);
  bgCacheTrim(key);
 }catch{/* 离线或失败：这次就没背景图，下次进来再试 */}
}

/* ── 聊天气泡皮肤 ────────────────────────────────────────────────────
   素材是 128×112 的整图（四角带装饰），前端用 CSS border-image 切九宫格拉伸，
   所以图不裁不切，原样引用即可。自己的消息用服务器预先水平翻转过的 -r.png：
   微信气泡的尖角和装饰都在左下角（对方那一侧），镜像之后才落在靠外的那边。
   皮肤存在 space 设置里（两个人共用一份），字色单独存一个字段——图有深有浅，
   白字深字没法自动判断。 */
function chatSkin(){
 const v=state.me?.space?.chat_bubble;
 return typeof v==='string'?v:'';
}
function chatSkinFg(){return (state.me?.space?.chat_bubble_fg||'dark')==='light'?'light':'dark';}
/* 皮肤素材是网上收的整图，"装饰/尾巴"画在左边还是右边看作作者，三个包也不统一。
   所以给一个左右互换开关；库里没这个键的老空间按"对调"起步——
   素材多数画成了右侧样式，原图给"我"那侧才顺眼。 */
function chatSkinSwap(){return state.me?.space?.chat_bubble_swap!==false;}
function chatSkinAttrs(){
 const skin=chatSkin();
 if(!skin)return {cls:'',style:''};
 const mirror=skin.replace(/\.png$/,'-r.png');
 /* CSS 里 --skin 是左侧（对方）、--skin-r 是右侧（我）。
     互换时把两张图对调即可，不用另生成素材。 */
 const swap=chatSkinSwap(), left=swap?mirror:skin, right=swap?skin:mirror;
 return {cls:' skin-on'+(chatSkinFg()==='light'?' skin-light':''),
         style:` style="--skin:url('/api/bubbles/${esc(left)}');--skin-r:url('/api/bubbles/${esc(right)}')"`};
}

function messagesPage() {
 const partner=state.me.users.find(u=>u.id!==state.me.user.id);
 const immersive=chatBgIsPhoto(),bgOn=!!myChatBg().bg,skinAttrs=chatSkinAttrs();
 /* 置顶条只显示最新的一条，点开跳过去；多条时给个总数，不挤占聊天区 */
 const pinned=recordsOf('chat').filter(r=>r.body.pinned&&!r.body.recalled).sort((a,b)=>b.created-a.created);
 const pinnedBar=pinned.length?`<button type="button" class="chat-pinned" data-action="chat-jump" data-id="${pinned[0].id}"><span class="cp-tag">📌 置顶</span><span class="cp-text">${esc((pinned[0].body.content||'一条附件').slice(0,42))}</span>${pinned.length>1?`<i>共 ${pinned.length} 条</i>`:''}</button>`:'';
 const searchBar=state.chatSearch?`<div class="chat-search-bar"><span>筛选「${esc(state.chatSearch)}」</span><button type="button" data-action="chat-search-clear">清除</button></div>`:'';
 const replyBar=state.chatReply?`<div class="chat-reply-bar"><i class="crb-mark" aria-hidden="true">↩</i><span>引用：${esc(state.chatReply.text||'一条消息')}</span><button type="button" class="icon-btn" data-action="chat-reply-cancel" aria-label="取消引用">${icon('close')}</button></div>`:'';
 /* ── 输入栏：中间胶囊输入框，右侧语音 / 表情 / 更多 ──────────
    有文字时语音按钮让位给发送按钮（form.has-text 控制）。 */
 const composeBar=`<form id="chat-form" class="chat-compose">
  <div class="compose-field"><textarea id="chat-text" name="content" placeholder="发消息" rows="1" maxlength="20000" aria-label="聊天内容" autocomplete="off" enterkeyhint="send"></textarea></div>
  <button type="button" class="compose-ib compose-mic" data-action="chat-voice" aria-label="发语音" title="发语音">${icon('mic')}</button>
  <button type="button" class="compose-ib compose-emoji" data-action="sticker-panel" aria-label="表情" title="表情">${icon('smile')}</button>
  <button type="button" class="compose-ib compose-plus" data-action="chat-fn" aria-label="更多" title="更多">${icon('plus')}</button>
  <button class="compose-send" type="submit" aria-label="发送消息" title="发送">${icon('send')}</button>
 </form>`;
 /* 面板只有网格：上方输入栏已经有一模一样的语音/表情/关闭，再加一行头就是重复。
     点 ⊕ 再点一次即可收起，选完任一项也会自动收起。 */
 const fnPanel=`<div id="chat-fn" class="fn-panel" hidden>
  <div class="fn-grid">
   <button type="button" class="fn-tile" data-action="chat-pick" data-id="media"><span class="fn-ico">${icon('image')}</span><b>相册</b></button>
   <button type="button" class="fn-tile" data-action="chat-pick" data-id="camera"><span class="fn-ico">${icon('camera')}</span><b>拍摄</b></button>
   <button type="button" class="fn-tile" data-action="chat-call"><span class="fn-ico">${icon('phone')}</span><b>发起通话</b></button>
   <button type="button" class="fn-tile" data-action="chat-locate"><span class="fn-ico">${icon('location')}</span><b>位置</b></button>
   <button type="button" class="fn-tile" data-action="chat-song"><span class="fn-ico">${icon('music')}</span><b>音乐</b></button>
  </div>
 </div>`;
 return `<section class="chat-panel${bgOn?' has-wallpaper':''}${immersive?' immersive':''}${skinAttrs.cls}"${skinAttrs.style}>${chatWallpaper()}<header class="chat-header"><button class="icon-btn" data-action="chat-back" aria-label="返回">${icon('back')}</button>${partner?avatar(partner.id):'<span class="avatar">♡</span>'}<div><h3>${partner?esc(partner.name):'等待另一半加入'}</h3><small>我们的悄悄话 · 仅彼此可见</small></div><button class="icon-btn" data-action="chat-search" aria-label="搜索消息" title="搜索消息" style="margin-left:auto">${icon('search')}</button><button class="icon-btn" data-action="chat-bg" aria-label="聊天背景" title="聊天背景">${icon('photo')}</button><button class="icon-btn" data-nav="imports" aria-label="聊天记录">${icon('book')}</button></header><div class="chat-body">${pinnedBar}${searchBar}<div id="chat-log" class="chat-log" aria-live="polite">${chatRows()}</div></div><div id="sticker-dock" class="sticker-dock" hidden></div>${replyBar}${composeBar}${fnPanel}<input id="chat-file" type="file" accept="image/*,video/*" multiple hidden><input id="chat-shot" type="file" accept="image/*" capture="environment" hidden></section>`;
}
function scrollChat(){const log=$('#chat-log');if(log)log.scrollTop=log.scrollHeight;}


/* ── 表情包：内置 emoji 两组（日常 / 涩涩）+ 个人自定义表情包（存本机，上传即存服务器媒体库） ── */
const CUTE_EMOJI=['😊','😄','🥰','😘','😗','💋','❤️','🧡','💕','💞','🤗','😳','🙈','✨','🌹','🍰','🍜','☕','🌙','⭐','🍀','🎁','📷','🎵','💤','🫶','🏠','🌈','☀️','🌧️'];
const SPICY_EMOJI=['😈','🫦','😏','💗','🍑','🍌','🍆','💦','👅','🔥','🛌','🙈','💋','🤫','💞','🌙'];
/* 内置贴纸包：静态文件打包于 static/stickers/<dir>/0..n.<ext>，双方登录即可用 */
const STICKER_PACKS=[
 {id:'pk-dancer',label:'🕺 舞动',dir:'musicfuckdancer3',ext:'webm',count:50},
 {id:'pk-tsrj8',label:'🫧 TSRJ8',dir:'tsrj8',ext:'webm',count:120},
 {id:'pk-lolitax',label:'🎀 Lolitax',dir:'lolitax',ext:'webp',count:119},
];
const stickerKey=()=>'stickers:'+state.me.user.id;
function myStickers(){try{return JSON.parse(localStorage.getItem(stickerKey())||'[]');}catch{return[];}}
function setStickers(list){localStorage.setItem(stickerKey(),JSON.stringify(list.slice(0,100)));}
function insertStickerText(em){const ta=$('#chat-text');if(!ta)return;if(document.activeElement===ta){const s=ta.selectionStart??ta.value.length,e=ta.selectionEnd??s;ta.value=ta.value.slice(0,s)+em+ta.value.slice(e);ta.selectionStart=ta.selectionEnd=s+em.length;}else ta.value+=em;syncCompose();}
/* 微信式输入框：初始一行，输入后自动长高，超过约 4 行内部滚动 */
function autoGrow(ta){if(!ta)return;ta.style.height='auto';ta.style.height=Math.min(ta.scrollHeight,96)+'px';}
/* 有文字时把语音位换成发送按钮（.has-text 由样式接管显示/隐藏）。 */
function syncCompose(){
 const form=$('#chat-form'),ta=$('#chat-text');
 if(form&&ta){form.classList.toggle('has-text',!!ta.value.trim());autoGrow(ta);}
}
/* ── 键盘避让 ────────────────────────────────────────────────────────────────
   两种机型行为互斥，必须分开走，混用就是双份位移（v1.6.21 踩过）：

   A. 布局视口会跟着键盘缩的机器（Android 17 实测：主人机）
      window.innerHeight 变小，vv.height 也变小 → hidden 能算出真值。
      直接用 hidden，**绝不能再用原生桥的值**，否则输入框会多顶一个键盘高度。

   B. 布局视口不缩的机器（Android 15 强制 edge-to-edge 后实测：女友机）
      innerHeight 与 vv.height 都不变 → hidden 恒 0 → 输入框被键盘遮住。
      只能靠原生 setupImeHeightBridge 经 __kbSetNative() 把 IME 高度喂进来。

   判据：hidden 算得出来（>90）就信网页；算不出来才信原生。
   kbShrink 一旦观测到视口真的被缩过就永久置 1，表示"这台机器是 A 类"，
   顺带挡掉"键盘收起瞬间原生值还没归零却被误用"的空窗。

   ── 平滑（只对 B 类机器生效）────────────────────────────────────────────
   原生桥是逐帧推整数高度的，直接写进 --kb-h 会让 padding-bottom 每帧重排。
   B 类机器上加一层指数平滑 + 单帧步长封顶，把跳变摊成连续上升。
   🔴 **A 类机器（主人机）必须逐字节保持原逻辑、不走平滑**：
      它的视口自己会缩，hidden 已经是平滑的系统值；再叠一层平滑会引入滞后，
      而且 --kb-shift 必须直接用 hidden（真实收缩量），不能用被削过的平滑值，
      否则壁纸补偿对不上、图会跟着键盘漂。
      2026-11-06 就是在这里改坏主人机的（KbLive 90→10、--kb-shift 改用平滑值、
      kbUp 记忆值把输入栏粘在高位），三处一起回归。 */
let kbShrink=0,kbNativePx=0,kbBaseH=0;
/* B 类机器平滑用的状态 */
let kbSmooth=0,kbRaf=0,kbTarget=0;
const kbDpr=()=>window.devicePixelRatio||1;
function syncKeyboard(){
 const vv=window.visualViewport;if(!vv)return;
 const ih=window.innerHeight;
 if(!kbBaseH||ih>kbBaseH)kbBaseH=ih;   /* 基准：见过的最大布局视口高度，换屏/旋转自动跟随 */
 const hidden=Math.max(0,Math.round(ih-vv.height-vv.offsetTop));
 /* 布局视口被键盘缩掉了 → A 类机器，原生桥永久让位 */
 if(Math.round(kbBaseH-ih)>90)kbShrink=1;

 /* ── A 类机器：完全沿用 e6cf8d1 的算法，一帧不平滑 ── */
 if(kbShrink||hidden>90){
  kbTarget=0;kbSmooth=0;
  if(kbRaf){cancelAnimationFrame(kbRaf);kbRaf=0;}
  applyKbA(hidden);
  return;
 }

 /* ── B 类机器：原生值才是唯一来源 ── */
 const px=kbNativePx/kbDpr();
 if(px<=90){                    /* 键盘真的没开（或已收起）：立刻归零 */
  kbTarget=0;kbSmooth=0;
  if(kbRaf){cancelAnimationFrame(kbRaf);kbRaf=0;}
  applyKbB(0);
  return;
 }
 kbTarget=px;
 if(!kbRaf)kbRaf=requestAnimationFrame(kbStep);
}
/* A 类机器落盘：与 e6cf8d1 逐字节等价。
   --kb-h 与 --kb-shift 两个阈值/条件必须按原样分开写，不能合并：
     · --kb-h   = hidden>90 ? hidden : 0
     · --kb-shift = (kbShrink && hidden>90) ? hidden : 0
   kbShrink 表示"布局视口真的被键盘缩过"；浏览器/老内核只缩视觉视口时
   kbShrink=0，此时壁纸本来就不会变矮，**绝不能**写 shift，否则会把壁纸拉长。 */
function applyKbA(hidden){
 const h=hidden>90?hidden:0;
 document.documentElement.style.setProperty('--kb-h',h>0?h+'px':'0px');
 document.documentElement.style.setProperty('--kb-shift',(kbShrink&&hidden>90)?hidden+'px':'0px');
 if(document.body)document.body.classList.toggle('kb-open',h>90);
 noteKbPanel(h);
}
/* B 类机器落盘：--kb-shift 恒 0（这类机型视口不缩，壁纸本来就不动，不需要补偿）。 */
function applyKbB(v){
 const h=Math.max(0,Math.round(v));
 document.documentElement.style.setProperty('--kb-h',h>0?h+'px':'0px');
 document.documentElement.style.setProperty('--kb-shift','0px');
 if(document.body)document.body.classList.toggle('kb-open',h>90);
 noteKbPanel(h);
}
/* 记住这台机器键盘的实际高度，给「更多功能」面板当高度用（见 style.css:.fn-panel）。
   只增不减：键盘收起时 h 归零，不能把已记下的高度清掉，否则下次开面板又回落 260。
   上限夹在 200~420，避免异常值把聊天区挤没。 */
let kbPanelH=0;
function noteKbPanel(h){
 if(h<200)return;
 if(h>420)h=420;
 if(h===kbPanelH)return;
 kbPanelH=h;
 document.documentElement.style.setProperty('--kb-panel-h',h+'px');
}
/* 每帧读最新的 kbTarget（不在 rAF 闭包里锁死首帧值）。
   🔴 指数平滑必须配单帧步长封顶：gap 初始就是整段位移（294px），
      乘 0.85 会第一帧直接跳 252px —— 真机表现是「闪一下、闪在终态位置」。
      封顶 42px 后 294px 摊到 7 帧（约 200ms）走完，是肉眼可见的连续上升。 */
const kbMaxStep=42;
function kbStep(){
 kbRaf=0;
 const gap=kbTarget-kbSmooth;
 if(Math.abs(gap)<0.6){ kbSmooth=kbTarget; applyKbB(kbSmooth); return; }
 let step=gap*0.85;
 if(step>kbMaxStep)step=kbMaxStep;
 if(step<-kbMaxStep)step=-kbMaxStep;
 kbSmooth+=step;
 applyKbB(kbSmooth);
 kbRaf=requestAnimationFrame(kbStep);
}
/* 原生 IME 高度桥的唯一入口（MainActivity.pushImeHeight 调用）。
   原生只传**物理像素**，"换算成 CSS px"和"用不用"都由这里决定。
   收到的值先存起来再触发一次同步，判据与网页自算走同一条路。 */
window.__kbSetNative=function(px){kbNativePx=Number(px)||0;syncKeyboard();};

/* ── 聊天里直接发文件（相册 / 拍摄 / 录音都走这里）───────────────── */
async function sendChatFiles(files){
 const list=[...(files||[])].filter(Boolean);if(!list.length)return;
 try{
  const ids=[];
  for(const f of list)ids.push((await uploadFile(f)).id);
  await sendChat({content:'',date:today(),media:ids});
  await refresh();scrollChat();
  toast(list.length>1?`已发送 ${list.length} 个文件`:'已发送');
 }catch(e){toast(e.message||'发送失败');}
}
/* 录音：点一下开始，再点一下结束并直接发出去（不复用写记录的弹窗，聊天里要快） */
let chatRec=null,chatRecStream=null;
async function chatVoiceToggle(){
 if(chatRec&&chatRec.state==='recording'){chatRec.stop();return;}
 try{
  if(!navigator.mediaDevices?.getUserMedia||!window.isSecureContext)
   throw new Error('录音需要 https 环境，当前页面拿不到麦克风');
  chatRecStream=await navigator.mediaDevices.getUserMedia({audio:true});
  const mime=['audio/webm','audio/mp4','audio/ogg'].find(m=>window.MediaRecorder&&MediaRecorder.isTypeSupported(m));
  chatRec=new MediaRecorder(chatRecStream,mime?{mimeType:mime}:{});
  const chunks=[];
  chatRec.ondataavailable=e=>chunks.push(e.data);
  chatRec.onstop=async()=>{
   const form=$('#chat-form');if(form)form.classList.remove('recording');
   try{chatRecStream.getTracks().forEach(t=>t.stop());}catch{}
   const type=(chatRec.mimeType||'audio/webm').split(';')[0];
   const ext=type.includes('mp4')?'m4a':type.includes('ogg')?'ogg':'webm';
   if(!chunks.length)return toast('没有录到声音');
   toast('正在发送语音…');
   await sendChatFiles([new File(chunks,'语音.'+ext,{type})]);
  };
  chatRec.start();
  $('#chat-form')?.classList.add('recording');
  toast('正在录音，再点一次麦克风结束并发送');
 }catch(e){toast(e.message||'录音失败');}
}

/* ── 从相册选：铺满下半屏，多选 + 写一句，一次发出去 ──────────────────
   以前点一张就立刻发送，想发三张得开三次面板。现在点选只做"引用"（打勾 + 序号），
   底部还能写一句描述跟着一起发；半屏高度让缩略图一屏能看清更多。 */
let albumPickList=[],albumPickSel=[];
async function chatAlbumPick(){
 albumPickSel=[];
 let list=[];
 try{list=await api('/media/images?limit=300');}catch{}
 albumPickList=list;
 focusReturn=document.activeElement;
 $('#modal-root').innerHTML=`<div class="pick-overlay" id="pick-overlay"><section class="pick-sheet" role="dialog" aria-modal="true" aria-labelledby="pick-title">
  <header class="ps-head"><div><b id="pick-title">从相册选</b><small id="ps-count">${list.length?`相册里 ${list.length} 张`:'相册还是空的'}</small></div><button type="button" class="button soft small" id="ps-upload">上传</button><button type="button" class="icon-btn" data-action="close-modal" aria-label="关闭">${icon('close')}</button></header>
  <div class="ps-grid" id="ps-grid">${list.length?list.map(m=>`<button type="button" class="ps-cell" data-mid="${esc(m.id)}" aria-label="${esc(m.name||'照片')}"><img src="/media/${esc(m.id)}?preview=true" alt="" loading="lazy" decoding="async"><i></i></button>`).join(''):'<p class="meta">相册里还没有照片。先用上面的「上传」传一张，或者去相册页传。</p>'}</div>
  <div class="ps-foot">
   <div class="ps-picked" id="ps-picked"></div>
   <div class="ps-row"><input id="ps-caption" maxlength="200" placeholder="说点什么…（可以留空）" autocomplete="off"><button type="button" class="button primary" id="ps-send" disabled>发送</button></div>
  </div>
 </section></div>`;
 document.body.style.overflow='hidden';
 syncAlbumPick();
 const grid=$('#ps-grid');
 if(grid)grid.onclick=e=>{
  const cell=e.target.closest('[data-mid]');if(!cell)return;
  const mid=cell.dataset.mid,at=albumPickSel.indexOf(mid);
  if(at>=0)albumPickSel.splice(at,1);else albumPickSel.push(mid);
  syncAlbumPick();
 };
 const picked=$('#ps-picked');
 if(picked)picked.onclick=e=>{
  const chip=e.target.closest('[data-drop]');if(!chip)return;
  albumPickSel.splice(Number(chip.dataset.drop),1);syncAlbumPick();
 };
 $('#ps-send')?.addEventListener('click',sendAlbumPick);
 $('#ps-upload')?.addEventListener('click',()=>{closeModal();$('#chat-file')?.click();});
 $('#ps-caption')?.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();sendAlbumPick();}});
 /* 点面板外的暗色区域 = 取消（和别的弹窗一致） */
 $('#pick-overlay')?.addEventListener('click',e=>{if(e.target.id==='pick-overlay')closeModal();});
}
function syncAlbumPick(){
 const n=albumPickSel.length;
 $$('.ps-cell').forEach(c=>{
  const at=albumPickSel.indexOf(c.dataset.mid);
  c.classList.toggle('on',at>=0);
  const badge=c.querySelector('i');if(badge)badge.textContent=at>=0?String(at+1):'';
 });
 const picked=$('#ps-picked');
 if(picked)picked.innerHTML=albumPickSel.map((mid,i)=>`<button type="button" class="ps-chip" data-drop="${i}" aria-label="取消第 ${i+1} 张"><img src="/media/${esc(mid)}?preview=true" alt=""><span>${i+1}</span></button>`).join('');
 const cnt=$('#ps-count');
 if(cnt)cnt.textContent=n?`已选 ${n} 张`:(albumPickList.length?`相册里 ${albumPickList.length} 张`:'相册还是空的');
 const btn=$('#ps-send');
 if(btn){btn.disabled=!n;btn.textContent=n?`发送 ${n}`:'发送';}
}
async function sendAlbumPick(){
 if(!albumPickSel.length)return;
 const cap=($('#ps-caption')?.value||'').trim(),ids=albumPickSel.slice();
 const btn=$('#ps-send');if(btn)btn.disabled=true;
 try{
  await sendChat({content:cap,date:today(),media:ids});
  closeModal();
  await refresh();scrollChat();
  toast(ids.length>1?`已发送 ${ids.length} 张`:'已发送');
 }catch(e){toast(e.message||'发送失败');syncAlbumPick();}
}
/* ── 聊天气泡皮肤：两千多张图，分批画、选中先预览再落库 ────────────────
   图是 128×112 的整图（四角带装饰），前端靠 CSS border-image 切九宫格随
   内容拉伸，所以这里只管"挑哪一张"。两件事特意没做成即点即生效：
   ① 图底深浅差得远，深字压在紫气泡上根本看不见，得让人配着预览选字色；
   ② 一组的图有一千多张，全塞进 DOM 会卡，所以滚到底再画下一批。 */
let bpGroups=[],bpPack='',bpPick='',bpFg='dark',bpSwap=true,bpShown=0;
const BP_PAGE=90;
async function bubblePicker(){
 focusReturn=document.activeElement;
 bpPick=chatSkin();bpFg=chatSkinFg();bpSwap=chatSkinSwap();bpShown=0;bpGroups=[];
 const cur=bpPick?bpPick.split('/')[0]:'';
 $('#modal-root').innerHTML=`<div class="pick-overlay" id="bp-overlay"><section class="pick-sheet bp-sheet" role="dialog" aria-modal="true" aria-labelledby="bp-title">
  <header class="ps-head"><div><b id="bp-title">聊天气泡</b><small id="bp-count">正在读素材…</small></div><button type="button" class="icon-btn" data-action="close-modal" aria-label="关闭">${icon('close')}</button></header>
  <div class="bp-tabs" id="bp-tabs"></div>
  <div class="bp-preview" id="bp-preview"></div>
  <div class="bp-grid" id="bp-grid"><p class="meta">正在加载…</p></div>
  <div class="ps-foot">
   <div class="bp-fg"><span>字色</span><button type="button" data-fg="dark">深色字</button><button type="button" data-fg="light">浅色字</button><i>气泡图有深有浅，按这张图选</i></div>
   <label class="bp-swap"><input type="checkbox" id="bp-swap"${bpSwap?' checked':''}><span>左右互换</span><i>气泡的装饰朝哪边，看着别扭就勾一下</i></label>
   <div class="ps-row"><button type="button" class="button soft" id="bp-none">不用皮肤</button><button type="button" class="button primary" id="bp-apply">使用这个</button></div>
  </div>
 </section></div>`;
 document.body.style.overflow='hidden';
 $('#bp-overlay').onclick=e=>{
  if(e.target.id==='bp-overlay'){closeModal();return;}
  const pack=e.target.closest('[data-pack]');
  if(pack){if(pack.dataset.pack===bpPack)return;bpPack=pack.dataset.pack;renderBubbleTabs();renderBubbleGrid();return;}
  const cell=e.target.closest('[data-skin]');
  if(cell){bpPick=cell.dataset.skin;syncBubblePick();return;}
  const fg=e.target.closest('[data-fg]');
  if(fg){bpFg=fg.dataset.fg;syncBubblePick();}
 };
 $('#bp-none').onclick=()=>{bpPick='';syncBubblePick();};
 $('#bp-swap').onchange=e=>{bpSwap=e.target.checked;syncBubblePick();};
 $('#bp-apply').onclick=applyBubblePick;
 let data={groups:[]};
 try{data=await api('/bubbles');}catch(e){toast(e.message||'气泡素材读不出来');}
 bpGroups=data.groups||[];
 if(!bpGroups.length){
  $('#bp-grid').innerHTML='<p class="meta">服务器上还没有气泡素材。把图放进数据卷的 bubbles/ 目录，按包分文件夹即可。</p>';
  $('#bp-count').textContent='没有素材';renderBubbleTabs();syncBubblePick();return;
 }
 bpPack=bpGroups.some(g=>g.id===cur)?cur:bpGroups[0].id;
 renderBubbleTabs();renderBubbleGrid();syncBubblePick();
 const grid=$('#bp-grid');
 grid.onscroll=()=>{if(grid.scrollTop+grid.clientHeight>grid.scrollHeight-180)growBubbleGrid();};
}
function bpPackLabel(id,i){
 const m=/^p(\d+)$/.exec(id);
 return `第 ${m?m[1]:i+1} 组`;
}
function renderBubbleTabs(){
 const box=$('#bp-tabs');if(!box)return;
 box.innerHTML=bpGroups.map((g,i)=>`<button type="button" class="bp-tab${g.id===bpPack?' on':''}" data-pack="${esc(g.id)}" aria-pressed="${g.id===bpPack}">${bpPackLabel(g.id,i)}<i>${g.count}</i></button>`).join('');
}
function bpCells(items){
 return items.map(n=>`<button type="button" class="bp-cell" data-skin="${esc(bpPack)}/${esc(n)}" aria-label="气泡 ${esc(n)}"><img src="/api/bubbles/${esc(bpPack)}/${esc(n)}" alt="" loading="lazy" decoding="async"></button>`).join('');
}
function renderBubbleGrid(){
 const g=bpGroups.find(x=>x.id===bpPack),grid=$('#bp-grid');if(!grid)return;
 if(!g){grid.innerHTML='<p class="meta">这一组没有图。</p>';return;}
 bpShown=Math.min(BP_PAGE,g.items.length);
 grid.scrollTop=0;
 grid.innerHTML=bpCells(g.items.slice(0,bpShown));
 const total=bpGroups.reduce((n,x)=>n+x.count,0),cnt=$('#bp-count');
 if(cnt)cnt.textContent=`共 ${total} 张 · 这一组 ${g.count} 张`;
}
function growBubbleGrid(){
 const g=bpGroups.find(x=>x.id===bpPack),grid=$('#bp-grid');
 if(!g||!grid||bpShown>=g.items.length)return;
 const from=bpShown;
 bpShown=Math.min(bpShown+BP_PAGE,g.items.length);
 grid.insertAdjacentHTML('beforeend',bpCells(g.items.slice(from,bpShown)));
 syncBubbleCells();
}
function syncBubbleCells(){
 const on=bpPick;
 $$('#bp-grid [data-skin]').forEach(c=>c.classList.toggle('on',!!on&&c.dataset.skin===on));
}
function syncBubblePick(){
 syncBubbleCells();
 const pv=$('#bp-preview');
 if(pv){
  const on=!!bpPick,cls=(on?' skinned':'')+(bpFg==='light'?' light':'');
  /* 预览必须跟聊天页用同一套左右规则，否则"预览看着对、进去反了" */
  const mirror=on?bpPick.replace(/\.png$/,'-r.png'):'';
  const left=bpSwap?mirror:bpPick, right=bpSwap?bpPick:mirror;
  const style=on?` style="--skin:url('/api/bubbles/${esc(left)}');--skin-r:url('/api/bubbles/${esc(right)}')"`:'';
  pv.innerHTML=`<div class="bp-preview-row"><div class="bp-bubble${cls}"${style}>今天下班去买菜，回来给你做番茄牛腩，路上有点堵</div></div>`
   +`<div class="bp-preview-row mine"><div class="bp-bubble mine${cls}"${style}>好呀，路上慢点</div></div>`;
 }
 $$('#bp-overlay [data-fg]').forEach(b=>b.classList.toggle('on',b.dataset.fg===bpFg));
 const ap=$('#bp-apply');
 if(ap)ap.textContent=bpPick?'使用这个':'用默认气泡';
}
async function applyBubblePick(){
 const s=state.me.space||{},btn=$('#bp-apply');
 if(btn)btn.disabled=true;
 try{
  await put('/space',{...s,chat_bubble:bpPick||'',chat_bubble_fg:bpFg,chat_bubble_swap:bpSwap});
  await refresh();closeModal();
  toast(bpPick?'气泡换好了，两个人都看得见':'已换回默认气泡');
 }catch(e){toast(e.message||'保存失败');}
 finally{if(btn)btn.disabled=false;}
}
/* ── 点开一条位置消息：先想办法唤起高德 App ──────────────────────────
   原来整张卡是一个 target=_blank 的链接，点下去直接切到浏览器看网页地图，
   在 App 里等于"跳出恋爱空间"。现在的顺序：
   Android → intent://（装了就直开高德，没装由 Chrome/WebView 内核按
   browser_fallback_url 自己回落到网页）；iOS → iosamap://；
   其它/都失败 → 1.4 秒后在本窗口打开 uri.amap.com（callnative=1，网页自己也会再试一次）。
   "唤起来了"的判断：页面被切到后台（visibilitychange / pagehide）。 */
function openMap(lat,lng,name){
 const nm=name||'我们的位置';
 const web='https://uri.amap.com/marker?position='+lng+','+lat
  +'&name='+encodeURIComponent(nm)+'&coordinate=gaode&callnative=1&src=love-space';
 const ua=navigator.userAgent||'';
 if(!/android|iphone|ipad|ipod|harmony|mobile/i.test(ua)){window.location.href=web;return;}
 const q='sourceApplication=LoveSpace&poiname='+encodeURIComponent(nm)+'&lat='+lat+'&lon='+lng+'&dev=0';
 let gone=false;
 const mark=()=>{gone=true;};
 document.addEventListener('visibilitychange',mark);
 window.addEventListener('pagehide',mark);
 const timer=setTimeout(()=>{
  document.removeEventListener('visibilitychange',mark);
  window.removeEventListener('pagehide',mark);
  if(gone||document.hidden)return;
  window.location.href=web;
 },1400);
 void timer;
 if(/android|harmony/i.test(ua)){
  /* 两条路各有各的道理：
     - APK 里（WebView）走 androidamap:// 直 scheme，Capacitor 的 WebViewClient 会把
       非 http 的地址当外部 Intent 拉起，比 intent:// 更稳；
     - 浏览器里走 intent://，因为只有 Chrome 认 #Intent; 里的 browser_fallback_url，
       没装高德时会自己回落到网页地图，而不是丢一个"无法打开"的错误页。 */
  const scheme='androidamap://viewMap?'+q;
  window.location.href=isNativeApp()
   ?scheme
   :'intent://viewMap?'+q+'#Intent;scheme=androidamap;package=com.autonavi.minimap;S.browser_fallback_url='+encodeURIComponent(web)+';end';
 }else{
  window.location.href='iosamap://viewMap?'+q;
 }
}
/* 位置：浏览器定位拿经纬度，作为一条 location 消息发出去 */
function chatLocate(){
 if(!navigator.geolocation)return toast('这台设备不支持定位');
 if(!window.isSecureContext)return toast('定位只允许在 https 页面使用，当前连接不是安全上下文');
 const p=$('#chat-fn');if(p)p.hidden=true;
 toast('正在获取位置…');
 /* 首次使用会弹系统权限框，用户点「允许」之后第一次回调仍可能是 PERMISSION_DENIED
    （权限刚落、WebView 还没接住），所以对 code=1 给一次自动重试。 */
 let retried=false;
 const tips={1:'位置权限没给：到「设置 → 应用 → 恋爱空间 → 权限」里打开「位置」，再试一次',
             2:'暂时定不到位置——室内、地下室或没开 GPS 都会这样，换个地方再试',
             3:'定位超时了，再点一次'};
 const attempt=()=>navigator.geolocation.getCurrentPosition(async pos=>{
  try{
   const lat=Math.round(pos.coords.latitude*1e5)/1e5,lng=Math.round(pos.coords.longitude*1e5)/1e5;
   await sendChat({content:'',date:today(),media:[],location:{lat,lng}});
   await refresh();scrollChat();toast('位置已发送');
  }catch(e){toast(e.message||'发送失败');}
 },err=>{
  if(err&&err.code===1&&!retried){retried=true;setTimeout(attempt,1200);return;}
  toast(tips[err&&err.code]||('定位失败：'+(err&&err.message)||'未知原因'));
 },{enableHighAccuracy:true,timeout:8000,maximumAge:300000});
 attempt();
}
/* 表情面板：内嵌于输入栏上方（输入框始终可见），点击按钮开合；点 emoji 只插入文本不弹键盘 */
function stickerPanel(){
 const dock=$('#sticker-dock');if(!dock)return;
 if(!dock.hidden){dock.hidden=true;return;}
 const fn=$('#chat-fn');if(fn)fn.hidden=true;
 state.stickerTab=state.stickerTab||'cute';
 dock.innerHTML=`<div class="sticker-tabs" id="sticker-tabs"></div><div class="sticker-body" id="sticker-body"></div>`;
 dock.hidden=false;
 if(document.activeElement&&document.activeElement.blur)document.activeElement.blur();
 renderStickerTabs();
}
function renderStickerTabs(){
 const box=$('#sticker-tabs');if(!box)return;
 const tabs=[['cute','💕 日常'],['spicy','🔥 涩涩'],['mine','🌟 我的']].concat(STICKER_PACKS.map(p=>[p.id,p.label]));
 box.innerHTML=tabs.map(([id,label])=>`<button data-action="sticker-tab" data-id="${id}" class="${state.stickerTab===id?'active':''}">${label}</button>`).join('');
 $('#sticker-body').innerHTML=stickerTabHTML(state.stickerTab);
 lazyStickerVideos();
}
function stickerTabHTML(tab){
 if(tab==='mine'){
  const list=myStickers();
  return `${list.length?`<div class="sticker-grid mine">${list.map(s=>`<button type="button" class="sticker-cell" data-action="sticker-send" data-id="${s.mid}" aria-label="发送表情包"><img loading="lazy" src="/media/${s.mid}?preview=true" alt="${esc(s.name||'表情包')}"><span class="sticker-del" data-action="sticker-del" data-id="${s.mid}" aria-label="删除这张表情包">×</span></button>`).join('')}</div>`:`<p class="meta meta-center" style="padding:26px 0 10px">还没有专属表情包<br><small>点下面收第一张，一点就能发给 TA</small></p>`}<label class="sticker-add">＋ 添加表情包<input type="file" id="sticker-file" accept="image/jpeg,image/png,image/webp,image/gif" hidden></label><p class="small-note" style="text-align:center;margin-top:8px">只存于本机列表 · 图片保存在你们的空间里</p>`;
 }
 const pack=STICKER_PACKS.find(p=>p.id===tab);
 if(pack){
  const cells=Array.from({length:pack.count},(_,i)=>{
   const path=`/static/stickers/${pack.dir}/${i}.${pack.ext}`;
   const inner=pack.ext==='webm'?`<video muted loop playsinline data-src="${path}"></video>`:`<img src="${path}" loading="lazy" alt="贴纸">`;
   return `<button type="button" class="sticker-cell" data-action="sticker-pack-send" data-id="${path}" aria-label="发送贴纸">${inner}</button>`;
  }).join('');
  return `<div class="sticker-grid pack">${cells}</div><p class="small-note" style="text-align:center;margin-top:10px">点一下，直接发给 TA</p>`;
 }
 const list=tab==='spicy'?SPICY_EMOJI:CUTE_EMOJI;
 return `<div class="sticker-grid">${list.map(em=>`<button type="button" class="sticker-cell" data-action="sticker-emoji" data-id="${em}" aria-label="插入表情">${em}</button>`).join('')}</div><p class="small-note" style="text-align:center;margin-top:10px">${tab==='spicy'?'这些只属于你们两个人的小秘密 🔒':'点一下，就能打进输入框'}</p>`;
}
/* 视频贴纸懒加载：滚进可视区才加载 src 并循环播放，滚出即暂停，避免几十个视频同时解码 */
function lazyStickerVideos(){
 const root=$('#sticker-body');
 // 每次渲染贴纸面板都会重建 DOM，旧的 observer 必须先断开：否则切几次标签页就
 // 攒下几十个 observer 一起回调，白耗主线程，还会让已销毁的视频继续被 observe
 if(root&&root._stickerObserver){root._stickerObserver.disconnect();}
 const io=new IntersectionObserver(entries=>{
  entries.forEach(en=>{
   const v=en.target;
   if(en.isIntersecting){
    if(v.dataset.src&&!v.getAttribute('src'))v.src=v.dataset.src;
    v.play().catch(()=>{});
   }else{v.pause();}
  });
 },{root:root||null,rootMargin:'160px'});
 if(root)root._stickerObserver=io;
 document.querySelectorAll('.sticker-cell video[data-src]').forEach(v=>io.observe(v));
}
