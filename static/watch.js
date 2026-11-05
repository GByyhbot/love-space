'use strict';

/* ── 一起看 / 在线片源（自 app.js 拆出）────────────────────────────────
   放映区、进度同步、片源四层浏览（组件 → 首页 → 海报墙 → 选集）。

   与 app.js 共享同一个全局作用域（两者都是 classic script，没走 ES module），
   所以 $ / esc / api / state / icon / openModal 直接用，不需要 import。
   之所以不用 module：`document.currentScript` 在 module 里是 null，而 app.js
   靠它取自己的 ?v= 去注册 service worker，一改就会让旧 worker 被 CF 缓存 4 小时。

   加载顺序：本文件必须排在 app.js **之前**。app.js 末尾的 boot() 会调用
   watch*，顺序反了就是 ReferenceError（defer 保证按文档顺序执行）。
   新增本类文件要同步 static/sw.js 的 CORE 预热清单与 network-first 规则。 */

/* ── 一起看（竖屏上下分屏，带进度同步）────────────────────────
   上半放映区、下半聊天区。

   同步只传「时间轴」，不传画面。之所以能这样，是因为片源来自服务器媒体
   `/media/<id>`：两个人拿到的是同一个文件，时长一致，对齐才有意义。
   （选本机文件也留着，但那只是"各自打开同一部片"，客户端无法验证是不是同一部。）

   · 同步是**事件触发**的，不是实时轮询：只有「用户主动做了」才上报 ——
     拖进度条、点播放/暂停、选片/切集/换组件。播放过程中一个字节都不发，
     对方那侧也没有轮询在跑（以前每 2.5 秒拉一次 /api/watch，手机上很费电费流量）。
   · 对方靠 SSE 收到「一起看状态变了」的信号，才来拉一次 `/api/watch`；
     服务端按 updated 把 position 往后推算，所以拉到的就是当下的进度。
   · 程序性动作（换源、跟对方对齐）不会当成用户操作推回去，
     否则两边会对着推、形成死循环。
   · 代价：不再有持续的进度校正，长时间播放两边会慢慢漂移；
     状态带上留了「对齐」按钮，拖一下进度条或点一下就能拉齐。
   · 首次进页面只定位不自动出声 —— 浏览器禁止无手势自动播放，强行 play 会被拦；
     昨天看到一半的进度今天进来自动响起来也不合适，所以给一个「点一下继续」。 */
let watchObjectUrl=null, watchTimer=null, watchLastUpdated=0, watchApplying=false, watchFirstPoll=true;
/* 上报闸门：把「用户主动做的」和「程序自己做的」分开。
   watchMuteUntil —— 程序性动作的静音窗口（换源、跟对方对齐）；
   watchSeekTarget —— 程序性 seek 的目标位置，用来精确识别"这次 seek 不是用户拖的"；
   watchExpectKey —— 本端刚选的片源，等它挂上期间别被自己触发的同步事件重复换源。 */
let watchMuteUntil=0, watchSeekTarget=null, watchPushTimer=null, watchPushPending=false, watchExpectKey='';
function watchMute(ms){watchMuteUntil=Math.max(watchMuteUntil,Date.now()+(ms||1000));}
function watchMuted(){return Date.now()<watchMuteUntil;}

function watchVideo(){return $('#watch-video');}
/* hls.js 挂在 video 上时元素本身没有 src 属性（画面走 MSE 的 blob），
   光看 getAttribute('src') 会误判成「没有片源」，播放状态也就不上报了。 */
let watchHls=null,watchLoadingSrc=false,watchSrcSeq=0;
function watchHasSrc(){
 const v=watchVideo();
 return !!(v&&(v.getAttribute('src')||watchHls||watchLoadingSrc));
}
function watchDestroyHls(){
 if(watchHls){try{watchHls.destroy();}catch{}watchHls=null;}
}
/* HLS 片源：能跑 MSE 的内核交给 hls.js；Safari 这类原生就认 m3u8 的，
   直接把改写后的播放列表塞给 <video>。老内核两种都不支持的会给明确提示。 */
function watchMountHls(v,url){
 watchDestroyHls();
 if(typeof Hls==='undefined'||!Hls.isSupported()){v.src=url;return;}
 const hls=new Hls({enableWorker:false,maxBufferLength:15,backBufferLength:15});
 watchHls=hls;
 hls.on(Hls.Events.MEDIA_ATTACHED,()=>hls.loadSource(url));
 hls.on(Hls.Events.ERROR,(evt,data)=>{
  if(!data||!data.fatal)return;
  toast(data.type===Hls.ErrorTypes.NETWORK_ERROR
   ?'片源网络出错，换个组件或重新选一次集'
   :'这个片源当前浏览器播不了，换个组件看看');
 });
 hls.attachMedia(v);
}

function watchPage(){
 const chats=chatRows(true);
 return `<section class="watch-page">
  <header class="watch-head">
   <button class="icon-btn" data-action="watch-back" aria-label="返回聊天">${icon('back')}</button>
   <div><h3>一起看</h3><small id="watch-sub">边看边聊 · 选一部一起看</small></div>
   <button class="button soft small" data-action="watch-pick">${icon('film')} 选片源</button>
  </header>
  <div class="watch-stage" id="watch-stage">
   <video id="watch-video" class="watch-video" playsinline controls hidden></video>
   <div class="watch-empty" id="watch-empty">
    <div class="we-art"><span class="we-ring"></span><span class="we-icon">${icon('film')}</span></div>
    <b id="watch-empty-title">还没有片源</b>
    <small id="watch-empty-hint">从相册里挑一段视频，两个人看的是同一个文件，进度自动对齐</small>
    <button class="button primary small" data-action="watch-pick">从相册选视频</button>
    <div class="we-tips"><span>进度自动对齐</span><span>随时换片</span></div>
   </div>
   <button type="button" class="watch-join" id="watch-join" data-action="watch-join" hidden>点一下继续播放</button>
  </div>
  <div class="watch-chat">
   <div class="watch-now" id="watch-now" hidden></div>
   <div class="watch-log" id="watch-log" aria-live="polite">${chats}</div>
   <form id="watch-form" class="chat-compose">
    <div class="compose-field"><textarea id="watch-text" rows="1" maxlength="20000" placeholder="边看边说" aria-label="聊天内容" autocomplete="off" enterkeyhint="send"></textarea></div>
    <button class="compose-send" type="submit" aria-label="发送消息">${icon('send')}</button>
   </form>
   <input id="watch-file" type="file" accept="video/*" hidden>
  </div>
 </section>`;
}
function watchScroll(){const log=$('#watch-log');if(log)log.scrollTop=log.scrollHeight;}

/* 把状态画到头部副标题和空状态上。片源没挂上时，这里就是唯一告诉
   "TA 选了哪部" 的地方，否则对方只会看到一句"还没有片源"。 */
/* 相册导出的文件名常常就是一串数字（1000028599.mp4），直接当片名摆出来既难看、
   也分不清是哪一段，一律改成中性叫法 —— 列表里靠下面的日期区分。 */
function watchName(raw){
 const n=String(raw||'').replace(/\.[^.]+$/,'').trim();
 return /^[\d\s._-]*$/.test(n)?'':n;
}

function watchRenderStatus(st){
 st=st||{};
 const sub=$('#watch-sub'), t=$('#watch-empty-title'), h=$('#watch-empty-hint');
 /* 短剧的 title 只存剧名，集数单独存；展示时拼成「剧名 · 第N集」 */
 const name=(watchName(st.title)||'一段视频')+(st.drama_id&&st.drama_ep?` · 第${st.drama_ep}集`:'');
 if(sub){
  sub.textContent=st.title?`${st.playing?'一起看着':'暂停中'} · ${name}`:'边看边聊 · 选一部一起看';
  sub.classList.toggle('live',!!(st.title&&st.playing));
 }
 /* 播放区和聊天区之间给一条「正在看」的状态带：有片源时两栏不再靠一条细线硬切，
    也能一眼看到对方是播着还是暂停了。内容不变就不重绘，避免 2.5s 轮询闪一下。 */
 const now=$('#watch-now');
 if(now){
  const label=st.title?`${watchName(st.title)||'一段视频'}${st.drama_id&&st.drama_ep?` · 第${st.drama_ep}集`:''}`:'';
  /* 状态带：不再有持续的进度校正，所以文案不说"进度自动对齐"。
     对方在操作时给一个「对齐」按钮 —— 长时间播放会慢慢漂移，点一下就拉齐。 */
  const mine=!st.by||st.by===state.me.user.id;
  const tip=st.playing?(mine?'正在看 · 你一操作就同步给 TA':'TA 在看 · 你一操作就跟上')
                      :'暂停中，点播放就能一起继续';
  const html=label?`<span class="wn-badge${st.playing?' live':''}">${icon('film')}</span>
   <span class="wn-text"><b>${esc(label)}</b><small>${tip}</small></span>
   ${(!mine&&label)?`<button type="button" class="wn-sync" data-action="watch-align" title="把进度拉到 TA 的位置">${icon('arrow')}对齐</button>`:''}
   <span class="wn-tag">${st.playing?'在播':'已暂停'}</span>`:'';
  if(now.innerHTML!==html)now.innerHTML=html;
  now.hidden=!label;
 }
 if(t&&!watchHasSrc()){
  const mine=st.by===state.me.user.id;
  t.textContent=st.title?`${mine?'你':(st.by?person(st.by).name:'TA')}选了《${name}》`:'还没有片源';
  h.textContent=st.title?'片源已经就位，点播放就能一起开始':'从相册里挑一段视频，两个人看的是同一个文件，进度自动对齐';
 }
}

/* 片源有三种：相册媒体、在线片源某一集、本机文件。srcKey 记「当前挂的是哪一版」，
   轮询时比对它就能发现对方换了片或换了集，不用去 string 比 src（在线片源的地址每次都带新签名）。
   在线片源还分 mp4 / HLS：先问后端这一集是什么格式，再决定用 <video> 还是 hls.js。 */
async function watchSetSource(opts){
 const v=watchVideo();if(!v)return;
 const seq=++watchSrcSeq;
 /* 换源会触发 emptied/pause/loadedmetadata 一串事件，还会把 currentTime 归零。
    静音这一小段时间，别把「换片」误报成「TA 暂停了」或者「进度归零了」。 */
 watchMute(1400);
 /* 换源会触发 emptied/pause，别让这些事件把「暂停了」的假状态推给对方 */
 watchLoadingSrc=true;
 try{
  watchDestroyHls();
  if(watchObjectUrl){URL.revokeObjectURL(watchObjectUrl);watchObjectUrl=null;}
  v.removeAttribute('src');v.load();   // readyState 归零，轮询挂的 loadedmetadata 才会命中新源
  v.hidden=false;
  const empty=$('#watch-empty');if(empty)empty.hidden=true;
  if(opts.media){
   v.dataset.srcKey='m:'+opts.media;
   v.src='/media/'+opts.media;
  }else if(opts.drama){
   const d=opts.drama;
   const key=`d:${d.src}:${d.prov}:${d.id}:${d.ep}`;
   v.dataset.srcKey=key;
   const path=`/dramas/${encodeURIComponent(d.src)}/${encodeURIComponent(d.prov)}/`+
              `${encodeURIComponent(d.id)}`;
   const url=`/api${path}/stream/${d.ep}`;
   let type='mp4';
   try{
    const info=await api(`${path}/source/${d.ep}`);
    type=(info&&info.type)||'mp4';
   }catch(e){toast(e.message||'这一集暂时打不开');}
   /* 等探测这会儿里对方可能又换了片，别把旧结果挂到新 srcKey 上 */
   const cur=watchVideo();
   if(!cur||cur.dataset.srcKey!==key||seq!==watchSrcSeq)return;
   if(type==='hls')watchMountHls(cur,url);else cur.src=url;
  }else{
   v.dataset.srcKey='local';
   watchObjectUrl=URL.createObjectURL(opts.file);
   v.src=watchObjectUrl;
  }
  watchFitStage();
 }finally{
  setTimeout(()=>{if(seq===watchSrcSeq)watchLoadingSrc=false;},60);
 }
}

/* 播放区高度跟着视频自身比例走。固定五五分屏时，横屏片子在 48% 高的框里用 contain
   缩放，上下会各留一整条黑边，看着像播放器没加载好。这里按 videoWidth/videoHeight
   算出真实高度，只保留一条上限：别让长片把下面的聊天区挤没。
   横过来拿手机时走左右分栏（见 style.css），高度由 flex 撑满，不再写死。 */
const WATCH_SIDE_BY_SIDE='(orientation:landscape) and (max-height:560px)';
function watchFitStage(){
 const v=watchVideo(),st=$('#watch-stage');if(!st)return;
 const w=st.clientWidth;
 const vw=v&&v.videoWidth,vh=v&&v.videoHeight;
 /* 没片源或元数据还没到：清掉内联高度，交回 CSS 的默认分屏 */
 if(!w||!vw||!vh){st.style.height='';return;}
 if(window.matchMedia&&window.matchMedia(WATCH_SIDE_BY_SIDE).matches){st.style.height='';return;}
 const box=$('#page');
 const pageH=(box&&box.clientHeight)||window.innerHeight;
 const h=Math.round(w*vh/vw);
 /* 竖屏片子（短剧基本都是 9:16）按 62% 卡会左右各留一大条黑边，
     放宽到「只给聊天区留 240」；横屏片子照旧 62%，够看又不挤聊天。 */
 const portrait=vh>vw;
 const limit=portrait?Math.max(Math.round(pageH*0.62),pageH-240):Math.round(pageH*0.62);
 st.style.height=Math.max(96,Math.min(h,limit))+'px';
}

async function watchPush(){
 const v=watchVideo();
 if(!v||(!v.getAttribute('src')&&!watchHls)||watchLoadingSrc)return;
 const body={position:v.currentTime,playing:!v.paused};
 if(Number.isFinite(v.duration))body.duration=v.duration;
 try{
  const cur=await api('/watch',{method:'PUT',body:JSON.stringify(body)});
  state.watch=cur;watchLastUpdated=Number(cur.updated)||0;
  watchRenderStatus(cur);
 }catch{}
}

/* 唯一的上报入口：只有「用户主动做了」才允许推给对方。
   reason='play' | 'pause' | 'seek'。
   两道闸门：
     ① watchMuted() —— 程序性动作的静音窗口（换源、跟对方对齐）；
     ② watchSeekTarget —— 程序性 seek 的目标位置；命中就说明这次 seek 不是用户拖的。
   拖进度条时浏览器可能连着抛好几次 seeked，400ms 内合并成一条，别把请求刷成一片。 */
function watchReport(reason){
 if(watchApplying||watchMuted())return;
 if(reason==='seek'&&watchSeekTarget!=null){
  const v=watchVideo();
  const same=v&&Math.abs((Number(v.currentTime)||0)-watchSeekTarget)<0.4;
  watchSeekTarget=null;
  if(same)return;
 }
 if(watchPushTimer){watchPushPending=true;return;}
 watchPush();
 watchPushTimer=setTimeout(()=>{
  watchPushTimer=null;
  if(watchPushPending){watchPushPending=false;watchPush();}
 },400);
}

function watchBindVideo(){
 const v=watchVideo();if(!v)return;
 /* 用属性赋值而不是 addEventListener：整块 DOM 每次换页都会重画，
    属性赋值天然覆盖上一次的绑定，不会越绑越多。 */
 v.onplay=()=>watchReport('play');
 v.onpause=()=>watchReport('pause');
 v.onseeked=()=>watchReport('seek');
 /* 短剧一集只有两三分钟，播完自己接下一集，不用每次都回去点 */
 v.onended=()=>{if(!watchApplying)watchNextEpisode();};
 /* 元数据到手才知道片子的实际比例，这时再定高度 */
 v.onloadedmetadata=()=>watchFitStage();
}

function showWatchJoin(){const b=$('#watch-join');if(b)b.hidden=false;}
function hideWatchJoin(){const b=$('#watch-join');if(b)b.hidden=true;}

function watchJoin(){
 const v=watchVideo();if(!v)return;
 hideWatchJoin();
 v.play().catch(()=>showWatchJoin());
}

/* 拉一次服务端状态并对齐过来。
   触发时机只有四种：① 进入页面 ② SSE 通知「一起看状态变了」
   ③ 低频兜底轮询 ④ 手动点「对齐」。没有事件的时候一个请求都不发。
   force=true 时不看 updated，硬对齐一次（手动对齐按钮用）。 */
async function watchPull(force){
 if(state.page!=='watch'){stopWatchSync();return;}
 let st;try{st=await api('/watch');}catch{return;}
 state.watch=st;
 watchRenderStatus(st);
 const v=watchVideo();if(!v)return;
 /* 对方换了片（或换了一集/换了个组件）就跟过去；本机文件是我自己选的，服务端没有 media,
    这时 want 为空，保持原样别把本地视频顶掉。
    want===watchExpectKey：本端刚点的片还在挂载途中，别被自己触发的同步再换一次源。 */
 const want=st.drama_id
  ?`d:${st.drama_src||''}:${st.drama_provider||''}:${st.drama_id}:${st.drama_ep||1}`
  :(st.media?`m:${st.media}`:'');
 if(want&&v.dataset.srcKey!==want&&want!==watchExpectKey){
  /* 提前压住回写：换源会清空 video，那串 emptied/pause 不该被当成「TA 暂停了」 */
  watchApplying=true;watchMute(1600);
  if(st.drama_id)watchSetSource({drama:{src:st.drama_src,prov:st.drama_provider,
   id:st.drama_id,ep:st.drama_ep||1}});
  else watchSetSource({media:st.media});
  /* 换源后这一轮就到此为止：位置按服务端的来，再从下一条快照开始正常同步，
     否则同一个 updated 会被应用两次、跟当前这次 seek 打架。 */
  watchLastUpdated=Number(st.updated)||0;
  const seek=()=>{try{v.currentTime=Math.max(0,Number(st.position)||0);}catch{}};
  if(v.readyState>=1)seek();else v.addEventListener('loadedmetadata',seek,{once:true});
  setTimeout(()=>{watchApplying=false;},800);
  if(st.playing)v.play().then(hideWatchJoin).catch(()=>showWatchJoin());
  return;
 }
 if(!watchHasSrc())return;

 const upd=Number(st.updated)||0;
 const pos=Math.max(0,Number(st.position)||0);

 if(watchFirstPoll){
  watchFirstPoll=false;watchLastUpdated=upd;
  if(pos>0.5){watchApplying=true;watchSeekTarget=pos;watchMute(900);
   try{v.currentTime=pos;}catch{}setTimeout(()=>{watchApplying=false;},800);}
  if(st.playing)showWatchJoin();
  return;
 }
 if(!force&&upd<=watchLastUpdated)return;
 watchLastUpdated=upd;
 if(st.by===state.me.user.id)return;   // 自己刚上报的快照，别自己跟自己
 watchApplying=true;watchMute(900);
 try{
  /* 播放中容忍 1.5 秒：频繁 seek 会打断解码，画面一顿一顿的，而人对 1.5 秒内的
     不同步几乎无感。暂停时就该停在同一帧，收紧到 0.5 秒 —— 这时候 seek 没有卡顿成本。 */
  const tol=st.playing?1.5:0.5;
  if(Math.abs(v.currentTime-pos)>tol){watchSeekTarget=pos;try{v.currentTime=pos;}catch{}}
  if(st.playing&&v.paused){try{await v.play();hideWatchJoin();}catch{showWatchJoin();}}
  else if(!st.playing&&!v.paused)v.pause();
 }finally{
  setTimeout(()=>{watchApplying=false;},800);
 }
}

function startWatchSync(){
 stopWatchSync();
 if(state.page!=='watch')return;
 watchFirstPoll=true;
 watchExpectKey='';
 watchBindVideo();
 watchRenderStatus(state.watch||{});
 watchPull();
 /* 兜底轮询：以前每 2.5 秒拉一次（实时同步），现在降到 15 秒，只负责在
    SSE 断线或事件漏了的时候把状态收敛回来。同步主通道是 SSE 的状态变更事件，
    没有事件时这一条也不会白发。 */
 watchTimer=setInterval(()=>watchPull(),15000);
 window.addEventListener('resize',watchFitStage);
 window.addEventListener('orientationchange',watchFitStage);
}
function stopWatchSync(){
 /* 离开「一起看」后整块 DOM 会被替换，但 hls.js 还 attach 在旧 <video> 的 JS 引用上，
    不 destroy 就会在后台继续拉分片烧流量（最多等下一轮轮询走到这里）。 */
 if(state.page!=='watch')watchDestroyHls();
 if(watchTimer){clearInterval(watchTimer);watchTimer=null;}
 window.removeEventListener('resize',watchFitStage);
 window.removeEventListener('orientationchange',watchFitStage);
}

/* 选片源：相册视频（同源，能真同步）/ 在线片源（走本站代理）/ 本机文件（退路）。
   在线片源是「服务 + 组件」两级：服务是 happy-capy 这类组件聚合器的地址，主人自己加；
   组件是那台服务代理的内容源，主人自己勾。前端只认「服务/组件/内容 id/集号」——
   直链带签名、二十来小时就过期，交给服务端每次现换。 */
/* 在线片源分四层：sources=组件卡列表（在线片源主页）/ home=某个组件按分类分区的
   片库 / list=某分类的完整海报墙 / detail=选集页。album tab 不走 view。 */
const WATCH_PICK={tab:'album',view:'sources',svc:'',prov:'',cat:'',page:1,q:'',
 videos:[],dramas:[],detail:null,catalog:null,openSvc:'',loading:false,error:'',
 /* filter = 组件卡页的关键词过滤（只在本地筛，不发请求）
    showHidden = 是否显示被「整理」隐藏掉的组件
    pageCount/total = 上游给的分页信息，决定「换一批」还能不能点 */
 filter:'',showHidden:false,pageCount:0,total:0,
 home:{rows:[],loading:false,error:''},recent:[]};

/* ── 组件索引：所有组件相关视图都从这一个地方取数据 ────────────────────
   上游清单（/drama-sources）+ 本地整理（别名/标签/隐藏/排序）在这里合成一张
   扁平表。以前 watchGroups / watchGroup / watchEnabledKeys / watchSourcesInner
   各走一遍 services[].providers[] 嵌套循环，想加一个维度就要改四处、还容易改漏
   （比如「隐藏」只在管理页生效、选片页照旧显示）。现在只有一个入口。 */
function watchIndex(){
 const p=WATCH_PICK;
 const out=[];
 ((p.catalog||{}).services||[]).forEach(s=>{
  (s.providers||[]).forEach((one,i)=>{
   const key=one.key||(s.id+':'+one.id);
   out.push({
    key,svc:s.id,svcName:s.name,svcOnline:!!s.online,svcError:s.error||'',
    prov:one.id,title:one.title||one.id,
    name:one.name||one.alias||one.title||one.id,alias:one.alias||'',
    tag:one.tag||'',hidden:!!one.hidden,
    order:(typeof one.order==='number'?one.order:null),idx:i,
    cats:one.categories||[],caps:one.caps||[],version:one.version||'',
    health:one.health||{},enabled:!!one.enabled,
    /* net = 上游诊断快照里的网络模式（服务器直连 / 手机端直连 / 建议代理 …）。
       它不是「这个组件好没好」，而是「该由谁去连源站」—— 拿它当可用性判断
       会误伤手机端直连的组件（服务端初筛不过，手机上照样能播）。 */
    net:one.net||{}});
  });
 });
 return out;
}

/* 已启用的组件，摊平成一维，方便做切换条 */
function watchGroups(){return watchIndex().filter(x=>x.enabled);}

/* 当前选中的组件。找不到就回落到第一个启用的 —— 但绝不在「不可见」的项上
   静默回落（以前回落用的是 enabled 列表，选中项被隐藏后会串到别家去）。 */
function watchGroup(){
 const p=WATCH_PICK;
 const hit=watchIndex().find(x=>x.svc===p.svc&&x.prov===p.prov);
 if(hit)return hit;
 return watchGroups()[0]||null;
}

function watchEnabledKeys(){return watchGroups().map(x=>x.key);}

/* 界面上要显示的一批：默认滤掉隐藏项，按「本地排序 → 上游顺序」稳定排列。
   注意不按 enabled 排序：勾选后卡片会当场换位置，手指下面的东西就跑了。 */
function watchVisible(){
 const q=String(WATCH_PICK.filter||'').trim().toLowerCase();
 const rows=watchIndex().filter(x=>WATCH_PICK.showHidden||!x.hidden);
 if(!q)return rows.sort(watchSort);
 return rows.filter(x=>(x.name+' '+x.title+' '+x.prov+' '+x.tag).toLowerCase().includes(q))
  .sort(watchSort);
}
function watchSort(a,b){
 const ao=a.order===null?9999:a.order,bo=b.order===null?9999:b.order;
 if(ao!==bo)return ao-bo;
 if(a.svc!==b.svc)return 0;      /* 跨服务保持上游给的块顺序 */
 return a.idx-b.idx;
}

async function watchCatalog(refresh){
 try{return await api('/drama-sources'+(refresh?'?refresh=1':''));}catch{return null;}
}

async function watchPick(){
 const p=WATCH_PICK;
 p.tab='album';p.view='sources';p.page=1;p.q='';p.cat='';p.detail=null;
 p.svc='';p.prov='';p.dramas=[];p.home={rows:[],loading:false,error:''};
 p.filter='';p.showHidden=false;p.pageCount=0;p.total=0;
 try{p.videos=await api('/media/videos');}catch{p.videos=[];}
 watchPickOpen();
 p.catalog=await watchCatalog();
 const g=watchGroups()[0];
 if(g){p.svc=g.svc;p.prov=g.prov;}
 wsSafeOpen();
}

/* 片源浏览统一裹一层影院外壳：openModal() 看见这个 class 就把弹窗切成全屏深色。
   顶部/切换条/底栏都 flex:none，中间的片单区自己滚动，长列表不会把标题顶出屏幕。 */
function wsPage(inner,view){return `<div class="ws-cinema" data-view="${view||''}">${inner}</div>`;}
/* 影院层是多级页面：异步请求回来时主人可能已经按了返回、点了别的组件。
   用 data-view 比对「DOM 现在显示哪一层」和「状态期望哪一层」，不一致就不重绘，
   免得慢请求把当前页盖掉（比只判 .src-manage 更通用）。 */
function wsExpectedView(){return WATCH_PICK.tab==='drama'?(WATCH_PICK.view||'sources'):'album';}
function wsCurrentView(){const n=document.querySelector('.ws-cinema');return n?(n.dataset.view||''):'';}
function wsSafeOpen(){if(wsCurrentView()&&wsCurrentView()!==wsExpectedView())return;watchPickOpen();}
/* 视图会在请求过程中变化的场景（如 list → detail）：只比对「主人有没有翻页」 */
function wsOpenIfUnchanged(from){if(wsCurrentView()&&wsCurrentView()!==from)return;watchPickOpen();}
function watchProvider(){
 const services=((WATCH_PICK.catalog||{}).services)||[];
 const s=services.find(x=>x.id===WATCH_PICK.svc);
 return s?((s.providers||[]).find(x=>x.id===WATCH_PICK.prov)||null):null;
}
function watchGroupName(){
 const g=watchGroup();
 if(g)return g.name;
 const p=watchProvider();
 return p?(p.name||p.alias||p.title):'片源';
}
function watchPickTitle(){
 const p=WATCH_PICK;
 if(p.tab!=='drama')return '选一部一起看';
 if(p.view==='sources')return '片源组件';
 if(p.view==='detail')return (p.detail&&p.detail.title)||'选一部一起看';
 if(p.view==='list'){
  const cats=(watchProvider()||{}).categories||[];
  const c=cats.find(x=>x.id===p.cat);
  return watchGroupName()+(c?' · '+c.title:'');
 }
 return watchGroupName();
}
function watchPickOpen(){
 openModal(watchPickTitle(),watchPickBody());
 /* 组件过滤框：只重画卡片区。整体重绘会让输入框失焦，打两个字就断。 */
 const box=$('#ws-src-filter');
 if(box){
  box.oninput=()=>{
   WATCH_PICK.filter=box.value;
   const grid=$('.ws-cinema .src-manage');
   if(grid)grid.innerHTML=watchSrcCards();
   const count=$('#ws-src-count');
   if(count)count.textContent=watchSrcCount();
  };
  /* 弹窗自己监听 Esc 关闭；在输入框里按 Esc 应该只是退出输入 */
  box.onkeydown=e=>{if(e.key==='Escape'){e.stopPropagation();box.blur();}};
 }
}

/* 继续观看只存本机：片名/海报/上次看到的集数，够点一下接着播，不碰服务端状态 */
const WS_RECENT_KEY='love-watch-recent-v1';
function watchRecentLoad(){
 try{const a=JSON.parse(localStorage.getItem(WS_RECENT_KEY)||'[]');
  WATCH_PICK.recent=Array.isArray(a)?a.filter(x=>x&&x.id&&x.title):[];}
 catch{WATCH_PICK.recent=[];}
 return WATCH_PICK.recent;
}
function watchRecentSave(d,g,ep){
 const key=[g.svc,g.prov,d.id].join(':');
 const row={key,svc:g.svc,prov:g.prov,id:d.id,title:d.title||'一段视频',
  poster:d.poster||'',ep:Number(ep)||1,ts:Date.now()};
 const list=watchRecentLoad().filter(x=>x.key!==key);
 list.unshift(row);WATCH_PICK.recent=list.slice(0,12);
 try{localStorage.setItem(WS_RECENT_KEY,JSON.stringify(WATCH_PICK.recent));}catch{}
}
function watchRecentFor(){
 return watchRecentLoad().filter(x=>x.svc===WATCH_PICK.svc&&x.prov===WATCH_PICK.prov).slice(0,6);
}
/* 上游组件清单没有图标字段，用名字首字 + 按 id 散列的彩色字标代替品牌 logo */
const WS_LOGO_COLORS=['#F5C518','#FF6B8B','#A78BFA','#4ED8B0','#FF9840','#62A8FF','#F472B6','#9BD75B'];
function wsLogo(title,id){
 let h=0;for(const ch of String(id||''))h=(h*31+ch.charCodeAt(0))>>>0;
 const c=WS_LOGO_COLORS[h%WS_LOGO_COLORS.length];
 return `<span class="src-logo" style="--logo:${c}">${esc(String(title||'?').slice(0,1))}</span>`;
}

function watchPickBody(){
 const p=WATCH_PICK;
 const tabs=`<div class="ws-tabs">
   <button type="button" class="ws-tab${p.tab==='album'?' on':''}" data-action="watch-tab" data-id="album">相册视频</button>
   <button type="button" class="ws-tab${p.tab==='drama'?' on':''}" data-action="watch-tab" data-id="drama">在线片源</button>
  </div>`;
 if(p.tab==='album'){
  const items=p.videos.length?p.videos.map(v=>{
    const name=watchName(v.name)||'相册视频';
    return `<button type="button" class="ws-item" data-watch-media="${esc(v.id)}" data-watch-title="${esc(name)}">
    <span class="ws-thumb" style="background-image:url('/media/${esc(v.id)}?poster=1')"></span>
    <span class="ws-meta"><b>${esc(name)}</b><small>${new Date(v.created*1000).toLocaleDateString('zh-CN',{timeZone:state.me.space.timezone})}</small></span>
   </button>`;}).join(''):'<p class="meta">相册里还没有视频。在线片源那栏可以直接挑，也可以先「从本机选文件」各自打开同一部。</p>';
  return wsPage(tabs+`<div class="ws-section"><b>相册里的视频</b><span class="ws-section-count">${p.videos.length?p.videos.length+' 段':''}</span></div>
   <div class="ws-list">${items}</div>
   <div class="ws-bottom">${button('从本机选文件','watch-pick-local','soft')}${button('取消','close-modal')}</div>`,'album');
 }
 /* 在线片源：组件卡列表 → 组件首页 → 分类片单 → 选集，四层各画各的 */
 if(p.view==='sources')return wsPage(watchSourcesInner(),'sources');
 if(p.view==='home')return wsPage(watchHomeInner(),'home');
 if(p.view==='detail')return wsPage(watchEpisodesBody(p.detail),'detail');
 return wsPage(watchListInner(),'list');
}

/* 在线片源首页 = 搜索框 + 分组 + 两列组件卡。
   分组规则：给组件起过「标签」就按标签分，都没标签就按服务分 —— 组件从 17 个长到
   上百个时，只是纵向更长，不会像以前那样一次性铺满一屏还没法找。
   卡片主体「进片源」、右侧小按钮管开/关：button 里不能再塞 button，
   所以外层用 div 容器、里面放两个平级按钮。 */
/* 组件的网络模式徽章。上游没标（内建源就是这样）就整块不画 —— 空徽章比
   没有徽章更让人困惑。四种模式照搬 CapyPlayer 首页卡片的说法，只是缩成两三个字。 */
function wsNetPill(net){
 const m=(net||{}).mode||'';
 if(!m)return '';
 const cls=' src-net-'+m.replace(/[^a-z]/g,'');
 return `<i class="src-net${cls}">${esc((net||{}).short||(net||{}).label||m)}</i>`;
}

/* 这个组件现在算不算「坏了」。
   ⚠️ 上游说 `mobile`（手机端直连）时，服务端那项检查不过**不代表**播不了：
   真正拉流的是手机自己。所以这里只把它算成「待手机验证」，不算异常。 */
function wsNetBad(row){
 const net=row.net||{};
 if(net.mode==='mobile')return false;
 return (row.health&&row.health.ok===false)||net.status==='failed';
}

function watchSrcCard(row,many){
 const n=(row.cats||[]).length;
 const net=row.net||{};
 const bad=wsNetBad(row);
 const bits=[];
 /* 状态优先占这一行：卡片副标题是单行截断的，排在分类数后面会被「6 个分类…」
    挤掉，等于没提示。 */
 if(bad)bits.push('连不上');
 else if(net.mode==='mobile'&&net.checks&&net.checks.server!=='passed')bits.push('待手机验证');
 /* 「个」省掉：两列窄卡里「直连 · 27 个分类」会被截成「27 个…」，少一个字就正好够 */
 else if(n)bits.push(`${n} 分类`);
 if(row.hidden)bits.push('已隐藏');
 const meta=bits.join(' · ')||'点一下打开';
 const label=many?(row.svcName+' · '+row.name):row.name;
 return `<div class="src-card${row.enabled?' on':''}${row.hidden?' off':''}${bad?' bad':''}">
    <button type="button" class="src-card-main" data-action="watch-src-open"
      data-id="${esc(row.svc)}" data-prov="${esc(row.prov)}">
      ${wsLogo(row.name,row.key)}
      <span class="src-card-txt"><b>${esc(label)}</b>
       <small>${wsNetPill(net)}${row.tag?`<i class="src-tag">${esc(row.tag)}</i>`:''}${esc(meta)}</small></span>
     </button>
    <button type="button" class="src-card-go" data-action="watch-src-toggle"
      data-id="${esc(row.svc)}" data-prov="${esc(row.prov)}"
      aria-label="${row.enabled?'关闭':'启用'}${esc(row.name)}" aria-pressed="${row.enabled}">
      ${row.enabled?icon('check'):icon('arrow')}
     </button>
    </div>`;
}

/* 只画卡片区。过滤时单独重画这一块，不整体重绘弹窗 —— 整体重绘会让输入框失焦，
   连打两个字就断。 */
function watchSrcCards(){
 const rows=watchVisible();
 const many=(((WATCH_PICK.catalog||{}).services)||[]).length>1;
 if(!rows.length){
  const any=watchIndex().length;
  const first=(((WATCH_PICK.catalog||{}).services)||[])[0]||{};
  return `<p class="ws-empty">${any
   ?'没找到匹配的组件，换个词试试。'
   :esc(first.error||'还没有可用的组件，先添加一台服务地址。')}</p>`;
 }
 const byTag=watchIndex().some(x=>x.tag);
 const groups=[];
 rows.forEach(r=>{
  const title=byTag?(r.tag||'未分组'):r.svcName;
  let g=groups.find(x=>x.title===title);
  if(!g){g={title,rows:[]};groups.push(g);}
  g.rows.push(r);
 });
 return groups.map(g=>`<div class="src-group">
   <div class="src-group-head"><b>${esc(g.title)}</b><span>${g.rows.length}</span></div>
   <div class="src-grid">${g.rows.map(r=>watchSrcCard(r,many)).join('')}</div>
  </div>`).join('');
}

/* 计数行单独抽出来：过滤时只重画卡片区，这一行要跟着一起更新，
   否则会出现「共 20 个，筛出 18 个」却只显示 2 张卡的自相矛盾。 */
function watchSrcCount(){
 const all=watchIndex();
 const hidden=all.filter(x=>x.hidden).length;
 const shown=watchVisible().length;
 const bits=[`共 ${all.length} 个组件`];
 if(String(WATCH_PICK.filter||'').trim())bits.push(`匹配 ${shown} 个`);
 else if(hidden&&!WATCH_PICK.showHidden)bits.push(`隐藏 ${hidden} 个`);
 /* 上游只诊断它自己排的那一批（本机 17 个里覆盖 9 个），不是每个卡片都有
    网络模式。不说明白，主人会以为是漏画了。 */
 const netted=all.filter(x=>x.net&&x.net.mode).length;
 if(netted&&netted<all.length)bits.push(`${netted} 个标了网络模式`);
 return bits.join('，');
}

function watchSourcesInner(){
 const svcs=((WATCH_PICK.catalog||{}).services)||[];
 const hidden=watchIndex().filter(x=>x.hidden).length;
 const head=`<div class="src-filter">
   <input type="search" id="ws-src-filter" class="src-filter-input"
     value="${esc(WATCH_PICK.filter||'')}" placeholder="找组件：名字、编号或标签"
     autocomplete="off" maxlength="24" enterkeyhint="search">
  </div>
  <p class="ws-tip">点卡片进片源；右侧勾选框决定它出现在选片里。<span id="ws-src-count">${watchSrcCount()}</span></p>`;
 const hiddenRow=hidden?`<button type="button" class="src-hidden-toggle" data-action="watch-src-hidden">
   ${WATCH_PICK.showHidden?'收起':'显示'}已隐藏的 ${hidden} 个</button>`:'';
 const svcRows=svcs.map(s=>`<div class="src-svc-row">
   <span class="src-dot${s.online?' on':''}"></span>
   <b>${esc(s.name)}</b><small>${esc(s.base)}</small>
   <button type="button" class="link-btn" data-action="watch-src-del" data-id="${esc(s.id)}">移除</button>
  </div>`).join('');
 return `${head}
  <div class="src-manage">${watchSrcCards()}${hiddenRow}</div>
  <div class="src-svc-block"><b>片源服务</b>${svcRows||'<p class="ws-empty">还没有服务。</p>'}</div>
  <div class="ws-bottom">${button('整理','watch-src-curate','soft')}${button('加服务','watch-src-add','soft')}${button('完成','watch-src-done','primary')}</div>`;
}

/* 一行横滑海报：继续观看、各分类共用同一套卡片 */
function wsRail(items,action){
 return `<div class="ws-rail">`+items.map(d=>`<button type="button" class="ws-rail-card"
   data-action="${action}" data-id="${esc(d.id)}"${action==='watch-recent-play'?` data-ep="${Number(d.ep)||1}"`:''}>
   <span class="ws-card-poster" style="background-image:url('${esc(d.poster||'')}')">${d.remark?`<i class="ws-card-tag">${esc(d.remark)}</i>`:''}</span>
   <span class="ws-card-title">${esc(d.title)}</span>
  </button>`).join('')+`</div>`;
}

/* 组件首页（参考图 2）：顶部「继续观看」，下面按分类一排一排横滑，右侧 › 看全部 */
function watchHomeInner(){
 const p=WATCH_PICK;
 const recent=watchRecentFor();
 const blocks=[];
 if(recent.length)blocks.push(`<section class="ws-home-sec">
   <div class="ws-section"><b>继续观看</b></div>${wsRail(recent,'watch-recent-play')}</section>`);
 const cats=(watchProvider()||{}).categories||[];
 const rows=p.home.rows||[];
 rows.forEach(r=>blocks.push(`<section class="ws-home-sec">
   <div class="ws-section"><b>${esc(r.cat.title)}</b>
    <button type="button" class="ws-section-more" data-action="watch-home-more"
      data-id="${esc(r.cat.id)}" aria-label="查看${esc(r.cat.title)}全部内容">${icon('arrow')}</button></div>
   ${r.items.length?wsRail(r.items,'watch-drama'):`<p class="ws-rail-empty">${p.home.loading?'正在找…':esc(r.error||'这个分类暂时没有内容')}</p>`}
  </section>`));
 if(!rows.length)blocks.push(`<p class="ws-empty">${p.home.loading?'正在找…':esc(p.home.error||'这个片源还没有分类')}</p>`);
 /* 出错时紧跟一句针对这款组件网络模式的建议，别让人对着「加载失败」猜 */
 const advice=watchNetAdvice();
 if(advice)blocks.push(`<p class="ws-advice">${esc(advice)}</p>`);
 if(cats.length>rows.length)blocks.push(`<button type="button" class="ws-home-all" data-action="watch-home-all">
   查看全部 ${cats.length} 个分类 ${icon('arrow')}</button>`);
 const head=watchCanSearch()
  ?`<div class="ws-home-head"><button type="button" class="ws-search"
   data-action="watch-search">${icon('search')}${p.q?'搜：'+esc(p.q):'搜片名'}</button></div>`
  :'';
 return `<div class="ws-home">${head}${blocks.join('')}</div>`;
}

/* 某分类的完整海报墙（从分区 › 或搜索进来），分页和换一批沿用老逻辑 */
function watchListInner(){
 const p=WATCH_PICK;
 const cats=(watchProvider()||{}).categories||[];
 const chips=cats.map(c=>`<button type="button" class="ws-chip${p.cat===c.id?' on':''}"
   data-action="watch-cat" data-id="${esc(c.id)}">${esc(c.title)}</button>`).join('');
 const list=p.loading?'<p class="ws-empty">正在找…</p>':(p.dramas.length?`<div class="ws-grid">`+p.dramas.map(d=>`
   <button type="button" class="ws-card" data-action="watch-drama" data-id="${esc(d.id)}">
    <span class="ws-card-poster" style="background-image:url('${esc(d.poster)}')">${d.remark?`<i class="ws-card-tag">${esc(d.remark)}</i>`:''}</span>
    <span class="ws-card-title">${esc(d.title)}</span>
   </button>`).join('')+`</div>`:`<p class="ws-empty">${p.error?esc(p.error)+'。<br>':''}换个关键词，或者切到别的分类看看。</p>`);
 /* 上游给了 pageCount 就照着说清楚「第几页 / 共几页」，没给才退回按条数说话。
    以前全靠「这一页是不是满的」猜，红果一个分类 1413 页，猜不出来。 */
 const count=p.total?`共 ${p.total} 部${p.pageCount>1?` · 第 ${p.page}/${p.pageCount} 页`:''}`
  :(p.dramas.length?p.dramas.length+' 部':'');
 const canMore=!p.pageCount||p.page<p.pageCount;
 const more=canMore
  ?`<button type="button" class="ws-section-more" data-action="watch-more">换一批 ${icon('arrow')}</button>`
  :`<span class="ws-section-end">到底了</span>`;
 const section=`<div class="ws-section"><b>${esc((cats.find(c=>c.id===p.cat)||{}).title||(p.q?'搜「'+p.q+'」':'片单'))}</b>
   <span class="ws-section-count">${count}</span>${more}</div>`;
 const search=watchCanSearch()
  ?`<button type="button" class="ws-search" data-action="watch-search">${icon('search')}${p.q?esc(p.q):'搜片名'}</button>`:'';
 return `<div class="ws-toolbar"><div class="ws-cats">${chips}</div>${search}
 </div>`+section+`<div class="ws-list">${list}</div>
  <div class="ws-bottom">${button('取消','close-modal')}</div>`;
}

/* 上游的 capabilities 是未文档化的扩展：没给就当作支持（宁可多一个入口，
   也别把功能藏起来）；明确说没有 search 时才不显示搜索按钮。 */
function watchCanSearch(){
 const caps=((watchProvider()||{}).caps)||[];
 return !caps.length||caps.indexOf('search')>=0;
}

/* 组件连不上时给一句「接下来怎么办」。
   四种网络模式的处置**完全相反**，笼统说「出错了」等于没说 —— 最典型的是
   `mobile`：真正拉流的是手机自己，这时候让人去给服务器挂代理是南辕北辙。 */
function watchNetAdvice(){
 const p=WATCH_PICK;
 const g=watchGroup();
 if(!g)return '';
 const rows=p.home&&p.home.rows?p.home.rows:[];
 const failed=!!(p.home&&p.home.error)||rows.some(r=>!!r.error);
 /* 还在拉的时候别下结论：分类是一条条回来的，第一批失败不代表整页完蛋，
    提前弹一句「连不上」会跟下面还转着的「正在找…」自相矛盾。 */
 if(p.home&&p.home.loading)return '';
 if(!failed&&!wsNetBad(g))return '';
 const net=g.net||{};
 /* 明确标了「手机端直连」的组件：服务端拿不到内容本来就不该当成故障 */
 if(net.mode==='mobile')
  return '这个组件由手机端直连拉流，服务端取不到内容不代表播不了 —— 先在手机上试播一集。';
 if(net.mode==='proxy_configured')
  return '已经给它配了海外代理，服务端却还是连不上：先确认代理在容器里能访问，再重启这个组件，让它的 worker 重新读一次配置。';
 if(net.mode==='proxy_suggested')
  return '源站按地区限制访问，可以只给它挂一个局部代理，不必让整台服务都走代理。';
 if(net.mode==='direct')
  return '这个组件要由服务器自己去连源站，现在连不上：先查 NAS 的出网（DNS / 上游链路）。';
 return '这个组件现在连不上。';
}

/* 组件首页数据：每个分类各拉第一页铺一行。分类多的组件（27 个）不能一口气全并发，
   3 个一批、最多 6 个分类；剩下的用「查看全部 N 个分类」去完整片单页挑。 */
const WS_HOME_MAX_CATS=6;
async function watchHomeLoad(){
 const p=WATCH_PICK;
 const g=watchProvider();
 const cats=g?((g.categories||[]).slice(0,WS_HOME_MAX_CATS)):[];
 p.home={rows:cats.map(c=>({cat:c,items:[],error:''})),loading:!!cats.length,error:''};
 if(!cats.length)p.home.error='这个片源还没有分类';
 watchPickOpen();
 for(let i=0;i<p.home.rows.length;i+=3){
  const batch=p.home.rows.slice(i,i+3);
  const res=await Promise.allSettled(batch.map(r=>api(
   `/dramas/${encodeURIComponent(p.svc)}/${encodeURIComponent(p.prov)}?category=${encodeURIComponent(r.cat.id)}&page=1`)));
  res.forEach((r,k)=>{
   if(r.status==='fulfilled')batch[k].items=(r.value&&r.value.items)||[];
   else batch[k].error=(r.reason&&r.reason.message)||'这个分类暂时打不开';
  });
  wsSafeOpen();
 }
 p.home.loading=false;
 wsSafeOpen();
}

/* 点组件卡进片源。服务端 /api/dramas 与 /api/watch 都要求组件在启用清单里，
   没勾过的源点进来会连环 403 —— 进片源时顺手勾上，右侧开关仍可再关掉。 */
async function watchOpenSource(sid,prov){
 const services=((WATCH_PICK.catalog||{}).services)||[];
 const s=services.find(x=>x.id===sid);
 const p=s&&(s.providers||[]).find(x=>x.id===prov);
 if(!p)return;
 WATCH_PICK.tab='drama';WATCH_PICK.view='home';
 WATCH_PICK.svc=sid;WATCH_PICK.prov=prov;
 WATCH_PICK.detail=null;WATCH_PICK.dramas=[];WATCH_PICK.q='';
 WATCH_PICK.cat='';WATCH_PICK.page=1;WATCH_PICK.error='';
 if(!p.enabled){
  p.enabled=true;
  try{await api('/drama-sources/enabled',{method:'PUT',body:JSON.stringify({enabled:watchEnabledKeys()})});}
  catch(e){p.enabled=false;toast(e.message||'启用失败');}
 }
 await watchHomeLoad();
}

function watchEpisodesBody(d){
 /* 正在看的那一集高亮出来：state.watch 由 watchPull() 维护 */
 const cur=(state&&state.watch)||{};
 const curEp=String(cur.drama_id||'')===String(d.id)?Number(cur.drama_ep)||0:0;
 const eps=d.episodes.map(e=>`<button type="button" class="ws-ep${curEp===Number(e.n)?' on':''}" data-action="watch-drama-ep"
   data-id="${esc(d.id)}" data-ep="${e.n}">${e.n}</button>`).join('');
 return `<div class="ws-detail-head">
   <span class="ws-poster" style="background-image:url('${esc(d.poster)}')"></span>
   <div class="ws-detail-meta">
    <b>${esc(d.title)}</b>
    <small>${d.episodes.length>1?`共 ${d.episodes.length} 集 · 点一集就开始`:'点一下就开始'}</small>
    <button type="button" class="link-btn" data-action="watch-drama-back">${icon('back')} 返回片单</button>
   </div>
  </div>
  ${d.description?`<p class="ws-desc">${esc(d.description)}</p>`:''}
  <div class="ws-eps">${eps}</div>
  <div class="ws-bottom">${button('取消','close-modal')}</div>`;
}

async function watchLoadDramas(){
 const p=WATCH_PICK;
 if(!p.catalog)p.catalog=await watchCatalog();
 const g=watchGroup();
 p.view='list';
 if(!g){p.dramas=[];p.error='这个片源暂时不可用';return watchPickOpen();}
 /* 上游的 browse 必须带分类，空着会 404；没选过就默认第一个（搜索不用带） */
 if(!p.q)p.cat=p.cat||((g.cats[0]||{}).id||'');
 p.loading=true;p.error='';
 watchPickOpen();
 const query=`?category=${encodeURIComponent(p.cat||'')}&page=${p.page}${p.q?'&q='+encodeURIComponent(p.q):''}`;
 try{
  const res=await api(`/dramas/${encodeURIComponent(g.svc)}/${encodeURIComponent(g.prov)}`+query);
  p.dramas=(res&&res.items)||[];
  p.pageCount=Number(res&&res.pageCount)||0;
  p.total=Number(res&&res.total)||0;
 }catch(e){
  /* 自己加的组件上游说挂就挂，得让主人知道是源站的事，不是我们没搜到 */
  p.dramas=[];p.pageCount=0;p.total=0;p.error=e.message||'片源列表没拉到';toast(p.error);
 }
 p.loading=false;
 wsSafeOpen();
}

async function watchDramaDetail(id){
 const g=watchGroup();
 if(!g)return;
 const from=wsCurrentView();
 WATCH_PICK.loading=true;
 /* 详情加载期间不切视图、也不重绘：慢请求回来时主人可能已经翻页了，
    只比对「当前 DOM 还是不是当初那一层」，是才切到选集页。 */
 try{
  WATCH_PICK.detail=await api(`/dramas/${encodeURIComponent(g.svc)}/${encodeURIComponent(g.prov)}/${encodeURIComponent(id)}`);
 }catch(e){WATCH_PICK.detail=null;toast(e.message||'这个打不开');}
 WATCH_PICK.loading=false;
 if(WATCH_PICK.detail)WATCH_PICK.view='detail';
 wsOpenIfUnchanged(from);
}

function watchSearchForm(){
 openModal('搜一部片',`<form class="modal-form" id="ws-search-form">
   <label>片名、演员或关键词<input name="q" required maxlength="40" autocomplete="off" value="${esc(WATCH_PICK.q||'')}" placeholder="例如：少夫人来自东北"></label>
   ${formError()}
   ${modalActions('搜一下')}
  </form>`);
 $('#ws-search-form').onsubmit=async e=>{
  e.preventDefault();
  const q=String(new FormData(e.currentTarget).get('q')||'').trim();
  if(!q)return;
  WATCH_PICK.q=q;WATCH_PICK.page=1;WATCH_PICK.tab='drama';WATCH_PICK.view='list';
  WATCH_PICK.cat='';WATCH_PICK.detail=null;
  await watchLoadDramas();
 };
}

async function watchChooseDrama(id,ep,g){
 g=g||watchGroup();
 if(!g)return;
 const d=WATCH_PICK.detail||{};
 const title=d.title||'一段视频';
 const many=(d.episodes||[]).length>1;
 watchRecentSave({id,title,poster:d.poster||''},g,ep);
 closeModal();
 /* 记下本端刚点的片源：SSE 事件会在几百毫秒后回来，那时源可能还没挂上，
    用它避免把自己触发的同步再换一次源。 */
 watchExpectKey=`d:${g.svc}:${g.prov}:${id}:${ep}`;
 watchSetSource({drama:{src:g.svc,prov:g.prov,id,ep}});
 watchRenderStatus({...(state.watch||{}),title,drama_src:g.svc,drama_provider:g.prov,
  drama_id:id,drama_ep:ep,media:''});
 try{
  const cur=await api('/watch',{method:'PUT',body:JSON.stringify({
    drama_src:g.svc,drama_provider:g.prov,drama_id:id,drama_ep:Number(ep),media:'',
    title,position:0,duration:0,playing:false})});
  state.watch=cur;watchLastUpdated=Number(cur.updated)||0;watchFirstPoll=false;
  watchRenderStatus(cur);
  toast(many?`第 ${ep} 集，点播放就一起看`:'选好了，点播放就一起开始');
 }catch(e){toast(e.message||'选片失败');}
}

/* 一集就几分钟，播完自动接下一集；改的是服务端状态，另一半也会跟过来 */
function watchNextEpisode(){
 const st=state.watch||{};
 if(!st.drama_id||watchApplying)return;
 const next=Number(st.drama_ep||1)+1;
 if(next>2000)return;
 watchChooseDrama(st.drama_id,next,{svc:st.drama_src,prov:st.drama_provider});
}

/* ── 组件管理：加服务、勾组件 ─────────────────────────────────────── */
/* 「片源组件」现在就是在线片源 tab 的主页面，不再另开弹窗；
   添加/移除/开关之后都回到这一层，标题与返回层级由 watchPickTitle()/wsBack() 管。 */
function watchSources(){
 WATCH_PICK.tab='drama';WATCH_PICK.view='sources';
 WATCH_PICK.detail=null;
 watchPickOpen();
}
/* 影院层返回键按层级回退：组件列表→相册，首页→组件列表，片单→首页，选集→片单 */
function wsBack(){
 const p=WATCH_PICK;
 if(p.tab!=='drama')return closeModal();
 if(p.view==='sources'){p.tab='album';return watchPickOpen();}
 if(p.view==='home'){p.view='sources';return watchPickOpen();}
 if(p.view==='list'){p.view='home';p.detail=null;p.q='';return watchPickOpen();}
 if(p.view==='detail'){p.detail=null;p.view='list';return watchPickOpen();}
 return closeModal();
}

async function watchToggleSource(sid,prov){
 const cat=WATCH_PICK.catalog||{services:[]};
 const s=(cat.services||[]).find(x=>x.id===sid);
 const p=s&&(s.providers||[]).find(x=>x.id===prov);
 if(!p)return;
 p.enabled=!p.enabled;
 try{
  await api('/drama-sources/enabled',{method:'PUT',body:JSON.stringify({enabled:watchEnabledKeys()})});
 }catch(e){
  p.enabled=!p.enabled;
  toast(e.message||'改不了');
 }
 /* 当前选中的组件可能刚被关掉，回落到第一个还开着的 */
 const g=watchGroup();
 WATCH_PICK.svc=g?g.svc:'';WATCH_PICK.prov=g?g.prov:'';
 watchSources();
}

/* ── 整理组件：改名 / 标签 / 隐藏 ─────────────────────────────────────
   上游只告诉我们「有哪些组件」，怎么摆是本地的事。保存时只提交**改动过**的项，
   改一个名字不必把几十个组件都写一遍；逐条 PUT，失败也能看出卡在哪一条。 */
function watchCurateForm(){
 const rows=watchIndex();
 const list=rows.map(r=>`<div class="curate-row" data-key="${esc(r.key)}">
   <div class="curate-head"><b>${esc(r.title)}</b>${wsNetPill(r.net)}<small>${esc(r.key)}</small></div>
   <input name="alias:${esc(r.key)}" value="${esc(r.alias)}" maxlength="24"
     placeholder="改个名（留空 = 用上游原名）" autocomplete="off">
   <div class="curate-line">
    <input name="tag:${esc(r.key)}" value="${esc(r.tag)}" maxlength="12"
      placeholder="标签，例如 短剧 / 影视" autocomplete="off">
    <label class="switch-row"><input type="checkbox" name="hidden:${esc(r.key)}"${r.hidden?' checked':''}><span>隐藏</span></label>
   </div>
  </div>`).join('');
 openModal('整理组件',`<form class="modal-form" id="ws-curate-form">
   <p class="meta" style="margin:0">只改本机显示，不动上游。标签相同的组件会自动归到一组。</p>
   <div class="curate-list">${list||'<p class="ws-empty">还没有组件。</p>'}</div>
   ${formError()}
   <div class="form-actions">${button('取消','watch-src-back')}<button class="button primary" type="submit">保存</button></div>
  </form>`);
 const form=$('#ws-curate-form');
 form.onsubmit=async e=>{
  e.preventDefault();
  const fd=new FormData(form);
  const jobs=[];
  rows.forEach(r=>{
   const alias=String(fd.get('alias:'+r.key)||'').trim();
   const tag=String(fd.get('tag:'+r.key)||'').trim();
   const hidden=fd.get('hidden:'+r.key)==='on';
   const patch={};
   if(alias!==r.alias)patch.alias=alias;
   if(tag!==r.tag)patch.tag=tag;
   if(hidden!==r.hidden)patch.hidden=hidden;
   if(Object.keys(patch).length)jobs.push({key:r.key,patch});
  });
  if(!jobs.length)return closeModal();
  const box=form.querySelector('.form-error');
  for(let i=0;i<jobs.length;i++){
   const body=Object.assign({key:jobs[i].key},jobs[i].patch);
   try{
    await api('/drama-sources/overlay',{method:'PUT',body:JSON.stringify(body)});
   }catch(err){
    /* 可能只存进去一部分：先把清单刷新成真实状态再报错，别让界面骗人 */
    WATCH_PICK.catalog=await watchCatalog(true);
    if(box)box.textContent=(err.message||'保存失败')+'（已保存的部分仍然生效）';
    return;
   }
  }
  WATCH_PICK.catalog=await watchCatalog(true);
  toast('整理好了');
  watchSources();
 };
}

function watchAddSourceForm(){
 /* 这里的「取消」不是关弹窗而是回上一层面板（watch-src-back），
    和标准收尾件 modalActions() 的行为不同，所以保留自定义 actions。 */
 openModal('添加片源服务',`<form class="modal-form" id="ws-src-form">
   <label>名字<input name="name" maxlength="24" autocomplete="off" placeholder="随便起，例如「家里那台」"></label>
   <label>服务地址<input name="base" required maxlength="200" autocomplete="off" inputmode="url"
     placeholder="http://192.168.31.95:8788"></label>
   <p class="meta" style="margin:0">填 happy-capy 这类组件服务的根地址，保存后会自动去读它的组件清单。</p>
   ${formError()}
   <div class="form-actions">${button('取消','watch-src-back')}<button class="button primary" type="submit">保存</button></div>
  </form>`);
 $('#ws-src-form').onsubmit=async e=>{
  e.preventDefault();
  /* 先把表单节点抓在手上：await 之后事件对象的 currentTarget 会被置空，
     出错时就再也找不到那个 .form-error 了（这里踩过一次）。 */
  const form=e.currentTarget;
  const fd=new FormData(form);
  const base=String(fd.get('base')||'').trim();
  const name=String(fd.get('name')||'').trim();
  if(!base)return;
  try{
   /* 记住加之前有哪几台，好让新加的那台自动展开 ——
      否则主人加完一台还得自己往下滚去找它。 */
   const before=new Set(((WATCH_PICK.catalog||{}).services||[]).map(s=>s.id));
   await api('/drama-sources',{method:'POST',body:JSON.stringify({name,base})});
   WATCH_PICK.catalog=await watchCatalog(true);
   const fresh=((WATCH_PICK.catalog||{}).services||[]).find(s=>!before.has(s.id));
   if(fresh)WATCH_PICK.openSvc=fresh.id;
   toast('加上了，勾上想要的组件就能看');
   watchSources();
  }catch(err){
   const box=form.querySelector('.form-error');
   if(box)box.textContent=err.message||'加不上';
  }
 };
}

async function watchDropSource(sid){
 try{
  await api('/drama-sources/'+encodeURIComponent(sid),{method:'DELETE'});
  WATCH_PICK.catalog=await watchCatalog(true);
  const g=watchGroup();
  WATCH_PICK.svc=g?g.svc:'';WATCH_PICK.prov=g?g.prov:'';
  watchSources();
 }catch(e){toast(e.message||'删不掉');}
}

async function watchChooseMedia(id,title){
 closeModal();
 watchExpectKey='m:'+id;
 watchSetSource({media:id});
 watchRenderStatus({...(state.watch||{}),title,media:id});
 try{
  const cur=await api('/watch',{method:'PUT',body:JSON.stringify({media:id,title,position:0,duration:0,playing:false})});
  state.watch=cur;watchLastUpdated=Number(cur.updated)||0;watchFirstPoll=false;
  watchRenderStatus(cur);
  toast('选好了，点播放就一起开始');
 }catch(e){toast(e.message||'选片失败');}
}

function watchPickLocal(){
 const input=$('#watch-file');if(!input)return;
 input.value='';
 input.onchange=()=>{
   const f=input.files&&input.files[0];if(!f)return;
   watchExpectKey='local';
   watchSetSource({file:f});
  /* 本机片源不上传，只把片名告诉对方；媒体和短剧都传空，把服务器上的片源清掉，
     免得对方那边还挂着一部你以为已经换掉的片子。 */
  const title=watchName(f.name)||'本机视频';
  api('/watch',{method:'PUT',body:JSON.stringify({media:'',drama_id:'',drama_ep:0,title,position:0,duration:0,playing:false})})
   .then(cur=>{state.watch=cur;watchLastUpdated=Number(cur.updated)||0;watchFirstPoll=false;watchRenderStatus(cur);})
   .catch(()=>{});
  try{watchVideo()?.play().catch(()=>{});}catch{}
 };
 input.click();
}
