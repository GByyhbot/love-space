'use strict';

/* ── 生理期（自 app.js 拆出）────────────────────────────────────────────
   周期推算、日历标记、日记录卡、统计分析页、记录表单。

   口径：两个人共同维护同一条周期，谁都能记能改，页面看到的完全一样
   （后端 period.visible / db.visible 同口径）。没有「共享 / 私密」也没有「替谁记」。

   ⚠️ 和 app.js 共享全局作用域（classic script），不用 module 的原因见 watch.js 首部。
   ⚠️ 必须排在 app.js 之前加载：navigate('together') 会调 periodPage()。

/* ———— 生理期 ————
   参考美柚的核心闭环：记一次经期 → 推算周期与下次 → 日历上标出来。
   这里没有「共享 / 私密」也没有「替谁记」：两个人共同维护同一条周期，
   谁都能记、能改，页面看到的完全一样（后端 period.visible / db.visible 同口径）。 */
/* 记录项按天的档位表：编号落库（加密后也短），文案和图标只活在前端。
   想加一个选项只改这里，后端白名单不用动。 */
const PERIOD_FLOW={1:'非常少量',2:'少量',3:'中量',4:'大量',5:'非常大量'};
const PERIOD_COLOR={1:['浅红色','#F6A8BB'],2:['鲜红色','#EF3F68'],3:['深红色','#B22340'],4:['褐色','#8A5432'],5:['黑色','#3B3431']};
const PERIOD_PAIN={1:['完全不痛','😌'],2:['轻微痛','🙂'],3:['比较痛','😣'],4:['非常痛','😖'],5:['痛到极致','😫']};
const PERIOD_DISCHARGE={1:['干燥','内裤干爽，分泌物量少'],2:['粘稠','分泌物稠厚，触感像胶状物'],3:['稀糊状','含水量偏多偏黄，触感像乳液'],4:['水状','呈白色或透明，触感似水滴'],5:['蛋清状','呈透明状，两指间可拉丝']};
const PERIOD_MOODS=[['😄','超开心'],['😃','挺开心'],['😐','一般'],['🙁','不开心'],['😭','好伤心'],['🤩','兴奋'],['😲','惊喜'],['😌','满足'],['🥰','心动'],['😎','自信'],['😴','放松'],['😑','平静'],['😤','烦躁'],['😠','易怒'],['😡','生气'],['😰','焦虑'],['😞','内耗'],['😣','压力'],['😨','害怕'],['😶','冷漠']];
const PERIOD_SEX=[['无措施','⚠️'],['避孕套','🛡️'],['体外排精','💦'],['未射精','🚫'],['紧急避孕药','💊'],['短效避孕药','💊'],['长效避孕药','💊'],['节育环','⭕'],['其他措施','🌸'],['自慰','✋']];
const PERIOD_BODY_SYMPTOMS=[['没有症状','👍'],['腰酸','🧍'],['腹痛','🤕'],['小腹坠胀','🎈'],['乳房胀痛','💗'],['身体酸痛','💪'],['头痛','🤯'],['眩晕','💫'],['失眠','🌙'],['粉刺','🫧'],['皮肤干燥','🧴'],['食欲不振','🍽️'],['贪冷饮','🧊'],['腹泻','🚽'],['便秘','🧻'],['疲惫','😪']];
const PERIOD_SECRETION=[['褐色分泌物','🟤'],['出血','🩸'],['有血块','🔴'],['白带增多','⚪']];
const PERIOD_SYMPTOMS=[...PERIOD_BODY_SYMPTOMS,...PERIOD_SECRETION].map(([name])=>name);
/* 记录项清单：顺序就是美柚记录页的顺序，图标是「这类纪录长什么样」的提示 */
const PERIOD_LOG_FIELDS=[['flow','流量','🩸'],['color','颜色','🎨'],['pain','痛经','⚡'],['sex','爱爱','💗'],['symptoms','症状','💊'],['mood','心情','😊'],['weight','体重','⚖️'],['discharge','白带','💧'],['temp','体温','🌡️']];
const DAY_MS=864e5;
function dayNum(s){return Math.round(Date.parse(String(s).slice(0,10)+'T00:00:00Z')/DAY_MS);}
function dayStr(n){return new Date(n*DAY_MS).toISOString().slice(0,10);}
/* 日记录行：同一种 kind，靠「有 date 没有 start」认出来。经期行才有 start，参与周期推算；
   日记录行只描述那一天，日历和预测都不受它影响。 */
function periodDayRows(){return recordsOf('period').filter(r=>!r.body.start&&r.body.date);}
function periodDayRow(date){return periodDayRows().find(r=>String(r.body.date).slice(0,10)===date)||null;}
function periodDayLogs(){const map={};periodDayRows().forEach(r=>{map[String(r.body.date).slice(0,10)]=r.body;});return map;}
/* 一行记录右侧要显示的值：空字符串表示还没记，行尾会换成 ⊕ */
function periodValueText(key,b){
 switch(key){
  case 'flow':return b.flow?(typeof b.flow==='number'?(PERIOD_FLOW[b.flow]||''):'经量'+b.flow):'';
  case 'color':return b.color?(PERIOD_COLOR[b.color]||[''])[0]:'';
  case 'pain':return b.pain?(PERIOD_PAIN[b.pain]||[''])[0]:'';
  case 'discharge':return b.discharge?(PERIOD_DISCHARGE[b.discharge]||[''])[0]:'';
  case 'mood':{const m=b.mood?PERIOD_MOODS[b.mood-1]:null;return m?`${m[0]} ${m[1]}`:'';}
  case 'sex':{
   const list=periodSexEntries(b);
   if(!list.length)return '';
   const first=list[0];
   const ways=first.w.map(i=>(PERIOD_SEX[i-1]||[])[0]).filter(Boolean).join('、');
   return [list.length>1?`${list.length} 次`:'',first.t||'',ways].filter(Boolean).join(' · ');
  }
  case 'symptoms':return (b.symptoms||[]).join(' · ');
  case 'weight':return b.weight?`${b.weight} 公斤`:'';
  case 'temp':return b.temp?`${b.temp} ℃`:'';
  default:return '';
 }
}
/* 存一天：没有这天的行就新建，有就整体覆盖（body 是整份加密体，不能只发一个字段） */
async function periodSaveDay(date,patch){
 const row=periodDayRow(date);
 const body={...((row&&row.body)||{}),date,...patch};
 Object.keys(body).forEach(k=>{
  const v=body[k];
  if(v===''||v==null||(Array.isArray(v)&&!v.length))delete body[k];
 });
 if(body.start)delete body.start;   // 日记录行永不带 start，否则会被当成一次经期
 if(row)await put('/records/'+row.id,{kind:'period',body});
 else await post('/records',{kind:'period',body,client_id:uuid()});
 await refresh();
}
/* 「月经来了 是/否」：是＝这天补一次经期起点（已在窗口内则不动）；
   否＝这天是首日就撤掉这条，是中途某天就把这次经期截到昨天为止。 */
/* 这一天算不算经期，用两个动作表达，跟美柚一致：
   · 经期外：[月经来了]  —— 从这天开始一次；离上次结束 3 天内自动接上那一段，不拆成两次
   · 经期内：[月经走了]  —— 今天干净了，这次截到昨天（今天是首日就直接撤掉）
             [月经又来了] —— 今天还在，把结束日再往后推一天（幂等，连点不会疯长） */
async function periodStart(day){
 const d=periodData(),n=dayNum(day),lastEp=d.lastEp;
 if(lastEp){
  const gap=n-lastEp.end;
  // 刚结束又回潮：接在上一段后面，否则一个月会碎成两三段经期
  if(gap>=1&&gap<=3){
   const r=lastEp.rec;
   await put('/records/'+r.id,{kind:'period',body:{...r.body,length:n-dayNum(r.body.start)+1}});
   toast('已经把这次经期接到今天');await refresh();return;
  }
 }
 // 经期长度的默认值取历史平均，但不低于 3 天：中途截短过一次之后，
 // 平均值会被拉到 1–2 天，下次新建就会变成一个荒唐的"两天经期"。
 const body={start:day,length:Math.max(3,d.length),cycle:d.cycle};
 await post('/records',{kind:'period',body,client_id:uuid()});
 toast('已记下这次经期');await refresh();
}
async function periodEnd(day){
 const d=periodData(),n=dayNum(day),hit=periodEpisodeOf(d,n);
 if(!hit)return toast('这天本来就不在经期里');
 const ep=hit.owner,s=dayNum(ep.body.start);
 if(s===n){await del('/records/'+ep.id);toast('已撤掉这次经期');}
 else{await put('/records/'+ep.id,{kind:'period',body:{...ep.body,length:n-s}});toast('这次经期到昨天为止');}
 await refresh();
}
async function periodMore(day){
 const d=periodData(),n=dayNum(day),hit=periodEpisodeOf(d,n);
 if(!hit)return toast('这天不在经期里');
 const ep=hit.owner,s=dayNum(ep.body.start),len=Number(ep.body.length||5),want=Math.max(len,n-s+2);
 if(want===len)return toast(`这次经期已经排到第 ${len} 天了`);
 await put('/records/'+ep.id,{kind:'period',body:{...ep.body,length:want}});
 toast('这次经期又多算一天');await refresh();
}
function periodData(){
 /* 两个人共同维护同一条周期：不按作者区分，谁记的都算进去，界面也就只有一套 */
 const items=recordsOf('period').filter(r=>r.body.start).slice().sort((a,b)=>String(a.body.start).localeCompare(String(b.body.start)));
 /* 同一次月经常被拆成两三行（中途点了「月经走了」、隔天又「月经又来了」就会另起一行）。
   统计前先按"首尾相接即同一段"合并，否则平均经期天数会被碎片腰斩——
   去年补了半年数据后，13 行只对应 8 次月经，平均天数一度显示成 2 天。 */
 const episodes=[];
 items.forEach(r=>{
  const s=dayNum(r.body.start),len=Math.max(1,Number(r.body.length||1)),e=s+len-1;
  const prev=episodes[episodes.length-1];
  if(prev&&s<=prev.end+1){
   prev.end=Math.max(prev.end,e);prev.length=prev.end-prev.start+1;prev.rec=r;prev.frags.push(r);return;
  }
  episodes.push({start:s,end:e,length:len,rec:r,frags:[r]});
 });
 const gaps=[];
 for(let i=1;i<episodes.length;i++){const g=episodes[i].start-episodes[i-1].start;if(g>=15&&g<=60)gaps.push(g);}
 const lastEp=episodes[episodes.length-1]||null;
 const avg=gaps.length?Math.round(gaps.reduce((a,b)=>a+b,0)/gaps.length):(lastEp?.rec.body.cycle||28);
 const length=episodes.length?Math.round(episodes.reduce((s,e)=>s+e.length,0)/episodes.length):5;
 const todayN=dayNum(today());
 const startN=lastEp?lastEp.start:null;
 const nextStart=startN!=null?startN+avg:null;
 /* 判断"今天在不在经期里"必须用这次记录的实际天数，不能用平均天数：
   平均 3 天、这次只记了 1 天的时候，以前会出现"标题写卵泡期、副标题写经期第 2 天"的矛盾。
   这里同样取合并后的段长，否则最后几天被拆成碎片时"经期第 N 天"会提前结束。 */
 const lastLen=lastEp?lastEp.length:5;
 const inWindow=startN!=null&&todayN>=startN&&todayN<startN+lastLen;
 return {items,episodes,gaps,cycle:avg,length,last:lastEp?lastEp.rec:null,lastEp,lastLen,nextStart,todayN,inWindow,
  dayOfPeriod:inWindow?todayN-startN+1:0,untilNext:nextStart!=null?nextStart-todayN:null,
  estimated:gaps.length===0};
}
/* 这一天落在哪一次月经里（合并后的段），以及该动哪一行：
   取开始日不晚于这天的最后一个碎片，这样即便这天正好落在两个碎片之间的空档
   （隔一天才又「月经又来了」），改长度也改在正确的那一行上。 */
function periodEpisodeOf(d,n){
 const ep=(d.episodes||[]).find(e=>n>=e.start&&n<=e.end);
 if(!ep)return null;
 const owner=ep.frags.filter(r=>dayNum(r.body.start)<=n).pop()||ep.frags[0];
 return {ep,owner};
}
/* 美柚式四阶段：月经期 / 卵泡期 / 排卵期 / 黄体期
   锚点是每次月经开始日，排卵日按"下次月经前 14 天"推（黄体期长度相对固定），
   所以黄体期天数恒定、卵泡期随周期长短伸缩，这也符合真实生理规律。 */
const PHASE_NAMES={period:'月经期',follicular:'卵泡期',fertile:'排卵期',luteal:'黄体期'};
function cyclePhases(d){
 const map={};
 const mark=(s,len,predicted)=>{
  const ovu=s+d.cycle-14;
  const put=(n,phase)=>{if(n>=0)map[dayStr(n)]={phase,predicted};};
  for(let i=0;i<len;i++)put(s+i,'period');
  for(let i=s+len;i<=ovu-6;i++)put(i,'follicular');
  for(let i=ovu-5;i<=ovu+1;i++)put(i,'fertile');
  for(let i=ovu+2;i<s+d.cycle;i++)put(i,'luteal');
  const k=dayStr(ovu);if(map[k])map[k].ovu=true;
 };
 // 先铺预测（远的先写），再用实际记录覆盖 —— 有真实数据时永远以真实为准
 if(d.nextStart!=null)for(let k=2;k>=0;k--)mark(d.nextStart+d.cycle*k,d.length,true);
 d.episodes.forEach(e=>mark(e.start,e.length,false));
 return map;
}
function todayPhase(d){const ph=cyclePhases(d)[today()];return ph||null;}
/* 整月网格：格子样式沿用 .cal-day（经期实心粉、预测虚边、排卵紫、记过细节带点）。
   只负责画格子，标题和翻页在 periodTopCard 里——原来的「双月日历」删掉了，一个月就够看。 */
function periodMonthGrid(y,m,d){
 const lead=new Date(Date.UTC(y,m-1,1)).getUTCDay(),days=new Date(Date.UTC(y,m,0)).getUTCDate();
 const phases=cyclePhases(d),todayS=today(),logs=periodDayLogs(),picked=state.periodDay||todayS;
 // 月初第一格的"上一段"要取上月最后一天，否则每月 1 号都会被误标成阶段第一天
 const firstIso=`${y}-${String(m).padStart(2,'0')}-01`;
 let prevPhase=(phases[dayStr(dayNum(firstIso)-1)]||{}).phase||'';
 const recs=new Map();
 d.items.forEach(r=>recs.set(String(r.body.start).slice(0,10),r));
 const cells=[...Array(lead)].map(()=>'<span></span>');
 for(let v=1;v<=days;v++){
  const iso=`${y}-${String(m).padStart(2,'0')}-${String(v).padStart(2,'0')}`,ph=phases[iso],rec=recs.get(iso),log=logs[iso];
  const isStart=!!ph&&ph.phase!==prevPhase;
  prevPhase=ph?ph.phase:'';
  // 格子里不再写短标签：经期是实心粉、排卵期是连续紫底，标签只会把那一行撑高
  const cls=ph?` ph-${ph.phase}${ph.predicted?' ph-pred':''}${ph.ovu?' ph-ovu':''}${isStart?' ph-start':''}`:'';
  const parts=[ph?`${PHASE_NAMES[ph.phase]}${ph.predicted?'（预测）':''}`:'还没有记录',ph&&ph.ovu?'排卵日':'',rec?'这次经期的第一天':'',log?'这天记过身体情况':'点一下记这天'].filter(Boolean);
  const tip=parts.join(' · ');
  cells.push(`<button type="button" class="cal-day${cls}${iso===todayS?' is-today':''}${rec?' has-rec':''}${log?' has-log':''}${iso===picked?' picked':''}" data-action="period-day" data-day="${iso}" title="${tip}" aria-label="${m} 月 ${v} 日，${tip}"><span class="cal-num">${v}</span><span class="cal-dots"></span></button>`);
 }
 return `<div class="cal-weekrow">${['日','一','二','三','四','五','六'].map((w,i)=>`<span class="cal-week${i===0||i===6?' is-end':''}">${w}</span>`).join('')}</div><div class="calendar-grid period-cal">${cells.join('')}</div>`;}
/* 翻月：月末日期要夹到目标月的最后一天，否则 1/31 往前翻会跳到 3 月 */
function shiftMonth(day,delta){
 const y=Number(day.slice(0,4)),m=Number(day.slice(5,7))-1+delta;
 const dt=new Date(Date.UTC(y,m,1));
 const last=new Date(Date.UTC(dt.getUTCFullYear(),dt.getUTCMonth()+1,0)).getUTCDate();
 const date=Math.min(Number(day.slice(8)),last);
 return `${dt.getUTCFullYear()}-${String(dt.getUTCMonth()+1).padStart(2,'0')}-${String(date).padStart(2,'0')}`;
}
/* 阶段短名用两字，日历格子里放得下；主视觉卡上要念全称，单独一份 */
const PHASE_CARD={period:'经期',follicular:'卵泡期',fertile:'排卵期',luteal:'黄体期'};
/* 每个阶段一句照护提示——比"现在处于 X"多给一点能落地的事。
   长度控制在 15 字内：卡片左边只剩 ~15 个字宽，长一句就会折出孤字。 */
const PHASE_CARE={
 period:'多休息、保暖',
 follicular:'状态正好，适合一起出门走走',
 fertile:'身体状态不错，别熬夜就行',
 luteal:'容易情绪起伏，多担待一点'
};
function greetWord(){
 const h=new Date().getHours();
 if(h<5)return '夜深了';
 if(h<9)return '早上好';
 if(h<12)return '上午好';
 if(h<14)return '中午好';
 if(h<18)return '下午好';
 if(h<23)return '晚上好';
 return '夜深了';
}
/* 周期主视觉卡：左边问候 + 当前阶段 + 一句照护提示，右边环形进度标「周期第 N 天」。
   自己的大卡和「她的周期」共用这一个组件，口径不会分叉。 */
/* 受孕概率只按阶段给「低/中/高」三档，不给百分比：
   日历推算给不出那么细的结论，写死数字反而会被当成避孕依据。
   （Clue / Flo 也把这类提示写成"推算"，不承诺准确性。） */
const FERTILITY={period:['低','经期几乎不会受孕'],follicular:['中','越接近排卵日越高'],fertile:['高','排卵期前后，概率最高'],luteal:['低','排卵已过，概率回落']};
const FERTILITY_NOTE='按日历推算，仅供参考，不能作为避孕依据。';
/* 周期异常预警：阈值照「姨妈来了（Novawerk）」和「她扶 FloMe」那套——
   周期 <21 或 >35 天、经期 >7 天、长期没记录。看最近三次而不是只看最后一次，
   否则一次异常过一个月就被下一次正常值盖掉，等于没提醒。 */
function periodWarnings(d){
 const out=[],eps=d.episodes||[];
 if(eps.length<2)return out;
 const gaps=[];for(let i=1;i<eps.length;i++)gaps.push(eps[i].start-eps[i-1].start);
 const recent=gaps.slice(-3);
 const short=recent.filter(g=>g<21),long=recent.filter(g=>g>35);
 if(short.length)out.push(`最近三次里有 ${short.length} 次周期只有 ${short.join('、')} 天，偏短——可能是一次点滴出血，也可能记漏了`);
 if(long.length)out.push(`最近三次里有 ${long.length} 次周期到 ${long.join('、')} 天，偏长`);
 const len=d.lastEp?d.lastEp.length:0;
 if(len>7)out.push(`这次经期记了 ${len} 天，超过 7 天建议留意`);
 if(d.lastEp&&d.todayN-d.lastEp.start>Math.max(45,d.cycle+21))
  out.push(`距离上一次经期已经 ${d.todayN-d.lastEp.start} 天，可能漏记了`);
 return out;
}
function cycleHero(d,name=''){
 if(!d.items.length)return '';
 const ph=todayPhase(d);
 const cyc=Math.max(1,d.cycle);
 const startN=dayNum(d.last.body.start);
 const dayIn=Math.min(cyc,Math.max(1,d.todayN-startN+1));
 const pct=Math.max(4,Math.round(dayIn/cyc*100));   // 至少留一点弧，0% 看着像没加载出来
 const R=31,C=+(2*Math.PI*R).toFixed(1);
 const title=ph
  ?`当前阶段：${PHASE_CARD[ph.phase]}${ph.predicted?'<em class="cycle-hero-pred">预测</em>':''}`
  :(d.untilNext<0?`已推迟 ${-d.untilNext} 天`:'周期还在推算');
 const tip=d.inWindow
  ?`今天是经期第 ${d.dayOfPeriod} 天，${PHASE_CARE.period}`
  :(ph?PHASE_CARE[ph.phase]:(d.untilNext>=0?`预计还有 ${d.untilNext} 天`:'记一次就能重新推算'));
 const fert=ph?FERTILITY[ph.phase]:null;
 return `<div class="cycle-hero">
  <div class="cycle-hero-copy">
   <span class="cycle-hero-hi">${greetWord()}${name?'，'+esc(name):''}</span>
   <strong class="cycle-hero-phase">${title}</strong>
   <span class="cycle-hero-tip">${tip}</span>
   ${fert?`<span class="cycle-hero-fert f-${ph.phase}" title="${esc(FERTILITY_NOTE)}">受孕概率 <b>${fert[0]}</b><em>${esc(fert[1])}</em></span>`:''}
  </div>
  <div class="cycle-hero-side">
   <svg class="cycle-ring" viewBox="0 0 72 72" role="img" aria-label="周期第 ${dayIn} 天，共 ${cyc} 天">
    <circle class="ring-track" cx="36" cy="36" r="${R}"></circle>
    <circle class="ring-fill" cx="36" cy="36" r="${R}" stroke-dasharray="${C}" stroke-dashoffset="${(C*(1-pct/100)).toFixed(1)}" transform="rotate(-90 36 36)"></circle>
    <text x="36" y="36" text-anchor="middle" dominant-baseline="central">${dayIn}</text>
   </svg>
   <span class="cycle-hero-day">周期第 ${dayIn} 天</span>
  </div>
 </div>`;
}
/* 阶段进度条：一条 bar 摊开整个周期，游标就是今天，当前段高亮。
   ⚠️ flex 权重必须是「周期内第几天」这种相对天数，别拿绝对天数（dayNum）去当权重，
   否则某一段会被撑成两万多天、整条 bar 塌成一段。 */
function phaseBar(d){
 if(!d.items.length)return '';
 const s=dayNum(d.last.body.start),cyc=Math.max(1,d.cycle),len=Math.max(1,d.length),ovuRel=cyc-14;
 const segs=[['period','月经期',len],['follicular','卵泡期',Math.max(1,ovuRel-5-len)],
             ['fertile','排卵期',7],['luteal','黄体期',Math.max(1,cyc-ovuRel-2)]];
 const pos=Math.min(100,Math.max(0,(d.todayN-s+1)/cyc*100));
 const ph=todayPhase(d),cur=ph?ph.phase:'';
 return `<div class="phase-wrap"><div class="phase-bar">${segs.map(([k,nm,nd])=>`<span class="phase-seg s-${k}${k===cur?' current':''}" style="flex:${nd}" title="${nm}约 ${nd} 天"><b>${nm}</b><small>${nd}天</small></span>`).join('')}<i class="phase-cursor" style="left:${pos}%" aria-hidden="true"></i></div></div>`;
}
/* 顶部日历卡：整月网格 + 月份翻页 + 图例。
   原来这里只显示一周、下面再摆一份双月日历，等于同一件事看两遍；现在合成一张，整月铺开。 */
function periodTopCard(d){
 const day=state.periodDay||today(),y=Number(day.slice(0,4)),m=Number(day.slice(5,7));
 return `<div class="cal-bar"><div class="cal-bar-title"><strong>${m} 月</strong><span>${y} 年</span></div><div class="cal-bar-nav"><button type="button" class="cal-nav" data-action="period-month" data-delta="-1" aria-label="上个月">‹</button><button type="button" class="cal-today" data-action="period-pick" data-day="${today()}">今天</button><button type="button" class="cal-nav" data-action="period-month" data-delta="1" aria-label="下个月">›</button></div></div>${periodMonthGrid(y,m,d)}<p class="period-legend"><span class="lg-pill p-period">月经期</span><span class="lg-pill p-pred">预测经期</span><span class="lg-pill p-fertile">排卵期</span><span class="lg-pill p-ovu"><i></i>排卵日</span></p>`;
}
/* 选中那天的记录卡：一行一项，点开底部弹层选，选完立刻存。
   「月经来了 是/否」不是普通字段——它决定这天算不算经期，所以单独一行的分段按钮。 */
function periodLogCard(day){
 const d=periodData(),log=periodDayLogs()[day]||{},n=dayNum(day);
 const hit=periodEpisodeOf(d,n),ep=hit?hit.owner:null;
 const on=!!hit;
 const head=day===today()?'今天':`${Number(day.slice(5,7))} 月 ${Number(day.slice(8))} 日`;
 const rows=PERIOD_LOG_FIELDS.map(([key,name,ico])=>{
  const text=periodValueText(key,log);
  return `<button type="button" class="plog-row" data-action="period-log" data-field="${key}" data-day="${day}"><span class="plog-ico">${ico}</span><span class="plog-name">${name}</span><span class="plog-val">${esc(text)}</span>${text?'<span class="plog-add ghost">›</span>':`<span class="plog-add">${icon('plus')}</span>`}</button>`;
 }).join('');
 return `<section class="card period-log">
  <div class="plog-head"><div><strong>${head}</strong><small>${on?`经期第 ${n-hit.ep.start+1} 天`:'记下这一天，周期会更准'}</small></div>${ep?`<button type="button" class="link-btn" data-action="edit-record" data-id="${ep.id}">改经期长度</button>`:''}</div>
  <div class="plog-row"><span class="plog-ico">🩸</span><span class="plog-name">经期</span>${on
   ?`<span class="plog-seg"><button type="button" class="seg-btn outline" data-action="period-end" data-day="${day}">月经走了</button><button type="button" class="seg-btn" data-action="period-more" data-day="${day}">月经又来了</button></span>`
   :`<span class="plog-seg"><button type="button" class="seg-btn primary" data-action="period-start" data-day="${day}">月经来了</button></span>`}</div>
  ${rows}
  <button type="button" class="plog-row" data-action="period-log" data-field="content" data-day="${day}"><span class="plog-ico">📝</span><span class="plog-name">日记</span><span class="plog-val">${esc((log.content||'').slice(0,16))}</span><span class="plog-add">${log.content?'':icon('edit')}</span></button>
 </section>`;
}
/* 爱爱一天可能好几次，每次单独记措施和时间。
   老数据是 [2,4] 这种纯编号，统一读成 [{t:'',w:[2]},…]，界面只处理一种形状。 */
function periodSexEntries(b){
 return (b.sex||[]).map(item=>item&&typeof item==='object'
  ?{t:String(item.t||''),w:(item.w||[]).filter(x=>typeof x==='number')}
  :{t:'',w:typeof item==='number'?[item]:[]});
}
const CLOCK_H=[...Array(24)].map((_,i)=>String(i).padStart(2,'0'));
const CLOCK_M=[...Array(60)].map((_,i)=>String(i).padStart(2,'0'));
const WHEEL_H=44;   // 每格 44px，滚轮靠 scrollTop 换算选中项，改了要同步 CSS
function nowTime(){const d=new Date();return `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`;}
function wheelMarkup(t){
 const [h,m]=(t||'00:00').split(':');
 const col=(id,vals,cur)=>`<div class="wheel" data-wheel="${id}">${vals.map(v=>`<span class="wheel-item${v===cur?' on':''}">${v}</span>`).join('')}</div>`;
 return `<div class="wheel-wrap"><i class="wheel-band" aria-hidden="true"></i>${col('h',CLOCK_H,h||'00')}<span class="wheel-colon">:</span>${col('m',CLOCK_M,m||'00')}</div>`;
}
function bindWheel(root){
 $$('.wheel',root).forEach(w=>{
  const items=$$('.wheel-item',w);
  const idx=Math.max(0,items.findIndex(x=>x.classList.contains('on')));
  w.scrollTop=idx*WHEEL_H;
  w.onscroll=()=>{
   const i=Math.round(w.scrollTop/WHEEL_H);
   items.forEach((it,k)=>it.classList.toggle('on',k===i));
  };
 });
}
function periodSexSheet(day){
 const b=(periodDayRow(day)||{}).body||{};
 let entries=periodSexEntries(b);
 if(!entries.length)entries=[{t:nowTime(),w:[]}];
 let cur=0;
 openModal('爱爱',`<div class="ps-sheet" id="sex-sheet"></div>`,{sheet:true});
 const root=$('#sex-sheet');
 /* 切 tab / 重绘前先把屏幕上的选择读回 entries，否则会丢 */
 const read=()=>{
  const ways=$$('.ps-opt.on',root).map(o=>Number(o.dataset.pick));
  const wh=$('.wheel[data-wheel="h"]',root),wm=$('.wheel[data-wheel="m"]',root);
  const h=wh?CLOCK_H[Math.round(wh.scrollTop/WHEEL_H)]:null;
  const m=wm?CLOCK_M[Math.round(wm.scrollTop/WHEEL_H)]:null;
  entries[cur]={t:`${h||'00'}:${m||'00'}`,w:ways};
 };
 const draw=()=>{
  const e=entries[cur];
  root.innerHTML=`
   <div class="sex-tabs">${entries.map((x,i)=>`<button type="button" class="sex-tab${i===cur?' on':''}" data-tab="${i}">第 ${i+1} 次</button>`).join('')}<button type="button" class="sex-tab add" data-add="1" aria-label="再记一次">＋</button></div>
   <h3 class="ps-sub">爱爱</h3>
   <div class="ps-grid c5">${PERIOD_SEX.map(([name,emoji],i)=>psOption(i+1,name,emoji,e.w.includes(i+1))).join('')}</div>
   <h3 class="ps-sub">时间</h3>
   ${wheelMarkup(e.t)}
   <div class="form-actions"><button type="button" class="button" data-action="close-modal">取消</button>${entries.length>1?`<button type="button" class="button danger" id="sex-del">删除这次</button>`:''}<button type="button" class="button primary" id="sex-ok">确定</button></div>`;
  bindWheel(root);
  $('#sex-ok').onclick=async ev=>{
   read();
   ev.currentTarget.disabled=true;
   try{await periodSaveDay(day,{sex:entries.filter(x=>x.w.length).map(x=>({t:x.t,w:x.w}))});closeModal();}
   catch(err){toast(err.message);ev.currentTarget.disabled=false;}
  };
  const del=$('#sex-del');
  if(del)del.onclick=()=>{
   entries.splice(cur,1);
   if(!entries.length)entries=[{t:nowTime(),w:[]}];
   cur=Math.min(cur,entries.length-1);
   draw();
  };
 };
 root.onclick=e=>{
  const tab=e.target.closest('.sex-tab');
  if(tab&&tab.dataset.add){
   read();
   if(entries.length>=8)return toast('最多记八次');
   entries.push({t:nowTime(),w:[]});cur=entries.length-1;draw();return;
  }
  if(tab){read();cur=Number(tab.dataset.tab);draw();return;}
  const opt=e.target.closest('.ps-opt');
  if(opt){opt.classList.toggle('on');opt.setAttribute('aria-pressed',String(opt.classList.contains('on')));}
 };
 draw();
}
/* ———— 底部选择弹层 ————
   单选＝点一下就存并关掉；多选＝勾完点确定。全部走 periodSaveDay 落库。 */
function psOption(value,label,visual,on,style){
 return `<button type="button" class="ps-opt${on?' on':''}" data-pick="${esc(String(value))}" aria-pressed="${on}"><span class="ps-dot"${style?` style="${style}"`:''}>${visual||''}</span><span class="ps-label">${esc(label)}</span></button>`;
}
function periodChoiceSheet(day,field,title,items,cols=5){
 const cur=((periodDayRow(day)||{}).body||{})[field];
 openModal(title,`<div class="ps-sheet" id="ps-sheet"><div class="ps-grid c${cols}">${items.map(([v,label,visual,style])=>psOption(v,label,visual,String(cur)===String(v),style)).join('')}</div><p class="small-note">选一下就直接保存；再点一次同一项就是清除。</p></div>`,{sheet:true});
 $('#ps-sheet').onclick=async e=>{
  const btn=e.target.closest('.ps-opt');if(!btn)return;
  const picked=Number(btn.dataset.pick);
  try{await periodSaveDay(day,{[field]:String(cur)===String(picked)?null:picked});closeModal();}
  catch(err){toast(err.message);}
 };
}
function periodMultiSheet(day,field,title,groups,cols=4){
 const chosen=new Set((((periodDayRow(day)||{}).body||{})[field]||[]).map(String));
 const body=groups.map(([sub,items])=>`${sub?`<h3 class="ps-sub">${sub}</h3>`:''}<div class="ps-grid c${cols}">${items.map(([v,label,visual])=>psOption(v,label,visual,chosen.has(String(v)))).join('')}</div>`).join('');
 openModal(title,`<div class="ps-sheet" id="ps-sheet">${body}<div class="form-actions">${button('取消','close-modal')}<button class="button primary" id="ps-ok">确定</button></div></div>`,{sheet:true});
 const root=$('#ps-sheet');
 root.onclick=e=>{
  const btn=e.target.closest('.ps-opt');if(!btn)return;
  const on=!btn.classList.contains('on');
  // 「没有症状」和具体症状互斥，否则同一份记录自相矛盾
  if(on)$$('.ps-opt.on',root).forEach(o=>{if(o!==btn&&(btn.dataset.pick==='没有症状'||o.dataset.pick==='没有症状'))o.classList.remove('on');});
  btn.classList.toggle('on',on);btn.setAttribute('aria-pressed',String(on));
 };
 $('#ps-ok').onclick=async e=>{
  const picked=$$('.ps-opt.on',root).map(o=>o.dataset.pick);
  e.currentTarget.disabled=true;
  try{await periodSaveDay(day,{[field]:field==='sex'?picked.map(Number):picked});closeModal();}
  catch(err){toast(err.message);e.currentTarget.disabled=false;}
 };
}
/* 体重/体温：自绘数字键盘，比系统键盘稳（不会被弹起的键盘顶飞、也不用处理小数点和负号） */
function periodNumberSheet(day,field,title,unit,low,high){
 const cur=((periodDayRow(day)||{}).body||{})[field];
 let buf=cur!=null?String(cur):'';
 openModal(title,`<div class="ps-sheet" id="num-sheet"><div class="num-display"><output>${buf||'0'}</output><em>${unit}</em></div><div class="num-pad">${['1','2','3','4','5','6','7','8','9','.','0','del'].map(k=>`<button type="button" class="num-key" data-key="${k}">${k==='del'?'⌫':k}</button>`).join('')}</div><div class="form-actions">${button('取消','close-modal')}<button class="button primary" id="num-ok">确定</button></div></div>`,{sheet:true});
 const out=$('#num-sheet output');
 $('#num-sheet').onclick=e=>{
  const key=e.target.closest('.num-key');if(!key)return;
  const k=key.dataset.key;
  if(k==='del')buf=buf.slice(0,-1);
  else if(k==='.'){if(!buf.includes('.'))buf=(buf||'0')+'.';}
  else if(buf.length<5)buf=buf==='0'?k:buf+k;
  out.textContent=buf||'0';
 };
 $('#num-ok').onclick=async e=>{
  const value=Number(buf||0);
  if(!buf||!Number.isFinite(value)||value<low||value>high)return toast(`${title}需在 ${low}–${high} 之间`);
  e.currentTarget.disabled=true;
  try{await periodSaveDay(day,{[field]:value});closeModal();}
  catch(err){toast(err.message);e.currentTarget.disabled=false;}
 };
}
function periodLogSheet(field,day){
 const b=(periodDayRow(day)||{}).body||{};
 if(field==='content'){
  openModal('这一天的日记',`<form class="modal-form" id="pday-note"><label>想说的话<textarea name="content" maxlength="20000" placeholder="今天特别难受，或者想让他知道的…">${esc(b.content||'')}</textarea></label><p class="small-note">日记只存在这一天里，历史卡上不会重复显示。</p>${formError()}${modalActions()}</form>`,{sheet:true});
  $('#pday-note').onsubmit=async e=>{
   e.preventDefault();const submit=$('button[type=submit]',e.currentTarget);submit.disabled=true;
   try{await periodSaveDay(day,{content:String(new FormData(e.currentTarget).get('content')||'')});closeModal();}
   catch(err){$('.form-error',e.currentTarget).textContent=err.message;submit.disabled=false;}
  };
  return;
 }
 if(field==='flow')
  return periodChoiceSheet(day,'flow','流量',Object.entries(PERIOD_FLOW).map(([v,label])=>[v,label,`<i class="blood" style="--sz:${7+Number(v)*3}px"></i>`]));
 if(field==='color')
  return periodChoiceSheet(day,'color','颜色',Object.entries(PERIOD_COLOR).map(([v,[name,hex]])=>[v,name,'',`background:${hex}`]));
 if(field==='pain')
  return periodChoiceSheet(day,'pain','痛经',Object.entries(PERIOD_PAIN).map(([v,[name,emoji]])=>[v,name,emoji]));
 if(field==='mood')
  return periodChoiceSheet(day,'mood','心情',PERIOD_MOODS.map(([emoji,name],i)=>[i+1,name,emoji]));
 if(field==='sex')return periodSexSheet(day);
 if(field==='symptoms')
  // PERIOD_BODY_SYMPTOMS 是 [名称, 图标]，而 psOption 要 (值, 文案, 图标)，这里补一层
  return periodMultiSheet(day,'symptoms','症状',[['身体症状',PERIOD_BODY_SYMPTOMS.map(([name,emoji])=>[name,name,emoji])],['阴道分泌物',PERIOD_SECRETION.map(([name,emoji])=>[name,name,emoji])]],4);
 if(field==='weight')return periodNumberSheet(day,'weight','体重','公斤',20,300);
 if(field==='temp')return periodNumberSheet(day,'temp','体温','℃',30,45);
 if(field==='discharge'){
  openModal('白带',`<div class="ps-sheet" id="ps-sheet"><div class="ps-list">${Object.entries(PERIOD_DISCHARGE).map(([v,[name,desc]])=>`<button type="button" class="ps-item${String(b.discharge)===v?' on':''}" data-pick="${v}" aria-pressed="${String(b.discharge)===v}"><span class="ps-item-ico">💧</span><span class="ps-item-copy"><strong>${name}</strong><small>${desc}</small></span><i class="ps-radio"></i></button>`).join('')}</div></div>`,{sheet:true});
 $('#ps-sheet').onclick=async e=>{
  const btn=e.target.closest('.ps-item');if(!btn)return;
  try{await periodSaveDay(day,{discharge:Number(btn.dataset.pick)});closeModal();}catch(err){toast(err.message);}
  };
 }
}
function periodPage(){
 const d=periodData(),day=state.periodDay||today();
 /* 生理期不分「我的 / 她的」：两个人共同维护同一条周期，页面长得一样，谁记的都算数。 */
 const hero=d.items.length
  ?`<section class="card period-hero">${cycleHero(d,state.me.user.name)}<p class="meta">下次预计 ${Number(dayStr(d.nextStart).slice(5,7))} 月 ${Number(dayStr(d.nextStart).slice(8))} 日${d.estimated?'（参考值）':''} · ${d.untilNext>=0?`还有 ${d.untilNext} 天`:`已推迟 ${-d.untilNext} 天`}</p>${phaseBar(d)}<div class="stats-hero" style="grid-template-columns:repeat(3,minmax(0,1fr));margin:14px 0 0"><div class="stat-card"><span>平均周期</span><strong>${d.cycle}<em>天</em></strong></div><div class="stat-card"><span>平均经期</span><strong>${d.length}<em>天</em></strong></div><div class="stat-card"><span>记录天数</span><strong>${periodDayRows().length}<em>天</em></strong></div></div></section>`
  :`<section class="card"><div class="section-heading"><h2>🌸 开始记录</h2></div><p class="meta">点下面「月经来了 · 是」，把这次的第一天记下来；之后每天顺手记一点，周期会越来越准。谁记都行，两个人看到的是同一份。</p></section>`;
 /* 顺序：主视觉卡 → 整月日历 → 当天记录。日历只留这一份，下面不再重复 */
 const top=`<section class="card period-top-card">${periodTopCard(d)}</section>`;
 const log=periodLogCard(day);
 const spread=d.gaps.length>1?Math.max(...d.gaps)-Math.min(...d.gaps):0;
 const symCount={};
 periodDayRows().forEach(r=>(r.body.symptoms||[]).forEach(s=>{if(s!=='没有症状')symCount[s]=(symCount[s]||0)+1;}));
 d.items.forEach(r=>(r.body.symptoms||[]).forEach(s=>{if(s!=='没有症状')symCount[s]=(symCount[s]||0)+1;}));
 const syms=Object.entries(symCount).sort((a,b)=>b[1]-a[1]).slice(0,6);
 const total=Math.max(1,periodDayRows().length+d.episodes.length);
 const symBlock=syms.length?`<section class="card"><div class="section-heading"><h2>常出现的症状</h2></div>${syms.map(([s,n])=>`<div class="stat-row"><span>${esc(s)}</span><div class="stat-bar"><i style="width:${Math.round(n/total*100)}%"></i></div><b>${n} 次</b></div>`).join('')}<p class="small-note">${spread>7?`周期波动 ${spread} 天，波动大的时候多留一点休息的时间。`:'周期还算规律，保持记录会更准。'}</p></section>`:'';
 /* 一次月经一张卡：碎片行在统计上已经合并，列表里再拆成两三条只会让人以为记错了。
   「编辑 / 删除」对整次生效——删除会把这次的所有碎片行一起删掉。 */
 const hist=d.episodes.slice().reverse().map(e=>{
  const startIso=dayStr(e.start),endIso=dayStr(e.end),len=e.length;
  const logs=periodDayRows().filter(x=>{const n=dayNum(x.body.date);return n>=e.start&&n<=e.end;}).length;
  const author=e.frags[0].author;
  const symsAll=[...new Set(e.frags.flatMap(r=>r.body.symptoms||[]))];
  const words=e.frags.map(r=>r.body.content).filter(Boolean).join('\n');
  const ids=e.frags.map(r=>r.id).join(',');
  return `<article class="card"><div class="card-header">${avatar(author)}<div><strong>${esc(startIso.slice(5,7))} 月 ${esc(startIso.slice(8))} 日开始</strong><small>共 ${len} 天 · ${endIso.slice(5)} 结束${logs?` · 记了 ${logs} 天细节`:''}${e.frags.length>1?` · 分 ${e.frags.length} 段记的`:''} · ${esc(person(author).name)} 记录</small></div><div class="card-menu"><details class="more-menu"><summary aria-label="更多操作" title="更多操作">⋯</summary><div class="menu-pop"><button data-action="edit-record" data-id="${e.frags[0].id}">${icon('edit')} 编辑</button><button data-action="period-del-episode" data-ids="${ids}" class="danger">${icon('trash')} 删除这次</button></div></details></div></div>${symsAll.length?`<div class="tabs" style="flex-wrap:wrap;margin:8px 0 0">${symsAll.map(s=>`<span class="filter-chip">${esc(s)}</span>`).join('')}</div>`:''}${words?`<p class="card-text">${esc(words)}</p>`:''}</article>`;
 }).join('');
 /* 右上角不再放「记录经期」：记经期已经由下面记录卡的「月经来了 / 月经走了」接管，
    一个动作两个入口只会让人点错。这里换成进入数据分析页的入口。 */
 const headBar=heading('生理期','记下周期，把照顾提前一点。','');
 // 踩线才提示：正常的时候这块根本不存在，不占地方
 const warns=periodWarnings(d);
 const warnBlock=warns.length?`<section class="card period-warn"><strong>有几点需要留意</strong><ul>${warns.map(w=>`<li>${esc(w)}</li>`).join('')}</ul><small>按记录推算的提示，身体不舒服还是去看医生。</small></section>`:'';
 const entry=`<button type="button" class="card analysis-entry" data-action="period-analysis"><span class="ae-ico">📊</span><span class="ae-copy"><strong>数据分析</strong><small>周期、流量、痛经、体温的变化</small></span><span class="ae-go">${icon('arrow')}</span></button>`;
 return `${headBar}${hero}${warnBlock}${entry}${top}${log}${symBlock}${hist}`;
}
/* ───────────── 生理数据分析 ─────────────
   美柚那套「分析」页有十几个板块，这里按我们真正记过的维度落：数据完整度、规律度、
   预测、周期/经期变化、流量、痛经、颜色、症状、心情、白带、爱爱、体温、体重。
   （没有「便便」「开始时间」——我们没这两个字段，硬凑只会是空图。）
   图表全部手画 SVG/div，不引 Chart.js：离线 PWA 不能把核心页面挂在 CDN 上。 */
const PA_PURPLE='#A98BD8';
const paMean=a=>a.length?a.reduce((s,v)=>s+v,0)/a.length:0;
const paSd=a=>{if(a.length<2)return 0;const m=paMean(a);return Math.sqrt(paMean(a.map(v=>(v-m)**2)));};
const paRound=(v,n=0)=>{const p=10**n;return Math.round(v*p)/p;};
const paMD=s=>`${Number(String(s).slice(5,7))} 月 ${Number(String(s).slice(8,10))} 日`;

/* 分组柱：每天一组，左边本周期、右边近半年；没记的那根画虚线空框（照美柚的「未记录」） */
function paGrouped(rows,opt={}){
 const W=320,h=opt.h||(rows.length<=2?84:104),top=10,base=h-22,n=rows.length||1,slot=W/n;
 const max=opt.max||Math.max(1,...rows.flatMap(r=>[r.cur,r.hist]).filter(v=>typeof v==='number'));
 const bw=Math.min(12,slot*0.26);
 const y=v=>base-(base-top)*(v/max);
 const bar=(x,v,fill)=>typeof v==='number'&&v>0
  ?`<rect x="${x.toFixed(1)}" y="${y(v).toFixed(1)}" width="${bw.toFixed(1)}" height="${(base-y(v)).toFixed(1)}" rx="3" fill="${fill}"/>`
  :`<rect x="${x.toFixed(1)}" y="${base-18}" width="${bw.toFixed(1)}" height="18" rx="3" fill="none" stroke="var(--line)" stroke-dasharray="3 3"/>`;
 return `<svg class="pa-svg" viewBox="0 0 ${W} ${h}" width="100%" height="${h}" role="img" aria-label="${esc(opt.aria||'')}">`
  +[0,.5,1].map(f=>`<line x1="0" x2="${W}" y1="${(top+(base-top)*f).toFixed(1)}" y2="${(top+(base-top)*f).toFixed(1)}" stroke="var(--line)" stroke-dasharray="2 4"/>`).join('')
  +rows.map((r,i)=>{const c=slot*i+slot/2;
    return bar(c-bw-2,r.cur,'var(--primary)')+bar(c+2,r.hist,PA_PURPLE)
     +`<text x="${c.toFixed(1)}" y="${base+14}" text-anchor="middle" class="pa-tick">${esc(r.label)}</text>`;}).join('')
  +`</svg>`;
}
/* 单系列竖柱：近期经期天数、每月爱爱次数 */
function paVBars(rows,opt={}){
 const W=320,h=opt.h||(rows.length<=3?86:96),top=12,base=h-22,n=rows.length||1,slot=W/n;
 const max=opt.max||Math.max(1,...rows.map(r=>r.v||0));
 const bw=Math.min(18,slot*0.44);
 return `<svg class="pa-svg" viewBox="0 0 ${W} ${h}" width="100%" height="${h}" role="img" aria-label="${esc(opt.aria||'')}">`
  +`<line x1="0" x2="${W}" y1="${base}" y2="${base}" stroke="var(--line)"/>`
  +rows.map((r,i)=>{const c=slot*i+slot/2,v=r.v||0,hh=(base-top)*(v/max);
    // 0 也留一小截底色，否则连续几个空月看起来像图坏了
    const h1=v>0?hh:3;
    return `<rect x="${(c-bw/2).toFixed(1)}" y="${(base-h1).toFixed(1)}" width="${bw.toFixed(1)}" height="${h1.toFixed(1)}" rx="4" fill="${v>0?(r.now?'var(--primary)':'var(--soft-strong)'):'var(--line)'}"/>`
     +(v?`<text x="${c.toFixed(1)}" y="${(base-hh-6).toFixed(1)}" text-anchor="middle" class="pa-val">${v}</text>`:'')
     +`<text x="${c.toFixed(1)}" y="${base+14}" text-anchor="middle" class="pa-tick">${esc(r.label)}</text>`;}).join('')
  +`</svg>`;
}
/* 折线：体温 / 体重。只在首尾与最高最低处标数值，避免一串数字糊成一片 */
function paLine(pts,opt={}){
 const list=(pts||[]).filter(p=>typeof p.v==='number');
 if(list.length<2)return '';
 const W=320,h=opt.h||104,top=18,base=h-22;
 let lo=Math.min(...list.map(p=>p.v)),hi=Math.max(...list.map(p=>p.v));
 if(hi-lo<.4){hi+=.2;lo-=.2;}
 const X=p=>18+(W-36)*p.i/(list.length-1);
 const Y=v=>base-(base-top)*((v-lo)/(hi-lo));
 const color=opt.color||'#2F9E88';
 const marked=new Set([0,list.length-1,list.findIndex(p=>p.v===hi),list.findIndex(p=>p.v===lo)]);
 return `<svg class="pa-svg" viewBox="0 0 ${W} ${h}" width="100%" height="${h}" role="img" aria-label="${esc(opt.aria||'')}">`
  +`<line x1="0" x2="${W}" y1="${base}" y2="${base}" stroke="var(--line)"/>`
  +`<path d="${list.map((p,k)=>(k?'L':'M')+X(p).toFixed(1)+' '+Y(p.v).toFixed(1)).join(' ')}" fill="none" stroke="${color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`
  +list.map(p=>`<circle cx="${X(p).toFixed(1)}" cy="${Y(p.v).toFixed(1)}" r="3.5" fill="var(--surface)" stroke="${color}" stroke-width="2"/>`).join('')
  +list.map((p,k)=>marked.has(k)?`<text x="${X(p).toFixed(1)}" y="${(Y(p.v)-8).toFixed(1)}" text-anchor="middle" class="pa-val">${esc(opt.fmt?opt.fmt(p.v):p.v)}</text>`:'').join('')
  +`<text x="2" y="${base+13}" class="pa-tick">${esc(list[0].label)}</text>`
  +`<text x="${W-2}" y="${base+13}" text-anchor="end" class="pa-tick">${esc(list[list.length-1].label)}</text>`
  +`</svg>`;
}
/* 圆点矩阵：颜色、白带这种「一天一个颜色」的，用两行点比画柱状图直观 */
function paDotRows(rows){
 return `<div class="pa-dotmatrix">${rows.map(r=>`<div class="pa-dotrow"><span class="pa-dotlabel">${esc(r.name)}</span><div class="pa-dots">${r.cells.map(c=>c.color
   ?`<i class="pa-dot" style="background:${c.color}" title="${esc(c.tip||'')}"></i>`
   :`<i class="pa-dot hollow" title="${esc(c.tip||'')}"></i>`).join('')}</div></div>`).join('')}</div>`;
}

/* 把「经期段 + 日记录」摊成统计口径。所有 第N天 的序列都以「经期第几天」为横轴，
   这样不同长度的周期也能横向对齐——这也是美柚那套图能对比的原因。 */
function periodAnalysis(d){
 const eps=d.episodes||[],logs=periodDayLogs();
 const at=n=>logs[dayStr(n)]||null;
 const last=eps[eps.length-1]||null,prev=eps[eps.length-2]||null;
 const FIELDS=['flow','color','pain','sex','symptoms','mood','weight','discharge','temp'];
 // 数据完整度：经期里每一天都算一格，记了至少一项算填上
 let slots=0,filled=0;
 eps.forEach(e=>{for(let i=0;i<e.length;i++){slots++;const b=at(e.start+i);
  if(b&&FIELDS.some(k=>Array.isArray(b[k])?b[k].length:b[k]!=null&&b[k]!==''))filled++;}});
 const complete=slots?Math.round(filled/slots*100):0;
 const maxLen=Math.min(7,Math.max(1,...eps.map(e=>e.length)));
 const nth=key=>{
  const rows=[];
  for(let i=0;i<maxLen;i++){
   const cb=last&&i<last.length?at(last.start+i):null,cur=cb?(typeof cb[key]==='number'?cb[key]:null):null;
   const hist=eps.filter(e=>e!==last&&i<e.length).map(e=>at(e.start+i)?.[key]).filter(v=>typeof v==='number');
   if(cur==null&&!hist.length)continue;
   rows.push({label:`第${i+1}天`,cur,hist:hist.length?paRound(paMean(hist)):null});
  }
  return rows;
 };
 const nthColor=()=>{
  const n=Math.min(5,Math.max(1,...eps.map(e=>e.length))),cur=[],his=[];
  for(let i=0;i<n;i++){
   cur.push(last&&i<last.length?(at(last.start+i)?.color??null):null);
   const h=eps.filter(e=>e!==last&&i<e.length).map(e=>at(e.start+i)?.color).filter(v=>typeof v==='number');
   // 取众数：同一天在不同周期里颜色不一致时，代表值是"最常见的那一种"
   his.push(h.length?h.slice().sort((a,b)=>h.filter(v=>v===b).length-h.filter(v=>v===a).length)[0]:null);
  }
  return {cur,his,n};
 };
 const nthDischarge=()=>{
  const n=Math.min(5,Math.max(1,...eps.map(e=>e.length))),cur=[],his=[];
  for(let i=0;i<n;i++){
   cur.push(last&&i<last.length?(at(last.start+i)?.discharge??null):null);
   const h=eps.filter(e=>e!==last&&i<e.length).map(e=>at(e.start+i)?.discharge).filter(v=>typeof v==='number');
   his.push(h.length?paRound(paMean(h)):null);
  }
  return {cur,his,n};
 };
 const keySeries=(key,limit=12)=>{
  const rows=periodDayRows().filter(r=>typeof r.body[key]==='number')
   .sort((a,b)=>String(a.body.date).localeCompare(String(b.body.date)));
  return rows.slice(-limit).map(r=>({label:String(r.body.date).slice(5,10).replace('-','/'),v:r.body[key]}));
 };
 // 周期行：从新到旧。长度要记在「这一段开始的日子」上——09-29 那次到 10-26 是 27 天，
 // 所以 27 天属于 09-29 这一行；最后一段还没结束，只报「当前第 N 天」。
 const cycleRows=[];
 for(let i=eps.length-1;i>=0;i--){
  const e=eps[i],next=eps[i+1];
  if(next)cycleRows.push({date:e.start,gap:next.start-e.start});
  else cycleRows.push({cur:true,date:e.start,days:d.todayN-e.start+1});
 }
 const cycleMax=Math.max(1,...cycleRows.map(r=>r.cur?r.days:r.gap));
 // 近 6 个月爱爱
 const sexRows=periodDayRows().filter(r=>Array.isArray(r.body.sex)&&r.body.sex.length);
 const sexCount=sexRows.reduce((s,r)=>s+r.body.sex.length,0);
 const sexThisCycle=last?sexRows.filter(r=>{const n=dayNum(r.body.date);return n>=last.start&&n<=last.end;})
   .reduce((s,r)=>s+r.body.sex.length,0):0;
 const monthly=[];
 const y0=Number(today().slice(0,4)),m0=Number(today().slice(5,7));
 for(let k=5;k>=0;k--){
  let mm=m0-k,yy=y0;while(mm<1){mm+=12;yy-=1;}
  const pre=`${yy}-${String(mm).padStart(2,'0')}`;
  monthly.push({label:`${mm}月`,v:sexRows.filter(r=>String(r.body.date).slice(0,7)===pre)
    .reduce((s,r)=>s+r.body.sex.length,0),now:k===0});
 }
 const symCount={};
 periodDayRows().concat(eps.map(e=>e.rec)).forEach(r=>(r.body.symptoms||[]).forEach(s=>{
  if(s!=='没有症状')symCount[s]=(symCount[s]||0)+1;}));
 const moodCount={};
 periodDayRows().forEach(r=>{if(r.body.mood)moodCount[r.body.mood]=(moodCount[r.body.mood]||0)+1;});
 // 规律度：只看周期波动。样本 <3 个间隔时给参考值，别硬编一个分数骗人
 const sd=paSd(d.gaps);
 const score=d.gaps.length>=2?Math.min(99,Math.max(40,Math.round(100-Math.min(45,Math.max(0,(sd-1.5)*6))))):null;
 return {eps,last,prev,complete,slots,filled,flow:nth('flow'),pain:nth('pain'),
  color:nthColor(),discharge:nthDischarge(),cycleRows,cycleMax,
  sexCount,sexThisCycle,monthly,symCount,moodCount,sd,score,
  temp:keySeries('temp'),weight:keySeries('weight')};
}

/* 分析页本体：一个板块一块卡，顺序照「先结论后细节」排。 */
const PA_DIS_COLORS={1:'#CFBBA6',2:'#B9A183',3:'#E0C58F',4:'#A6D5E4',5:'#78C4D8'};
function periodAnalysisPage(){
 const d=periodData(),a=periodAnalysis(d);
 /* 返回走顶栏那个箭头（together 的子页都这样），页面里不再重复放一个 */
 const back=`<div class="page-heading"><div><h1>生理数据分析</h1><p>把这半年的记录，摊成看得懂的变化。</p></div></div>`;
 if(!a.eps.length)return back+`<section class="card"><p class="meta">还没有经期记录。回到生理期页点一次「月经来了」，这里就会开始长出图表。</p><div class="inline-actions">${button('回到生理期','period-back','primary')}</div></section>`;
 const sec=(h2,body,sub='')=>`<section class="card pa-card"><div class="section-heading"><h2>${h2}</h2>${sub?`<span class="pa-sub">${esc(sub)}</span>`:''}</div>${body}</section>`;
 const legend=items=>`<p class="pa-legend">${items.map(([c,t,empty])=>`<span><i class="pa-lg-dot${empty?' hollow':''}" style="${empty?'':`background:${c}`}"></i>${esc(t)}</span>`).join('')}</p>`;
 const warns=periodWarnings(d);

 /* ① 概览：规律度 + 数据完整度 + 三个基本盘 */
 const grade=a.score==null?'样本还太少':a.score>=85?'很规律':a.score>=70?'比较规律':a.score>=55?'有些波动':'波动明显';
 const note=a.score==null?'至少记满 3 个完整周期，规律度才有意义。'
   :a.score>=85?'继续保持，预测会越来越准。'
   :`周期波动 ${paRound(a.sd,1)} 天，预测日期按前后 ±${Math.max(2,Math.round(a.sd))} 天准备更稳妥。`;
 const overview=`<section class="card pa-overview">
  <div class="pa-hero-row">
   <div class="pa-ring" style="background:conic-gradient(var(--primary) ${(a.score||0)*3.6}deg, var(--soft) 0)"><span><b>${a.score==null?'--':a.score}</b><small>规律度</small></span></div>
   <div class="pa-hero-copy"><h3>${grade}</h3><p>${esc(note)}</p>
    <div class="pa-meter"><i style="width:${a.complete}%"></i></div>
    <small>完整度 ${a.complete}%　·　已记 ${a.filled}/${a.slots} 天</small></div>
  </div>
  <div class="pa-stats">
   <div><span>平均周期</span><strong>${d.cycle}<em>天</em></strong></div>
   <div><span>平均经期</span><strong>${d.length}<em>天</em></strong></div>
   <div><span>记录天数</span><strong>${periodDayRows().length}<em>天</em></strong></div>
  </div>
  ${warns.length?`<div class="pa-warns"><strong>需要留意</strong>${warns.map(w=>`<p>${esc(w)}</p>`).join('')}<small>按记录推算，不能替代医生判断。</small></div>`:''}
  <p class="pa-mini">受孕概率为日历推算（低 / 中 / 高），不能作为避孕依据。</p>
  </section>`;

 /* ② 经期预测：一周日期条，正中那天是预测日，左右两天算"可能" */
 const pred=(()=>{
  if(d.nextStart==null)return '';
  const cells=[];
  for(let i=-3;i<=3;i++){
   const n=d.nextStart+i,iso=dayStr(n),cls=i===0?' on':Math.abs(i)<=2?' soft':'';
   const wd='日一二三四五六'[new Date(n*DAY_MS).getUTCDay()];
   cells.push(`<span class="pa-day${cls}"><b>${Number(iso.slice(8))}</b><small>周${wd}</small></span>`);
  }
  const due=d.untilNext;
  return sec('🔮 经期预测',
   `<p class="pa-lead">预测下次经期将于 <b>${paMD(dayStr(d.nextStart))}</b> 开始，${due>=0?`距离经期开始还有 <b>${due}</b> 天`:`已经推迟 <b>${-due}</b> 天`}。</p>
    <div class="pa-week">${cells.join('')}</div>
    <p class="pa-legend"><span><i class="pa-lg-dot" style="background:var(--primary)"></i>预测开始日</span><span><i class="pa-lg-dot" style="background:var(--soft-strong)"></i>可能的开始日</span></p>`,
   d.estimated?'参考值':'');
 })();

 /* ③ 周期变化：最近一个周期 + 历史横向条 */
 const cycleSec=(()=>{
  const rows=a.cycleRows.slice(0,6).map(r=>{
   if(r.cur)return `<div class="pa-row"><span class="pa-date">${paMD(dayStr(r.date))}</span><span class="pa-chip">当前第 ${r.days} 天</span><span class="pa-track"><i style="width:${Math.round(r.days/a.cycleMax*100)}%"></i></span><b>${r.days}天</b></div>`;
   const diff=r.gap-Math.round(d.cycle);
   return `<div class="pa-row"><span class="pa-date">${paMD(dayStr(r.date))}</span><span class="pa-diff${diff<0?' early':diff>0?' late':''}">${diff===0?'准时':diff<0?`提前 ${-diff} 天`:`推迟 ${diff} 天`}</span><span class="pa-track"><i style="width:${Math.round(r.gap/a.cycleMax*100)}%"></i></span><b>${r.gap}天</b></div>`;
  }).join('');
  const gapNow=a.eps.length>1?a.eps[a.eps.length-1].start-a.eps[a.eps.length-2].start:null;
  const diffNow=gapNow==null?null:gapNow-Math.round(d.cycle);
  const range=a.eps.length>1?`${paMD(dayStr(a.eps[a.eps.length-2].start))} – ${paMD(dayStr(a.eps[a.eps.length-1].start-1))}`:'';
  const kpi=gapNow==null?'':`<div class="pa-kpi"><div><span>最近 1 个周期</span><strong>${gapNow} 天 <em class="pa-tag${gapNow>=21&&gapNow<=35?'':' warn'}">${gapNow>=21&&gapNow<=35?'正常':'需留意'}</em></strong></div>
   <div><span>比平均周期</span><strong>${diffNow===0?'相同':diffNow<0?`短 ${-diffNow} 天`:`长 ${diffNow} 天`}</strong></div></div>`;
  return sec('🗓 周期变化',kpi+`<p class="pa-mini">近期周期天数${range?`　·　最近一次 ${range}`:''}</p><div class="pa-list">${rows}</div>`);
 })();

 /* ④ 经期变化：本次天数 + 近期柱状 */
 const lenSec=(()=>{
  const bars=a.eps.slice(-6).map((e,i,arr)=>({label:`${Number(dayStr(e.start).slice(5,7))}/${Number(dayStr(e.start).slice(8))}`,v:e.length,now:i===arr.length-1}));
  const lastLen=a.last?a.last.length:0,prevLen=a.prev?a.prev.length:null;
  const diff=prevLen==null?null:lastLen-prevLen;
  return sec('💧 经期变化',
   `<div class="pa-kpi"><div><span>本次经期</span><strong>${lastLen} 天 <em class="pa-tag${lastLen>=2&&lastLen<=7?'':' warn'}">${lastLen>=2&&lastLen<=7?'正常':'需留意'}</em></strong></div>
     <div><span>和上个周期</span><strong>${diff==null?'—':diff===0?'相同':diff>0?`多 ${diff} 天`:`少 ${-diff} 天`}</strong></div></div>
    <p class="pa-mini">近期经期天数</p>${paVBars(bars,{aria:'近期每次经期的天数'})}`);
 })();

 /* ⑤ 流量 / ⑥ 痛经：同一套分组柱，两边的档位都是 1–5 */
 const flowRows=a.flow;
 const flowText=(()=>{
  const cur=flowRows.filter(r=>r.cur!=null),his=flowRows.filter(r=>r.hist!=null);
  if(!cur.length)return '这个周期还没记流量';
  if(!his.length)return '再多记一次经期，就能和近半年对比';
  const x=paMean(cur.map(r=>r.cur)),y=paMean(his.map(r=>r.hist)),dd=x-y;
  return Math.abs(dd)<.4?'和近半年差不多':dd>0?`比近半年偏多一点（约高 ${paRound(dd,1)} 档）`:`比近半年偏少一点（约低 ${paRound(Math.abs(dd),1)} 档）`;
 })();
 const flowSec=flowRows.length?sec('🩸 流量变化',
  `<p class="pa-kpi-line">本周期流量对比近半年：<b>${esc(flowText)}</b></p>${paGrouped(flowRows,{max:5,aria:'按经期第几天对比本周期与近半年的经量档位'})}${legend([['var(--primary)','本周期'],['#A98BD8','近半年'],['','未记录',1]])}`):'';

 const painRows=a.pain;
 const painText=(()=>{
  const cur=painRows.filter(r=>r.cur!=null);
  if(!cur.length)return '这个周期还没记痛经';
  const peak=cur.slice().sort((x,y)=>(y.cur||0)-(x.cur||0))[0];
  if(!peak.cur)return '这个周期完全没痛，挺好的';
  const nm=(PERIOD_PAIN[peak.cur]||[])[0]||'';
  return `这个周期最痛是「${nm}」，出现在${peak.label}`;
 })();
 const painSec=painRows.length?sec('⚡ 痛经情况',
  `<p class="pa-kpi-line">${esc(painText)}</p><div class="pa-offset">${paGrouped(painRows,{max:5,aria:'按经期第几天对比本周期与近半年的痛经程度'})}</div>${legend([['var(--primary)','本周期'],['#A98BD8','近半年'],['','未记录',1]])}`):'';

 /* ⑦ 颜色变化：一天一个点 */
 const colBuf=a.color,usedColors=new Set([...colBuf.cur,...colBuf.his].filter(Boolean));
 const colorSec=usedColors.size?sec('🎨 颜色变化',
  `${paDotRows([{name:'本周期',cells:colBuf.cur.map((v,i)=>({color:v?PERIOD_COLOR[v][1]:null,tip:v?`第${i+1}天 ${PERIOD_COLOR[v][0]}`:`第${i+1}天未记录`}))},
    {name:'近半年',cells:colBuf.his.map((v,i)=>({color:v?PERIOD_COLOR[v][1]:null,tip:v?`第${i+1}天 ${PERIOD_COLOR[v][0]}`:`第${i+1}天未记录`}))}])}
   ${legend([...usedColors].map(v=>[PERIOD_COLOR[v][1],PERIOD_COLOR[v][0]]).concat([['','未记录',1]]))}`):'';

 /* ⑧ 症状排行：沿用工具页的 .stat-row，不另造图表 */
 const syms=Object.entries(a.symCount).sort((x,y)=>y[1]-x[1]).slice(0,6);
 const symSec=syms.length?sec('💊 常出现的症状',
  syms.map(([s,n])=>`<div class="stat-row"><span>${esc(s)}</span><div class="stat-bar"><i style="width:${Math.round(n/syms[0][1]*100)}%"></i></div><b>${n} 次</b></div>`).join('')):'';

 /* ⑨ 心情 */
 const moods=Object.entries(a.moodCount).sort((x,y)=>y[1]-x[1]).slice(0,8);
 const moodSec=moods.length?sec('😊 心情',
  `<div class="pa-chips">${moods.map(([id,n])=>{const m=PERIOD_MOODS[Number(id)-1]||['🙂','心情'];return `<span class="pa-chip-mood"><i>${m[0]}</i>${esc(m[1])}<b>${n}</b></span>`;}).join('')}</div>
   <p class="pa-mini">共 ${Object.values(a.moodCount).reduce((s,n)=>s+n,0)} 次心情记录</p>`):'';

 /* ⑩ 白带：点阵，颜色按 5 档 */
 const disBuf=a.discharge;
 const disSec=(disBuf.cur.some(Boolean)||disBuf.his.some(Boolean))?sec('💧 白带变化',
  `${paDotRows([{name:'本周期',cells:disBuf.cur.map((v,i)=>({color:v?PA_DIS_COLORS[v]:null,tip:v?`第${i+1}天 ${PERIOD_DISCHARGE[v][0]}`:`第${i+1}天未记录`}))},
    {name:'近半年',cells:disBuf.his.map((v,i)=>({color:v?PA_DIS_COLORS[v]:null,tip:v?`第${i+1}天 ${PERIOD_DISCHARGE[v][0]}`:`第${i+1}天未记录`}))}])}
   ${legend(Object.entries(PERIOD_DISCHARGE).map(([v,it])=>[PA_DIS_COLORS[v],it[0]]).concat([['','未记录',1]]))}`):'';

 /* ⑪ 爱爱 */
 const sexSec=sec('💗 爱爱',
  `<p class="pa-kpi-line">本周期 <b>${a.sexThisCycle}</b> 次，累计 <b>${a.sexCount}</b> 次</p>
   <p class="pa-mini">近 6 个月</p>${paVBars(a.monthly,{aria:'近 6 个月每个月的次数'})}`);

 /* ⑫ 体温 / ⑬ 体重：有两次以上记录才画线 */
 const tempSec=a.temp.length>1?sec('🌡️ 体温',paLine(a.temp.map((p,i)=>({...p,i})),{color:'#2F9E88',fmt:v=>v.toFixed(1)+'℃',aria:'体温记录折线'})):'';
 const weightSec=a.weight.length>1?sec('⚖️ 体重',paLine(a.weight.map((p,i)=>({...p,i})),{color:'#7A93C4',fmt:v=>v.toFixed(1),aria:'体重记录折线'})):'';

 const tips=`<p class="small-note pa-foot">图表只反映记过的那几天。想让它更准，经期每天顺手点两下就够了。</p>`;
 return `${back}${overview}${pred}${cycleSec}${lenSec}${flowSec}${painSec}${colorSec}${symSec}${moodSec}${disSec}${sexSec}${tempSec}${weightSec}${tips}`;
}

function periodForm(record=null, presetDay=null){
 /* 这一层只管「这次经期从哪天到哪天」；每天的身体细节走日记录卡。
    presetDay：从日历格子点进来的那天，直接预填到「这次经期开始于」。 */
 const b=record?.body||{},d=periodData(),chosen=new Set(b.symptoms||[]);
 const chips=PERIOD_SYMPTOMS.map(s=>`<button type="button" class="sym-chip${chosen.has(s)?' on':''}" data-name="${s}" aria-pressed="${chosen.has(s)}">${s}</button>`).join('');
 // 老数据里 flow 是「少/中/多」，换成最近的档位显示，不至于打开就是空白
 const flowVal=typeof b.flow==='number'?b.flow:({'少':2,'中':3,'多':4}[b.flow]||'');
 openModal(record?'编辑这次经期':'记录这次经期',`<form class="modal-form" id="period-form">${field('这次经期开始于','start',b.start||presetDay||today(),'date','required')}<div class="form-row">${field('经期几天','length',b.length??d.length,'number','min="1" max="15"')}${field('周期几天','cycle',b.cycle??d.cycle,'number','min="15" max="60"')}</div>${selectField('整体经量','flow',[['','不记'],...Object.entries(PERIOD_FLOW)],flowVal)}<label>身体的感受（可多选）</label><div class="sym-chips">${chips}</div><label>想说的话（可选）<textarea name="content" maxlength="20000" placeholder="这次特别难受，或者想让他知道的…">${esc(b.content||'')}</textarea></label><p class="small-note">周期默认按历史记录的平均值填好，也可以手动改。数据加密保存，两个人一起维护同一条周期。</p>${formError()}${modalActions()}</form>`);
 $('#period-form').onclick=e=>{const chip=e.target.closest('.sym-chip');if(!chip)return;chip.classList.toggle('on');chip.setAttribute('aria-pressed',String(chip.classList.contains('on')));};
 $('#period-form').onsubmit=async e=>{
  e.preventDefault();const form=e.currentTarget,submit=$('button[type=submit]',form);
  submit.disabled=true;
  try{
   const f=new FormData(form);
   const flow=f.get('flow');
   const body={start:f.get('start'),length:Number(f.get('length')||5),cycle:Number(f.get('cycle')||d.cycle),
    ...(flow?{flow:Number(flow)}:{}),symptoms:$$('.sym-chip.on',form).map(c=>c.dataset.name),
    content:String(f.get('content')||'')};
   if(record)await put('/records/'+record.id,{kind:'period',body});
   else await post('/records',{kind:'period',body,client_id:uuid()});
   closeModal();await refresh();toast('已记下这次');
  }catch(err){$('.form-error',form).textContent=err.message;}
  finally{submit.disabled=false;}
 };
}
