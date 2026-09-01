(function(){
const T=THREE, app=document.getElementById('app');
const W=()=>app.clientWidth, H=()=>app.clientHeight;
const COL={lidar:0x38D6F0, radar:0xF5A623, camera:0x3DDC84, gnss:0xFF6B8A, acu:0x9B8CFF};
const hex=n=>'#'+n.toString(16).padStart(6,'0');

// sensor suite (positioned on the ROii footprint; no car body drawn)
const SENS=[
 {id:'lidar', nm:'LiDAR', shape:'cyl',  ty:'lidar',  pos:[0,1.42,-0.1], model:'Ouster OS1-64', range:'120 m', rate:'900 Mb/s', zone:'Rear ZCU'},
 {id:'radF',  nm:'Radar F', shape:'box', ty:'radar',  pos:[0,0.5,2.08],  dir:[0,0,1],  model:'LRR', range:'170 m', rate:'CAN-FD', zone:'Front-L'},
 {id:'radFL', nm:'Radar FL',shape:'box', ty:'radar',  pos:[-0.86,0.5,1.9],dir:[-0.7,0,0.7],model:'SRR', range:'80 m', rate:'CAN-FD', zone:'Front-L'},
 {id:'radFR', nm:'Radar FR',shape:'box', ty:'radar',  pos:[0.86,0.5,1.9], dir:[0.7,0,0.7], model:'SRR', range:'80 m', rate:'CAN-FD', zone:'Front-R'},
 {id:'radRL', nm:'Radar RL',shape:'box', ty:'radar',  pos:[-0.86,0.5,-1.95],dir:[-0.7,0,-0.7],model:'SRR', range:'80 m', rate:'CAN-FD', zone:'Rear ZCU'},
 {id:'radRR', nm:'Radar RR',shape:'box', ty:'radar',  pos:[0.86,0.5,-1.95],dir:[0.7,0,-0.7], model:'SRR', range:'80 m', rate:'CAN-FD', zone:'Rear ZCU'},
 {id:'camF',  nm:'Cam F',   shape:'cam', ty:'camera', pos:[0,1.05,0.55], dir:[0,0,1],   model:'8 MP', range:'120 m', rate:'GMSL2', zone:'Front-L'},
 {id:'camFL', nm:'Cam ML',  shape:'cam', ty:'camera', pos:[-0.92,0.95,0.65],dir:[-0.85,0,0.2],model:'Mirror', range:'40 m', rate:'GMSL2', zone:'Front-L'},
 {id:'camFR', nm:'Cam MR',  shape:'cam', ty:'camera', pos:[0.92,0.95,0.65], dir:[0.85,0,0.2], model:'Mirror', range:'40 m', rate:'GMSL2', zone:'Front-R'},
 {id:'camR',  nm:'Cam R',   shape:'cam', ty:'camera', pos:[0,0.95,-2.05], dir:[0,0,-1],  model:'Rear', range:'50 m', rate:'GMSL2', zone:'Rear ZCU'},
 {id:'gnss',  nm:'GNSS/IMU',shape:'puck',ty:'gnss',   pos:[0.35,1.4,-0.75],           model:'RTK', range:'—', rate:'2 Mb/s', zone:'Front-R'},
];
const ICON={lidar:'<circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/>',radar:'<path d="M12 12L3 6"/><circle cx="12" cy="12" r="2.5"/><path d="M12 12a10 10 0 0 1 8 4" fill="none"/>',camera:'<rect x="3" y="7" width="13" height="10" rx="2"/><path d="M16 10l5-3v10l-5-3"/>',gnss:'<circle cx="12" cy="10" r="3"/><path d="M12 13v8M8 21h8"/>',acu:'<rect x="5" y="5" width="14" height="14" rx="2"/><path d="M9 9h6v6H9z"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>'};

// renderer/scene/camera
const renderer=new T.WebGLRenderer({antialias:true}); renderer.setPixelRatio(Math.min(devicePixelRatio,2));
renderer.setSize(W(),H()); renderer.shadowMap.enabled=true; renderer.shadowMap.type=T.PCFSoftShadowMap; app.appendChild(renderer.domElement);
const scene=new T.Scene(); scene.background=new T.Color(0x0A0D13); scene.fog=new T.Fog(0x0A0D13,16,42);
const camera=new T.PerspectiveCamera(42,W()/H(),0.1,200);
const controls=new THREE.OrbitControls(camera,renderer.domElement); controls.enableDamping=true; controls.dampingFactor=.07;
controls.minDistance=4; controls.maxDistance=20; controls.maxPolarAngle=Math.PI*0.5-0.02; controls.target.set(0,0.6,0);
scene.add(new T.HemisphereLight(0x9fc0ff,0x0a0d13,0.5));
const key=new T.DirectionalLight(0xffffff,1.2); key.position.set(6,11,7); key.castShadow=true; key.shadow.mapSize.set(2048,2048);
key.shadow.camera.near=1;key.shadow.camera.far=40;key.shadow.camera.left=-8;key.shadow.camera.right=8;key.shadow.camera.top=8;key.shadow.camera.bottom=-8;key.shadow.bias=-.0004; scene.add(key);
const fill=new T.DirectionalLight(0x38D6F0,0.4); fill.position.set(-7,4,-6); scene.add(fill);
const grid=new T.GridHelper(50,50,0x1b2536,0x121a28); grid.material.transparent=true; grid.material.opacity=.5; scene.add(grid);
const floor=new T.Mesh(new T.CircleGeometry(25,64),new T.MeshStandardMaterial({color:0x0b0f16,roughness:1})); floor.rotation.x=-Math.PI/2; floor.receiveShadow=true; scene.add(floor);

const rig=new T.Group(); scene.add(rig);
// Embedded inside the Flutter console? Flutter draws the chrome; hide the HTML panels.
if(window.EMBED){document.body.classList.add('embed');}
let labelsOn=true;

// ---- ROii footprint outline (dashed) — vehicle implied, not drawn ----
const fp=[[-1,2.15],[1,2.15],[1,-2.15],[-1,-2.15],[-1,2.15]];
const fpPts=fp.map(p=>new T.Vector3(p[0],0.02,p[1]));
const fpLine=new T.Line(new T.BufferGeometry().setFromPoints(fpPts),new T.LineDashedMaterial({color:0x33507a,dashSize:0.18,gapSize:0.12,transparent:true,opacity:.7}));
fpLine.computeLineDistances(); rig.add(fpLine);
// wheels hint (faint)
[[-0.95,1.4],[0.95,1.4],[-0.95,-1.4],[0.95,-1.4]].forEach(([x,z])=>{const c=new T.Mesh(new T.RingGeometry(0.28,0.34,24),new T.MeshBasicMaterial({color:0x24405f,transparent:true,opacity:.4,side:T.DoubleSide}));c.rotation.x=-Math.PI/2;c.position.set(x,0.02,z);rig.add(c);});

// ================= ACU aluminum box (rear of footprint) =================
const acuG=new T.Group(); acuG.position.set(0,0,-1.15); rig.add(acuG);
const Wd=1.15,Hd=0.4,Dd=0.85;
const alu=new T.MeshStandardMaterial({color:0xB9BFC9,metalness:.9,roughness:.34});
const aluDark=new T.MeshStandardMaterial({color:0x6b7280,metalness:.85,roughness:.4});
const caseMat=alu.clone(); caseMat.transparent=true; caseMat.opacity=1;
const shell=new T.Mesh(new T.BoxGeometry(Wd,Hd,Dd),caseMat); shell.position.y=Hd/2+0.05; shell.castShadow=true; shell.receiveShadow=true; acuG.add(shell);
shell.add(new T.LineSegments(new T.EdgesGeometry(shell.geometry),new T.LineBasicMaterial({color:0x3a4457,transparent:true,opacity:.6})));
const acuBase=new T.Mesh(new T.BoxGeometry(Wd+0.03,0.05,Dd+0.03),aluDark); acuBase.position.set(0,0.075,0); acuG.add(acuBase);
// heatsink fins
const finMat=new T.MeshStandardMaterial({color:0x9aa1ad,metalness:.9,roughness:.3});
const fins=new T.Group(); fins.position.y=Hd+0.05; acuG.add(fins);
for(let i=0;i<14;i++){const f=new T.Mesh(new T.BoxGeometry(0.04,0.12,Dd*0.8),finMat);f.position.set(-Wd/2+0.12+i*((Wd-0.24)/13),0.06,0);f.castShadow=true;fins.add(f);}
// internal PCB (revealed via opacity)
const pcb=new T.Mesh(new T.BoxGeometry(Wd-0.16,0.03,Dd-0.16),new T.MeshStandardMaterial({color:0x0e3b2e,roughness:.6})); pcb.position.y=0.13; acuG.add(pcb);
const soc=new T.Mesh(new T.BoxGeometry(0.3,0.12,0.3),new T.MeshStandardMaterial({color:0x11151d,emissive:0x2b3a52,emissiveIntensity:.5})); soc.position.set(-0.22,0.19,-0.1); acuG.add(soc);
const sw=new T.Mesh(new T.BoxGeometry(0.26,0.1,0.26),new T.MeshStandardMaterial({color:0x141b28,emissive:COL.lidar,emissiveIntensity:.5})); sw.position.set(0.22,0.18,0.05); acuG.add(sw);
const internals=[pcb,soc,sw]; internals.forEach(o=>o.visible=false);
// front port hints
const portsF=new T.Group(); acuG.add(portsF);
[-.4,-.2,0,.2,.4].forEach((x,i)=>{const p=new T.Mesh(new T.BoxGeometry(0.1,0.08,0.06),new T.MeshStandardMaterial({color:0x0c1017,metalness:.5}));p.position.set(x,0.16,Dd/2+0.02);portsF.add(p);});
// ACU as a selectable "sensor"
const acuData={id:'acu',nm:'ACU · Compute',ty:'acu',model:'D10 · TSN switch + SoC',range:'—',rate:'2.4 Gb/s agg',zone:'Rear ZCU'};

// ================= sensor devices (real shapes) =================
const badges=[],pickables=[],groups={};
function mkFOV(fov,tilt,len,c){const half=fov*Math.PI/360,vt=(tilt||30)*Math.PI/360;
  const g=new T.SphereGeometry(len,24,12,-half,2*half,Math.PI/2-vt,2*vt);
  const m=new T.Mesh(g,new T.MeshBasicMaterial({color:c,transparent:true,opacity:.1,side:T.DoubleSide,depthWrite:false}));
  const l=new T.LineSegments(new T.EdgesGeometry(new T.SphereGeometry(len,14,6,-half,2*half,Math.PI/2-vt,2*vt)),new T.LineBasicMaterial({color:c,transparent:true,opacity:.3}));
  const grp=new T.Group();grp.add(m);grp.add(l);return grp;}

SENS.forEach(s=>{
  const g=new T.Group(); g.position.set(...s.pos); rig.add(g); groups[s.id]=g;
  const c=new T.Color(COL[s.ty]); let dev;
  if(s.shape==='cyl'){ // LiDAR — cylinder w/ glass scanning band + mast
    dev=new T.Group();
    const body=new T.Mesh(new T.CylinderGeometry(0.16,0.17,0.14,28),new T.MeshStandardMaterial({color:0x11202b,metalness:.6,roughness:.3}));
    const glass=new T.Mesh(new T.CylinderGeometry(0.15,0.15,0.1,28),new T.MeshStandardMaterial({color:0x06202b,metalness:.2,roughness:.1,emissive:c,emissiveIntensity:.35,transparent:true,opacity:.85}));glass.position.y=-0.02;
    const cap=new T.Mesh(new T.CylinderGeometry(0.17,0.16,0.05,28),new T.MeshStandardMaterial({color:0x2b3a52,metalness:.7,roughness:.3}));cap.position.y=0.09;
    dev.add(body);dev.add(glass);dev.add(cap);dev.userData.glass=glass;
    const mast=new T.Mesh(new T.CylinderGeometry(0.04,0.05,s.pos[1]-0.55,12),aluDark); mast.position.y=-(s.pos[1]-0.55)/2-0.08; g.add(mast);
    for(let i=0;i<3;i++){const r=new T.Mesh(new T.RingGeometry(1.4+i*1.6,1.44+i*1.6,64),new T.MeshBasicMaterial({color:c,transparent:true,opacity:.1-i*.025,side:T.DoubleSide}));r.rotation.x=-Math.PI/2;r.position.y=-s.pos[1]+0.03;g.add(r);}
  } else if(s.shape==='box'){ // radar — flat rectangular w/ radome
    dev=new T.Group();
    const b=new T.Mesh(new T.BoxGeometry(0.34,0.22,0.09),new T.MeshStandardMaterial({color:0x1a2130,metalness:.5,roughness:.4}));
    const dome=new T.Mesh(new T.BoxGeometry(0.28,0.17,0.03),new T.MeshStandardMaterial({color:0x0c1622,metalness:.3,roughness:.3,emissive:c,emissiveIntensity:.3}));dome.position.z=0.05;
    dev.add(b);dev.add(dome); dev.add(new T.LineSegments(new T.EdgesGeometry(b.geometry),new T.LineBasicMaterial({color:c,transparent:true,opacity:.4})));
  } else if(s.shape==='cam'){ // camera — small body + lens
    dev=new T.Group();
    const b=new T.Mesh(new T.BoxGeometry(0.14,0.11,0.12),new T.MeshStandardMaterial({color:0x1a2130,metalness:.5,roughness:.4,emissive:c,emissiveIntensity:.25}));
    const lens=new T.Mesh(new T.CylinderGeometry(0.045,0.05,0.06,20),new T.MeshStandardMaterial({color:0x05070a,metalness:.4,roughness:.2}));lens.rotation.x=Math.PI/2;lens.position.z=0.08;
    const ring=new T.Mesh(new T.TorusGeometry(0.05,0.008,8,20),new T.MeshBasicMaterial({color:c}));ring.position.z=0.1;
    dev.add(b);dev.add(lens);dev.add(ring);
  } else { // GNSS — flat puck
    dev=new T.Group();
    const b=new T.Mesh(new T.CylinderGeometry(0.15,0.16,0.06,28),new T.MeshStandardMaterial({color:0x1a2130,metalness:.5,roughness:.4}));
    const top=new T.Mesh(new T.CylinderGeometry(0.1,0.13,0.04,28),new T.MeshStandardMaterial({color:0x2b3a52,metalness:.6,roughness:.3,emissive:c,emissiveIntensity:.3}));top.position.y=0.05;
    dev.add(b);dev.add(top);
  }
  if(s.dir){const d=new T.Vector3(...s.dir).normalize();dev.quaternion.setFromUnitVectors(new T.Vector3(0,0,1),d);}
  dev.traverse(o=>{if(o.isMesh){o.castShadow=true;pickables.push(o);o.userData.sid=s.id;}});
  g.add(dev); g.userData={s,dev};
  // FOV (radar/camera) hidden until selected
  if(s.dir && (s.ty==='radar'||s.ty==='camera')){const fov=mkFOV(s.ty==='radar'?70:56,40,s.ty==='radar'?2.6:2.2,c);fov.visible=false;g.add(fov);g.userData.fov=fov;}
  // cable to ACU
  const a=new T.Vector3(...s.pos), b2=new T.Vector3(0,0.25,-1.0);
  const mid=a.clone().lerp(b2,0.5); mid.y=Math.min(a.y,0.35);
  const curve=new T.QuadraticBezierCurve3(a,mid,b2);
  const cab=new T.Line(new T.BufferGeometry().setFromPoints(curve.getPoints(24)),new T.LineBasicMaterial({color:c,transparent:true,opacity:.28}));
  rig.add(cab);
  // badge
  const el=document.createElement('div');el.className='badge';el.innerHTML='<i style="color:'+hex(COL[s.ty])+'"></i>'+s.nm;app.appendChild(el);badges.push({el,g,s});
});
// ACU badge
(function(){const el=document.createElement('div');el.className='badge';el.innerHTML='<i style="color:'+hex(COL.acu)+'"></i>ACU';app.appendChild(el);badges.push({el,g:acuG,s:acuData,isAcu:1});})();
acuG.traverse(o=>{if(o.isMesh){pickables.push(o);o.userData.sid='acu';}});
groups['acu']=acuG; acuG.userData={s:acuData};

// ---- left panel ----
const TY=[['lidar','LiDAR'],['radar','Radar'],['camera','Camera'],['gnss','GNSS / IMU'],['acu','ACU / Compute']];
const byTy={}; SENS.forEach(s=>(byTy[s.ty]=byTy[s.ty]||[]).push(s)); byTy.acu=[acuData];
const slist=document.getElementById('slist'),tyOn={};
TY.forEach(([ty,label])=>{const arr=byTy[ty]||[];if(!arr.length)return;tyOn[ty]=1;
  const row=document.createElement('div');row.className='srow';
  row.innerHTML='<span class="dot" style="color:'+hex(COL[ty])+';background:'+hex(COL[ty])+'"></span><span class="nm">'+label+'</span><span class="ct">'+arr.length+'<span class="u">&times;</span></span>';
  row.onclick=()=>{tyOn[ty]=!tyOn[ty];row.classList.toggle('off',!tyOn[ty]);arr.forEach(s=>{if(groups[s.id])groups[s.id].visible=tyOn[ty];});};
  slist.appendChild(row);});

// ---- case opacity -> reveal ACU internals ----
const opRange=document.getElementById('opacity'),opv=document.getElementById('opv'); opRange.value=100; opv.textContent='100';
opRange.oninput=()=>{const o=opRange.value/100;opv.textContent=opRange.value;caseMat.opacity=o;const show=o<0.6;internals.forEach(m=>m.visible=show);fins.visible=o>0.15;};

// ---- picking + card ----
const ray=new T.Raycaster(),mouse=new T.Vector2(),card=document.getElementById('card');let selected=null;
function select(s){selected=s;
  document.getElementById('c-tt').textContent=s.nm;
  document.getElementById('c-sub').textContent=(s.model||s.ty.toUpperCase());
  document.querySelector('#card .m:nth-child(1) .l').textContent='Range';
  document.querySelector('#card .m:nth-child(2) .l').textContent='Data';
  document.getElementById('c-range').textContent=s.range; document.getElementById('c-rate').textContent=s.rate; document.getElementById('c-zone').textContent=s.zone;
  const ic=document.getElementById('c-ic'),c=hex(COL[s.ty]); ic.style.background=c+'22';
  ic.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="'+c+'" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">'+ICON[s.ty]+'</svg>';
  SENS.forEach(x=>{const f=groups[x.id].userData.fov;if(f)f.visible=false;});
  const fv=groups[s.id]&&groups[s.id].userData.fov; if(fv)fv.visible=true;
  card.classList.add('show');
}
renderer.domElement.addEventListener('pointerdown',ev=>{const r=renderer.domElement.getBoundingClientRect();
  mouse.x=((ev.clientX-r.left)/r.width)*2-1;mouse.y=-((ev.clientY-r.top)/r.height)*2+1;ray.setFromCamera(mouse,camera);
  const hit=ray.intersectObjects(pickables,false);
  if(hit.length){const sid=hit[0].object.userData.sid;const s=(sid==='acu')?acuData:SENS.find(x=>x.id===sid);if(s){select(s);const g=groups[sid];g.scale.set(1.18,1.18,1.18);setTimeout(()=>g.scale.set(1,1,1),200);}}
  else card.classList.remove('show');});

// ================= the two redundant fault-injection routes (Path 1 / Path 2) =================
// These are what the console cuts: a healthy blue tube front->ACU, turning red + pulsing on fault.
const HEALTHY=0x2F9BFF, FAULT=0xEF4343;
const PATHS={};
[[1, 0.58],[2,-0.58]].forEach(([n,x])=>{
  const a=new T.Vector3(x,0.55,1.9), mid=new T.Vector3(x,0.46,0.45), b=new T.Vector3(x*0.45,0.32,-0.95);
  const curve=new T.QuadraticBezierCurve3(a,mid,b);
  const mat=new T.MeshStandardMaterial({color:HEALTHY,emissive:HEALTHY,emissiveIntensity:.55,metalness:.2,roughness:.5});
  const tube=new T.Mesh(new T.TubeGeometry(curve,36,0.032,8,false),mat); rig.add(tube);
  const anchor=curve.getPoint(0.5);
  const ag=new T.Group(); ag.position.copy(anchor); rig.add(ag);
  const el=document.createElement('div'); el.className='badge'; el.innerHTML='<i style="color:'+hex(HEALTHY)+'"></i>Path '+n; app.appendChild(el);
  const badge={el,g:ag,s:{id:'path'+n,nm:'Path '+n,ty:'net'},isPath:1};
  badges.push(badge);
  PATHS[n]={mat,healthy:HEALTHY,faulted:false,anchor,badge,tube};
});

// ================= fault markers (error hotspots) + alert pulsing =================
const markers={}, alertSet=new Set();
function anchorFor(name){ if(/Path1/i.test(name))return PATHS[1].anchor; if(/Path2/i.test(name))return PATHS[2].anchor;
  return new T.Vector3(0,0.7,-1.15); }               // default: above the ACU
function addMarker(name){ if(markers[name])return;
  const g=new T.Group(); g.position.copy(anchorFor(name)); g.position.y+=0.25;
  const ring=new T.Mesh(new T.TorusGeometry(0.14,0.022,10,28),new T.MeshBasicMaterial({color:FAULT}));
  const core=new T.Mesh(new T.SphereGeometry(0.055,16,12),new T.MeshBasicMaterial({color:FAULT}));
  g.add(ring); g.add(core); g.userData.marker=name; rig.add(g);
  ring.userData.marker=name; core.userData.marker=name; pickables.push(ring); pickables.push(core);
  markers[name]={g,ring,core};
}
function removeMarker(name){ const m=markers[name]; if(!m)return; rig.remove(m.g);
  [m.ring,m.core].forEach(o=>{const i=pickables.indexOf(o);if(i>=0)pickables.splice(i,1);}); delete markers[name]; }

// ---- views ----
const VIEWS={iso:[6,5,7.5],top:[0.01,11,0.01],side:[11,2,0],front:[0,2.5,10]};
const VKEYS=Object.keys(VIEWS); let viewIdx=0;
let camTgt=new T.Vector3(...VIEWS.iso),animC=false;
function setView(k){camTgt.set(...VIEWS[k]);animC=true;viewIdx=Math.max(0,VKEYS.indexOf(k));
  document.querySelectorAll('.views button').forEach(x=>x.classList.toggle('on',x.dataset.v===k));}
document.querySelectorAll('.views button').forEach(b=>b.onclick=()=>setView(b.dataset.v));
camera.position.set(...VIEWS.iso);

// ================= window.* contract driven by the Flutter ViewerService =================
function applyOpacity(o){o=Math.max(0,Math.min(1,+o||0));caseMat.opacity=o;caseMat.transparent=o<0.999;
  const show=o<0.6;internals.forEach(m=>m.visible=show);fins.visible=o>0.12;
  if(opRange){opRange.value=Math.round(o*100);opv.textContent=Math.round(o*100);}}
window.setVehicleShellOpacity=applyOpacity;
window.toggleHotspots=function(vis){labelsOn=(vis===true||vis==='true'||vis===1);};
window.createLabelHotspots=function(){/* the scene carries its own labels */};
window.toggleMaterials=function(){/* n/a for this scene */};
window.setPathLabelFault=function(path,faulted){const p=PATHS[+path];if(!p)return;
  p.faulted=(faulted===true||faulted==='true'||faulted===1);const c=p.faulted?FAULT:p.healthy;
  p.mat.color.setHex(c);p.mat.emissive.setHex(c);
  p.badge.el.querySelector('i').style.color=hex(c);};
window.switchOrbit=function(){setView(VKEYS[(viewIdx+1)%VKEYS.length]);};
window.setOrbit=function(theta,phi){const r=camera.position.distanceTo(controls.target);
  const th=(+theta)*Math.PI/180, ph=Math.max(0.05,Math.min(Math.PI-0.05,(+phi)*Math.PI/180));
  camTgt.set(controls.target.x+r*Math.sin(ph)*Math.sin(th),controls.target.y+r*Math.cos(ph),
             controls.target.z+r*Math.sin(ph)*Math.cos(th));animC=true;};
window.resetCamera=function(){setView('iso');};
window.createErrorHotspot=function(name){addMarker(String(name));};
window.removeErrorHotspot=function(name){removeMarker(String(name));};
window.addAlertTarget=function(m){m=String(m);if(/Path1/i.test(m))alertSet.add(1);else if(/Path2/i.test(m))alertSet.add(2);};
window.removeAlertTarget=function(m){m=String(m);if(/Path1/i.test(m))alertSet.delete(1);else if(/Path2/i.test(m))alertSet.delete(2);};
window.stopAlert=function(){alertSet.clear();};
window.clearFaultAlerts=function(){alertSet.clear();Object.keys(markers).forEach(removeMarker);
  [1,2].forEach(p=>window.setPathLabelFault(p,false));};
window.errorHotspotClicked=null;

// error-hotspot taps are reported back to Flutter via the polled variable
renderer.domElement.addEventListener('pointerdown',ev=>{const r=renderer.domElement.getBoundingClientRect();
  const mx=((ev.clientX-r.left)/r.width)*2-1,my=-((ev.clientY-r.top)/r.height)*2+1;
  const rc=new T.Raycaster();rc.setFromCamera(new T.Vector2(mx,my),camera);
  const hit=rc.intersectObjects(Object.values(markers).flatMap(m=>[m.ring,m.core]),false);
  if(hit.length)window.errorHotspotClicked=hit[0].object.userData.marker;});

// ---- badges + loop ----
const v=new T.Vector3();
function updB(){badges.forEach(({el,g,s,isAcu,isPath})=>{if(!g.visible||!labelsOn){el.classList.remove('on');return;}
  g.getWorldPosition(v);v.y+=isAcu?0.55:0.22;v.project(camera);
  const auto=s.ty==='lidar'||isAcu||isPath;
  el.classList.toggle('on',v.z<1&&(s.id===selected?.id||auto));
  el.style.left=((v.x*.5+.5)*W())+'px';el.style.top=((-v.y*.5+.5)*H())+'px';});}
addEventListener('resize',()=>{camera.aspect=W()/H();camera.updateProjectionMatrix();renderer.setSize(W(),H());});
let t=0;(function loop(){requestAnimationFrame(loop);t+=0.016;
  const lg=groups['lidar']; if(lg){lg.children[0]&&(lg.children[0].rotation.y=t*2.2);}
  sw.material.emissiveIntensity=.5+Math.sin(t*2.4)*.2; rig.rotation.y+=0.0013;
  const pulse=0.55+Math.sin(t*5)*0.45;
  alertSet.forEach(n=>{const p=PATHS[n];if(p)p.mat.emissiveIntensity=pulse;});
  Object.values(markers).forEach(m=>{const s=0.8+pulse*0.5;m.ring.scale.set(s,s,s);m.core.material.opacity=pulse;m.core.material.transparent=true;});
  if(animC){camera.position.lerp(camTgt,0.08);if(camera.position.distanceTo(camTgt)<0.12)animC=false;}
  controls.update();renderer.render(scene,camera);updB();})();

window.jsReady=true;
})();
