(function () {
  "use strict";

  // ───────── 연결 ─────────
  const statusEl = document.getElementById("status");
  const dot = document.getElementById("dot");
  let ws = null, reconnectTimer = null;

  function connect() {
    ws = new WebSocket(`ws://${location.host}/ws`);
    ws.onopen = () => { setStatus(true); send({ t: "hello", name: "Safari" }); send({ t: "getDeck" }); };
    ws.onclose = () => { setStatus(false); scheduleReconnect(); };
    ws.onerror = () => { try { ws.close(); } catch (e) {} };
    ws.onmessage = (ev) => {
      try {
        const m = JSON.parse(ev.data);
        if (m.t === "deck") {
          if (m.json && m.json.folders) { deck = m.json; saveLocal(); renderDeck(); }
          else { pushDeckToServer(); }   // 서버에 덱 없음 → 현재 덱으로 시드
        } else if (m.t === "apps") {
          installedApps = m.list || [];
          if (appsPickerRefresh) appsPickerRefresh();
        }
      } catch (e) {}
    };
  }
  function scheduleReconnect() { clearTimeout(reconnectTimer); reconnectTimer = setTimeout(connect, 1000); }
  function setStatus(ok) { statusEl.textContent = ok ? "연결됨" : "연결 끊김 · 재시도 중…"; dot.className = "dot" + (ok ? " on" : ""); }
  function send(obj) { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj)); }

  // ───────── 페이지 확대(핀치/더블탭) 강제 차단 ─────────
  // iOS 사파리는 viewport 메타를 무시하므로 gesture 이벤트를 직접 막아야 함.
  ["gesturestart", "gesturechange", "gestureend"].forEach((ev) =>
    document.addEventListener(ev, (e) => e.preventDefault(), { passive: false }));
  // 멀티터치 핀치(스크롤 영역 밖) 방지
  document.addEventListener("touchmove", (e) => {
    if (e.touches.length > 1 && !e.target.closest("#trackpad")) e.preventDefault();
  }, { passive: false });

  // ───────── 설정 (감도 등, 기기별 localStorage) ─────────
  const SETTINGS_KEY = "macpilot.settings.v1";
  const SETTINGS_DEFAULTS = { moveSpeed: 1.1, accel: 0.05, scrollSpeed: 1.0, scrollDir: 1, theme: "dark" };
  let settings = loadSettings();
  function loadSettings() {
    try { const r = localStorage.getItem(SETTINGS_KEY); if (r) return Object.assign({}, SETTINGS_DEFAULTS, JSON.parse(r)); } catch (e) {}
    return Object.assign({}, SETTINGS_DEFAULTS);
  }
  function saveSettings() { try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch (e) {} }

  // 테마 적용 (system 이면 기기 설정 따라감) + 로고도 테마에 맞게 교체
  const themeMQ = window.matchMedia("(prefers-color-scheme: dark)");
  function resolvedTheme() {
    let t = settings.theme || "dark";
    return t === "system" ? (themeMQ.matches ? "dark" : "light") : t;
  }
  function currentLogoSrc() { return resolvedTheme() === "light" ? "/logo-mark.png" : "/logo-mark-dark.png"; }
  function updateLogos() { document.querySelectorAll(".logo-img").forEach((i) => { i.src = currentLogoSrc(); }); }
  function applyTheme() {
    const t = resolvedTheme();
    document.documentElement.setAttribute("data-theme", t);
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", t === "light" ? "#f2f2f4" : "#141416");
    updateLogos();
  }
  themeMQ.addEventListener("change", () => { if (settings.theme === "system") applyTheme(); });
  applyTheme();

  // ───────── 키 매핑 ─────────
  const KEYMAP = {
    a:0,s:1,d:2,f:3,h:4,g:5,z:6,x:7,c:8,v:9,b:11,q:12,w:13,e:14,r:15,y:16,t:17,
    o:31,u:32,i:34,p:35,l:37,j:38,k:40,n:45,m:46,
    "1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29,
    "-":27,"=":24,"[":33,"]":30,";":41,"'":39,",":43,".":47,"/":44,"\\":42,"`":50," ":49
  };
  const SPECIAL_KEYS = [
    {label:"space",keyCode:49},{label:"return",keyCode:36},{label:"tab",keyCode:48},
    {label:"esc",keyCode:53},{label:"⌫",keyCode:51},{label:"⌦",keyCode:117},
    {label:"←",keyCode:123},{label:"→",keyCode:124},{label:"↑",keyCode:126},{label:"↓",keyCode:125},
    {label:"home",keyCode:115},{label:"end",keyCode:119},{label:"⇞",keyCode:116},{label:"⇟",keyCode:121},
    {label:"F1",keyCode:122},{label:"F2",keyCode:120},{label:"F3",keyCode:99},{label:"F4",keyCode:118},
    {label:"F5",keyCode:96},{label:"F6",keyCode:97},{label:"F7",keyCode:98},{label:"F8",keyCode:100},
    {label:"F9",keyCode:101},{label:"F10",keyCode:109},{label:"F11",keyCode:103},{label:"F12",keyCode:111}
  ];
  const MOD_SYMBOL = { command:"⌘", control:"⌃", shift:"⇧", option:"⌥" };
  const MOD_ORDER = ["control","option","shift","command"];

  function keyCodeForChar(ch) { if (!ch) return null; const c = ch.toLowerCase(); return KEYMAP[c] !== undefined ? KEYMAP[c] : null; }
  function keyLabel(keyCode) {
    if (keyCode === null || keyCode === undefined) return "?";
    const sp = SPECIAL_KEYS.find(s => s.keyCode === keyCode);
    if (sp) return sp.label;
    for (const k in KEYMAP) if (KEYMAP[k] === keyCode) return k === " " ? "space" : k.toUpperCase();
    return "?";
  }
  function comboLabel(keyCode, mods) {
    const ordered = MOD_ORDER.filter(m => (mods || []).includes(m)).map(m => MOD_SYMBOL[m]).join("");
    return ordered + keyLabel(keyCode);
  }
  function uid() { return "x" + Math.random().toString(36).slice(2, 9); }

  // ───────── 탭 전환 ─────────
  const kb = document.getElementById("kb-input");
  document.querySelectorAll("#tabbar .tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      const name = tab.dataset.tab;
      setSheet(false);   // 탭을 누르면 트랙패드 시트를 내려 해당 탭을 보여줌
      document.querySelectorAll("#tabbar .tab").forEach((t) => t.classList.toggle("active", t === tab));
      document.querySelectorAll(".panel").forEach((p) => p.classList.toggle("active", p.id === "panel-" + name));
      if (name === "keyboard") setTimeout(() => kb.focus(), 50); else kb.blur();
      if (name === "deck") renderDeck();
    });
  });

  // ═════════ 트랙패드 시트 (엣지 핸들로 소환/닫기) ═════════
  const mainEl = document.querySelector("main");
  const sheetEl = document.getElementById("tp-sheet");
  const sheetHandle = document.getElementById("tp-handle");
  const HANDLE_H = 46;
  let sheetOpen = true, sheetCurOff = 0, sheetDrag = null;

  function closedOffset() { return Math.max(mainEl.clientHeight - HANDLE_H, 0); }
  function applySheet(off, animate) {
    sheetCurOff = off;
    sheetEl.style.transition = animate ? "transform .25s cubic-bezier(.2,.8,.2,1)" : "none";
    sheetEl.style.transform = "translateY(" + off + "px)";
  }
  function setSheet(open) {
    sheetOpen = open;
    applySheet(open ? 0 : closedOffset(), true);
    sheetHandle.classList.toggle("open", open);
    if (open) kb.blur();
  }
  sheetHandle.addEventListener("touchstart", (e) => {
    sheetDrag = { y: e.touches[0].clientY, startOff: sheetOpen ? 0 : closedOffset(), moved: false };
  }, { passive: true });
  sheetHandle.addEventListener("touchmove", (e) => {
    if (!sheetDrag) return;
    e.preventDefault();
    const dy = e.touches[0].clientY - sheetDrag.y;
    if (Math.abs(dy) > 6) sheetDrag.moved = true;
    applySheet(Math.max(0, Math.min(sheetDrag.startOff + dy, closedOffset())), false);
  }, { passive: false });
  sheetHandle.addEventListener("touchend", () => {
    if (!sheetDrag) return;
    if (!sheetDrag.moved) setSheet(!sheetOpen);            // 탭 = 토글
    else setSheet(sheetCurOff < closedOffset() / 2);       // 드래그 = 위치로 스냅
    sheetDrag = null;
  });
  window.addEventListener("resize", () => applySheet(sheetOpen ? 0 : closedOffset(), false));

  // ═════════ 키보드 탭 ═════════
  let activeMods = [];
  function refreshModChips() {
    document.querySelectorAll("#kb-mods .modchip").forEach((c) => c.classList.toggle("on", activeMods.includes(c.dataset.mod)));
  }
  document.querySelectorAll("#kb-mods .modchip").forEach((chip) => {
    chip.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      const m = chip.dataset.mod;
      if (activeMods.includes(m)) activeMods = activeMods.filter((x) => x !== m); else activeMods.push(m);
      refreshModChips();
    });
  });

  let lastValue = "", composing = false;
  function flushDiff() {
    const value = kb.value;
    let p = 0; const minLen = Math.min(lastValue.length, value.length);
    while (p < minLen && lastValue[p] === value[p]) p++;
    const removed = lastValue.length - p;
    const added = value.slice(p);

    if (activeMods.length > 0 && removed === 0 && added) {
      // 모디파이어 켜짐 → 입력 글자를 조합키로 전송하고 입력창은 되돌림
      for (const ch of added) {
        const kc = keyCodeForChar(ch);
        if (kc !== null) send({ t: "key", keyCode: kc, mods: activeMods.slice() });
        else send({ t: "text", text: ch });
      }
      kb.value = lastValue;
      return;
    }
    for (let i = 0; i < removed; i++) send({ t: "key", keyCode: 51, mods: [] });
    if (added) send({ t: "text", text: added });
    lastValue = kb.value;
    if (kb.value.length > 80 && !composing) { kb.value = ""; lastValue = ""; }
  }
  kb.addEventListener("compositionstart", () => { composing = true; });
  kb.addEventListener("compositionend", () => { composing = false; flushDiff(); });
  kb.addEventListener("input", (e) => { if (e.isComposing || composing) return; flushDiff(); });
  document.getElementById("kb-clear").addEventListener("click", () => { kb.value = ""; lastValue = ""; kb.focus(); });

  document.querySelectorAll("#kb-special .sp").forEach((btn) => {
    btn.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      send({ t: "key", keyCode: parseInt(btn.dataset.key, 10), mods: activeMods.slice() });
    });
  });

  // ═════════ 덱 ═════════
  const STORE_KEY = "macpilot.deck.v2";
  let deck = loadDeck();
  let activeFolder = 0;
  let editMode = false;
  let installedApps = null, appsPickerRefresh = null;

  function loadDeck() {
    try { const raw = localStorage.getItem(STORE_KEY); if (raw) return JSON.parse(raw); } catch (e) {}
    return defaultDeck();
  }
  function saveLocal() { try { localStorage.setItem(STORE_KEY, JSON.stringify(deck)); } catch (e) {} }
  function pushDeckToServer() { send({ t: "saveDeck", deckJson: JSON.stringify(deck) }); }
  function saveDeck() { saveLocal(); pushDeckToServer(); }   // 폰 캐시 + 맥 서버 동시 저장
  function sc(label, keyCode, mods) { return { id: uid(), type: "shortcut", label, keyCode, mods }; }
  function defaultDeck() {
    return { folders: [
      { id: uid(), name: "기본", items: [
        sc("복사", 8, ["command"]), sc("붙여넣기", 9, ["command"]), sc("잘라내기", 7, ["command"]),
        sc("실행취소", 6, ["command"]), sc("다시실행", 6, ["command","shift"]), sc("전체선택", 0, ["command"]),
        sc("저장", 1, ["command"]), sc("찾기", 3, ["command"]), sc("새로고침", 15, ["command"]),
      ]},
      { id: uid(), name: "앱/창", items: [
        sc("새 탭", 17, ["command"]), sc("탭 닫기", 13, ["command"]), sc("스팟라이트", 49, ["command"]),
        sc("앱 전환", 48, ["command"]),
        { id: uid(), type: "launch", label: "미션컨트롤", target: "/System/Applications/Mission Control.app" },
      ]},
      { id: uid(), name: "매크로", items: [
        { id: uid(), type: "macro", label: "전체선택→복사", steps: [
          { type:"key", keyCode:0, mods:["command"] }, { type:"delay", ms:80 }, { type:"key", keyCode:8, mods:["command"] } ] },
        { id: uid(), type: "macro", label: "복사→앱전환→붙여넣기", steps: [
          { type:"key", keyCode:8, mods:["command"] }, { type:"delay", ms:120 },
          { type:"key", keyCode:48, mods:["command"] }, { type:"delay", ms:300 },
          { type:"key", keyCode:9, mods:["command"] } ] },
      ]},
      { id: uid(), name: "내 것", items: [] },
    ]};
  }

  const PAGE_SIZE = 9;
  const pagesEl = document.getElementById("deck-pages");
  const dotsEl = document.getElementById("page-dots");
  const tabsEl = document.getElementById("folder-tabs");
  const toolbarEl = document.getElementById("deck-toolbar");

  document.getElementById("deck-edit").addEventListener("click", () => {
    editMode = !editMode;
    document.getElementById("deck-edit").classList.toggle("on", editMode);
    toolbarEl.classList.toggle("on", editMode);
    renderDeck();
  });

  // 음량 / 밝기
  document.querySelectorAll("#media-bar button").forEach((b) => {
    b.addEventListener("click", () => send({ t: b.dataset.m, dir: b.dataset.d }));
  });

  function runItem(item) {
    if (item.type === "shortcut") send({ t: "key", keyCode: item.keyCode, mods: item.mods || [] });
    else if (item.type === "text") send({ t: "text", text: item.text || "" });
    else if (item.type === "launch") send({ t: "launch", target: item.target || "" });
    else if (item.type === "macro") send({ t: "macro", steps: item.steps || [] });
  }
  function cellSub(item) {
    if (item.type === "shortcut") return comboLabel(item.keyCode, item.mods);
    if (item.type === "macro") return "매크로 " + (item.steps ? item.steps.length : 0) + "단계";
    if (item.type === "text") return "텍스트";
    if (item.type === "launch") return "앱/링크";
    return "";
  }

  function renderDeck() {
    if (activeFolder >= deck.folders.length) activeFolder = 0;
    renderFolderTabs();
    renderToolbar();
    renderPages();
  }
  function renderFolderTabs() {
    tabsEl.innerHTML = "";
    deck.folders.forEach((f, i) => {
      const t = document.createElement("button");
      t.className = "folder-tab" + (i === activeFolder ? " active" : "");
      t.textContent = f.name;
      t.addEventListener("click", () => { activeFolder = i; renderDeck(); });
      tabsEl.appendChild(t);
    });
    if (editMode) {
      const add = document.createElement("button");
      add.className = "folder-tab add"; add.textContent = "＋폴더";
      add.addEventListener("click", () => {
        const name = prompt("새 폴더 이름"); if (!name) return;
        deck.folders.push({ id: uid(), name, items: [] }); activeFolder = deck.folders.length - 1; saveDeck(); renderDeck();
      });
      tabsEl.appendChild(add);
    }
  }
  function renderToolbar() {
    toolbarEl.innerHTML = "";
    if (!editMode) return;
    const rename = document.createElement("button");
    rename.textContent = "✎ 폴더 이름";
    rename.addEventListener("click", () => {
      const f = deck.folders[activeFolder]; const name = prompt("폴더 이름", f.name); if (!name) return;
      f.name = name; saveDeck(); renderDeck();
    });
    const del = document.createElement("button");
    del.className = "danger"; del.textContent = "🗑 폴더 삭제";
    del.addEventListener("click", () => {
      if (deck.folders.length <= 1) { alert("폴더는 최소 1개 필요합니다"); return; }
      if (!confirm("이 폴더와 버튼을 삭제할까요?")) return;
      deck.folders.splice(activeFolder, 1); activeFolder = 0; saveDeck(); renderDeck();
    });
    toolbarEl.appendChild(rename); toolbarEl.appendChild(del);
  }
  function renderPages() {
    const keepScroll = pagesEl.scrollLeft;
    pagesEl.innerHTML = "";
    const folder = deck.folders[activeFolder];
    const items = folder ? folder.items : [];
    const cells = items.map((item, i) => renderCell(item, i));
    if (editMode) cells.push(renderAddCell());
    const pages = [];
    for (let i = 0; i < cells.length; i += PAGE_SIZE) pages.push(cells.slice(i, i + PAGE_SIZE));
    if (pages.length === 0) pages.push([]);
    pages.forEach((pc) => {
      const page = document.createElement("div");
      page.className = "deck-page";
      pc.forEach((c) => page.appendChild(c));
      pagesEl.appendChild(page);
    });
    pagesEl.scrollLeft = keepScroll;
    renderDots(pages.length);
  }
  function renderCell(item, idx) {
    const btn = document.createElement("button");
    btn.className = "deck-btn" + (item.type === "macro" ? " macro" : "");
    btn.dataset.idx = idx;
    if (item.color) btn.style.background = item.color;
    if (dragState && dragState.item === item) btn.classList.add("drag-src");
    if (item.icon) {
      if (item.icon.indexOf("data:") === 0) { const im = document.createElement("img"); im.className = "ic-img"; im.src = item.icon; btn.appendChild(im); }
      else { const ic = document.createElement("span"); ic.className = "ic"; ic.textContent = item.icon; btn.appendChild(ic); }
    }
    const main = document.createElement("span"); main.textContent = item.label || "(이름없음)"; btn.appendChild(main);
    const sub = cellSub(item);
    if (sub) { const s = document.createElement("span"); s.className = "sub"; s.textContent = sub; btn.appendChild(s); }
    if (editMode) {
      btn.addEventListener("touchstart", (e) => {
        const t = e.touches[0];
        dragCandidate = { item, btn, x: t.clientX, y: t.clientY, armed: false };
        dragTimer = setTimeout(() => { if (dragCandidate) { dragCandidate.armed = true; btn.classList.add("lift"); } }, 220);
      }, { passive: true });
    } else {
      btn.addEventListener("click", () => runItem(item));
    }
    return btn;
  }
  function renderAddCell() {
    const btn = document.createElement("button");
    btn.className = "deck-btn add"; btn.textContent = "＋";
    btn.addEventListener("click", () => openEditor(null));
    return btn;
  }
  function renderDots(count) {
    dotsEl.innerHTML = "";
    if (count <= 1) return;
    for (let i = 0; i < count; i++) { const d = document.createElement("span"); d.className = "pd" + (i === 0 ? " on" : ""); dotsEl.appendChild(d); }
  }
  pagesEl.addEventListener("scroll", () => {
    const w = pagesEl.clientWidth; if (!w) return;
    const idx = Math.round(pagesEl.scrollLeft / w);
    dotsEl.querySelectorAll(".pd").forEach((d, i) => d.classList.toggle("on", i === idx));
  });

  // ── 드래그 재정렬 (편집 모드: 길게 눌러 집고 끌어서 이동) ──
  let dragCandidate = null, dragState = null, dragTimer = null;
  function clearCandidate() {
    if (dragTimer) { clearTimeout(dragTimer); dragTimer = null; }
    if (dragCandidate && dragCandidate.btn) dragCandidate.btn.classList.remove("lift");
    dragCandidate = null;
  }
  function beginDrag(t) {
    const btn = dragCandidate.btn, item = dragCandidate.item;
    if (dragTimer) { clearTimeout(dragTimer); dragTimer = null; }
    dragCandidate = null;
    const rect = btn.getBoundingClientRect();
    const ghost = btn.cloneNode(true);
    ghost.classList.add("drag-ghost");
    ghost.style.cssText += "position:fixed;left:" + rect.left + "px;top:" + rect.top + "px;width:" + rect.width + "px;height:" + rect.height + "px;margin:0;z-index:60;pointer-events:none;";
    document.body.appendChild(ghost);
    dragState = { item: item, ghost: ghost, offX: t.clientX - rect.left, offY: t.clientY - rect.top };
    renderPages();
  }
  function moveDrag(t) {
    const g = dragState.ghost;
    g.style.left = (t.clientX - dragState.offX) + "px";
    g.style.top = (t.clientY - dragState.offY) + "px";
    g.style.visibility = "hidden";
    const el = document.elementFromPoint(t.clientX, t.clientY);
    g.style.visibility = "visible";
    const target = el && el.closest ? el.closest(".deck-btn") : null;
    if (!target || target.classList.contains("add") || target.classList.contains("drag-ghost")) return;
    const targetIdx = parseInt(target.dataset.idx, 10);
    if (isNaN(targetIdx)) return;
    const folder = deck.folders[activeFolder];
    const curIdx = folder.items.indexOf(dragState.item);
    if (curIdx < 0 || targetIdx === curIdx) return;
    folder.items.splice(curIdx, 1);
    folder.items.splice(targetIdx, 0, dragState.item);
    renderPages();
  }
  function endDrag() { if (dragState.ghost) dragState.ghost.remove(); dragState = null; saveDeck(); renderPages(); }

  document.addEventListener("touchmove", (e) => {
    if (dragState) { e.preventDefault(); moveDrag(e.touches[0]); return; }
    if (!dragCandidate) return;
    const t = e.touches[0];
    if (dragCandidate.armed) { e.preventDefault(); beginDrag(t); }
    else if (Math.hypot(t.clientX - dragCandidate.x, t.clientY - dragCandidate.y) > 10) clearCandidate();
  }, { passive: false });
  document.addEventListener("touchend", () => {
    if (dragState) { endDrag(); return; }
    if (dragCandidate) { const it = dragCandidate.item; clearCandidate(); openEditor(it); }
  });

  // ═════════ 버튼 에디터 (모달) ═════════
  const modalRoot = document.getElementById("modal-root");
  let draft = null;       // 편집 중 항목
  let draftIndex = -1;    // 폴더 내 인덱스 (-1=신규)

  function openEditor(item) {
    draftIndex = item ? deck.folders[activeFolder].items.indexOf(item) : -1;
    draft = item ? JSON.parse(JSON.stringify(item))
                 : { id: uid(), type: "shortcut", label: "", keyCode: 8, mods: ["command"] };
    if (!draft.mods) draft.mods = [];
    renderModal();
  }
  function closeEditor() { modalRoot.innerHTML = ""; draft = null; appsPickerRefresh = null; }

  function renderModal() {
    modalRoot.innerHTML =
      '<div class="modal-bg"></div><div class="modal-card">' +
      '<div class="modal-head"><div class="modal-title">' + (draftIndex >= 0 ? "버튼 편집" : "버튼 추가") + '</div><button id="ed-close" class="modal-x">✕</button></div>' +
      '<div class="seg" id="ed-type">' +
        '<button data-type="shortcut">단축키</button><button data-type="text">텍스트</button>' +
        '<button data-type="launch">앱/링크</button><button data-type="macro">매크로</button></div>' +
      '<input id="ed-label" class="ed-input" placeholder="버튼 이름">' +
      '<div class="ed-row"><input id="ed-icon" class="ed-input ed-icon" maxlength="2" placeholder="🙂 아이콘"><select id="ed-folder" class="ed-input"></select></div>' +
      '<div class="ed-colors" id="ed-colors"></div>' +
      '<div id="ed-body"></div>' +
      '<div class="modal-actions">' +
        (draftIndex >= 0 ? '<button id="ed-delete" class="danger">삭제</button>' : '') +
        '<span style="flex:1"></span><button id="ed-cancel">취소</button><button id="ed-save" class="primary">저장</button>' +
      '</div></div>';

    modalRoot.querySelector(".modal-bg").addEventListener("click", closeEditor);
    modalRoot.querySelector("#ed-cancel").addEventListener("click", closeEditor);
    modalRoot.querySelector("#ed-close").addEventListener("click", closeEditor);
    const lab = modalRoot.querySelector("#ed-label");
    lab.value = draft.label || "";
    lab.addEventListener("input", () => { draft.label = lab.value; });

    // 아이콘
    const iconEl = modalRoot.querySelector("#ed-icon");
    iconEl.value = (draft.icon && draft.icon.indexOf("data:") !== 0) ? draft.icon : "";
    iconEl.addEventListener("input", () => { draft.icon = iconEl.value || null; });
    // 폴더 이동
    const folderEl = modalRoot.querySelector("#ed-folder");
    deck.folders.forEach((f, i) => { const o = document.createElement("option"); o.value = String(i); o.textContent = "📁 " + f.name; if (i === activeFolder) o.selected = true; folderEl.appendChild(o); });
    // 색상
    const COLORS = ["", "#2a3b4d", "#3a2a4d", "#4d2a2a", "#2a4d34", "#4d442a", "#2a4d4d", "#3a3a42"];
    const colorsEl = modalRoot.querySelector("#ed-colors");
    COLORS.forEach((c) => {
      const sw = document.createElement("button");
      sw.className = "swatch" + ((draft.color || "") === c ? " on" : "");
      sw.style.background = c || "#1c1c20";
      if (!c) sw.textContent = "✕";
      sw.addEventListener("click", () => { draft.color = c || null; colorsEl.querySelectorAll(".swatch").forEach((x) => x.classList.remove("on")); sw.classList.add("on"); });
      colorsEl.appendChild(sw);
    });

    modalRoot.querySelectorAll("#ed-type button").forEach((b) => {
      b.classList.toggle("on", b.dataset.type === draft.type);
      b.addEventListener("click", () => { changeType(b.dataset.type); });
    });
    if (draftIndex >= 0) modalRoot.querySelector("#ed-delete").addEventListener("click", () => {
      deck.folders[activeFolder].items.splice(draftIndex, 1); saveDeck(); closeEditor(); renderDeck();
    });
    modalRoot.querySelector("#ed-save").addEventListener("click", saveDraft);
    renderBody();
  }
  function changeType(type) {
    draft.type = type;
    if (type === "shortcut") { if (draft.keyCode == null) draft.keyCode = 8; if (!draft.mods) draft.mods = ["command"]; }
    if (type === "text" && draft.text == null) draft.text = "";
    if (type === "launch" && draft.target == null) draft.target = "";
    if (type === "macro" && !draft.steps) draft.steps = [];
    modalRoot.querySelectorAll("#ed-type button").forEach((b) => b.classList.toggle("on", b.dataset.type === type));
    renderBody();
  }
  function renderBody() {
    const body = modalRoot.querySelector("#ed-body");
    if (draft.type === "shortcut") body.innerHTML = comboBuilderHTML("");
    else if (draft.type === "text") body.innerHTML = '<div class="ed-label">입력할 텍스트</div><textarea id="ed-text" class="ed-input" placeholder="예: 이메일 주소, 자주 쓰는 문구"></textarea>';
    else if (draft.type === "launch") body.innerHTML =
      '<div class="ed-label">앱 이름 · 경로 · 링크(URL)</div>' +
      '<input id="ed-target" class="ed-input" placeholder="Notes · https://… · shortcuts://…" autocapitalize="off" autocorrect="off">' +
      '<div class="ed-label">설치된 앱에서 선택</div>' +
      '<input id="ed-appsearch" class="ed-input" placeholder="앱 검색…" autocapitalize="off" autocorrect="off">' +
      '<div class="ed-apps" id="ed-apps"></div>';
    else if (draft.type === "macro") body.innerHTML = '<div class="ed-label">매크로 단계 (순서대로 실행)</div><div class="ed-steps" id="ed-steps"></div><button class="ed-addstep" id="ed-addstep">+ 단계 추가</button>';
    wireBody();
  }
  function wireBody() {
    if (draft.type === "shortcut") wireComboBuilder("", draft, () => {});
    else if (draft.type === "text") { const t = modalRoot.querySelector("#ed-text"); t.value = draft.text || ""; t.addEventListener("input", () => draft.text = t.value); }
    else if (draft.type === "launch") {
      const t = modalRoot.querySelector("#ed-target");
      t.value = draft.target || "";
      t.addEventListener("input", () => draft.target = t.value);
      const search = modalRoot.querySelector("#ed-appsearch");
      const appsEl = modalRoot.querySelector("#ed-apps");
      const renderApps = () => {
        appsEl.innerHTML = "";
        if (!installedApps) { appsEl.textContent = "앱 목록 불러오는 중…"; return; }
        const f = (search.value || "").toLowerCase();
        installedApps.filter((a) => a.name.toLowerCase().includes(f)).slice(0, 300).forEach((a) => {
          const b = document.createElement("button");
          b.className = "app-tile";
          if (a.icon) { const im = document.createElement("img"); im.className = "app-ic"; im.src = a.icon; b.appendChild(im); }
          const nm = document.createElement("span"); nm.textContent = a.name; b.appendChild(nm);
          b.addEventListener("click", () => { draft.target = a.path; t.value = a.path; if (a.icon) draft.icon = a.icon; });
          appsEl.appendChild(b);
        });
      };
      search.addEventListener("input", renderApps);
      appsPickerRefresh = renderApps;
      renderApps();
      if (!installedApps) send({ t: "getApps" });
    }
    else if (draft.type === "macro") { renderSteps(); modalRoot.querySelector("#ed-addstep").addEventListener("click", () => { draft.steps.push({ type:"key", keyCode:8, mods:["command"] }); renderSteps(); }); }
  }

  // 조합키 빌더 (단축키 + 매크로 step 공용). prefix 로 id 충돌 방지.
  function comboBuilderHTML(prefix) {
    return '' +
      '<div class="ed-mods" id="' + prefix + 'mods">' +
        '<button data-mod="command">⌘</button><button data-mod="control">⌃</button>' +
        '<button data-mod="shift">⇧</button><button data-mod="option">⌥</button></div>' +
      '<div class="ed-label">키 (직접 입력 또는 아래에서 선택)</div>' +
      '<input id="' + prefix + 'keychar" class="ed-input" maxlength="1" placeholder="a, 1, = …" autocapitalize="off" autocorrect="off">' +
      '<div class="ed-special" id="' + prefix + 'special"></div>' +
      '<div class="ed-preview" id="' + prefix + 'preview"></div>';
  }
  function wireComboBuilder(prefix, target, onChange) {
    const modsEl = modalRoot.querySelector("#" + prefix + "mods");
    const charEl = modalRoot.querySelector("#" + prefix + "keychar");
    const specialEl = modalRoot.querySelector("#" + prefix + "special");
    const previewEl = modalRoot.querySelector("#" + prefix + "preview");
    function refresh() { previewEl.textContent = comboLabel(target.keyCode, target.mods); onChange(); }

    modsEl.querySelectorAll("button").forEach((b) => {
      b.classList.toggle("on", (target.mods || []).includes(b.dataset.mod));
      b.addEventListener("click", () => {
        const m = b.dataset.mod;
        if (!target.mods) target.mods = [];
        if (target.mods.includes(m)) target.mods = target.mods.filter((x) => x !== m); else target.mods.push(m);
        b.classList.toggle("on"); refresh();
      });
    });
    // 직접 입력
    const cur = keyLabel(target.keyCode);
    if (cur.length === 1) charEl.value = cur.toLowerCase();
    charEl.addEventListener("input", () => {
      const kc = keyCodeForChar(charEl.value);
      if (kc !== null) { target.keyCode = kc; specialEl.querySelectorAll("button").forEach((x) => x.classList.remove("on")); refresh(); }
    });
    // 특수키 그리드
    SPECIAL_KEYS.forEach((sp) => {
      const b = document.createElement("button");
      b.textContent = sp.label; b.classList.toggle("on", target.keyCode === sp.keyCode);
      b.addEventListener("click", () => {
        target.keyCode = sp.keyCode; charEl.value = "";
        specialEl.querySelectorAll("button").forEach((x) => x.classList.remove("on")); b.classList.add("on"); refresh();
      });
      specialEl.appendChild(b);
    });
    refresh();
  }

  // 매크로 단계 렌더
  function renderSteps() {
    const wrap = modalRoot.querySelector("#ed-steps");
    wrap.innerHTML = "";
    draft.steps.forEach((step, idx) => {
      const row = document.createElement("div");
      row.className = "ed-step";
      const head = document.createElement("div");
      head.className = "ed-step-head";
      const sel = document.createElement("select");
      [["key","단축키"],["text","텍스트"],["delay","딜레이"],["launch","앱/링크"]].forEach(([v,l]) => {
        const o = document.createElement("option"); o.value = v; o.textContent = l; if (step.type === v) o.selected = true; sel.appendChild(o);
      });
      sel.addEventListener("change", () => { step.type = sel.value; if (step.type==="key" && step.keyCode==null){step.keyCode=8;step.mods=["command"];} renderSteps(); });
      const rm = document.createElement("button"); rm.className = "rm"; rm.textContent = "✕";
      rm.addEventListener("click", () => { draft.steps.splice(idx, 1); renderSteps(); });
      head.appendChild(sel); head.appendChild(rm); row.appendChild(head);

      const bodyId = "step" + idx + "_";
      const sb = document.createElement("div");
      if (step.type === "key") { sb.innerHTML = comboBuilderHTML(bodyId); }
      else if (step.type === "text") { sb.innerHTML = '<input class="ed-input" placeholder="입력할 텍스트">'; }
      else if (step.type === "delay") { sb.innerHTML = '<input class="ed-input" type="number" placeholder="밀리초 (예: 200)">'; }
      else if (step.type === "launch") { sb.innerHTML = '<input class="ed-input" placeholder="앱 이름 · 경로 · https://… · shortcuts://…" autocapitalize="off" autocorrect="off">'; }
      row.appendChild(sb); wrap.appendChild(row);

      if (step.type === "key") { if (!step.mods) step.mods = []; wireComboBuilder(bodyId, step, () => {}); }
      else if (step.type === "text") { const i = sb.querySelector("input"); i.value = step.text||""; i.addEventListener("input",()=>step.text=i.value); }
      else if (step.type === "delay") { const i = sb.querySelector("input"); i.value = step.ms||""; i.addEventListener("input",()=>step.ms=parseInt(i.value,10)||0); }
      else if (step.type === "launch") { const i = sb.querySelector("input"); i.value = step.target||""; i.addEventListener("input",()=>step.target=i.value); }
    });
  }

  function saveDraft() {
    if (!draft.label) draft.label = defaultLabel(draft);
    const folderEl = modalRoot.querySelector("#ed-folder");
    let dest = folderEl ? parseInt(folderEl.value, 10) : activeFolder;
    if (isNaN(dest) || dest < 0 || dest >= deck.folders.length) dest = activeFolder;
    const srcItems = deck.folders[activeFolder].items;
    if (draftIndex >= 0) {
      if (dest === activeFolder) { srcItems[draftIndex] = draft; }
      else { srcItems.splice(draftIndex, 1); deck.folders[dest].items.push(draft); activeFolder = dest; }
    } else {
      deck.folders[dest].items.push(draft); activeFolder = dest;
    }
    saveDeck(); closeEditor(); renderDeck();
  }
  function defaultLabel(d) {
    if (d.type === "shortcut") return comboLabel(d.keyCode, d.mods);
    if (d.type === "text") return (d.text || "텍스트").slice(0, 8);
    if (d.type === "launch") return "앱";
    if (d.type === "macro") return "매크로";
    return "버튼";
  }

  // ═════════ 설정 모달 ═════════
  function fmt(key) { return key === "accel" ? Math.round(settings[key] * 100) + "%" : settings[key].toFixed(1) + "×"; }
  function sliderHTML(id, label, min, max, step) {
    return '<div class="set-row"><label>' + label + '</label><span class="set-val" id="sv-' + id + '"></span></div>' +
      '<input type="range" class="set-slider" id="set-' + id + '" min="' + min + '" max="' + max + '" step="' + step + '">';
  }
  function openSettings() {
    modalRoot.innerHTML =
      '<div class="modal-bg"></div><div class="modal-card">' +
      '<div class="modal-head"><div class="modal-title">설정</div><button id="set-close" class="modal-x">✕</button></div>' +
      '<div class="set-section">테마</div>' +
      '<div class="seg" id="set-theme"><button data-theme="system">시스템</button><button data-theme="light">라이트</button><button data-theme="dark">다크</button></div>' +
      '<div class="set-section">트랙패드</div>' +
      sliderHTML("move", "커서 속도", 0.4, 3, 0.1) +
      sliderHTML("accel", "포인터 가속", 0, 0.15, 0.01) +
      sliderHTML("scroll", "스크롤 속도", 0.3, 3, 0.1) +
      '<div class="set-row"><label>스크롤 방향 반전</label><input type="checkbox" id="set-scrolldir"></div>' +
      '<div class="modal-actions"><button id="set-reset" class="danger">기본값</button><span style="flex:1"></span><button id="set-done" class="primary">완료</button></div>' +
      '<div class="about"><img class="logo-img about-logo" alt="JoonLab"><div class="copyright">© joonlab · MacPilot</div></div>' +
      '</div>';
    const close = () => { modalRoot.innerHTML = ""; };
    modalRoot.querySelector(".modal-bg").addEventListener("click", close);
    modalRoot.querySelector("#set-close").addEventListener("click", close);
    modalRoot.querySelector("#set-done").addEventListener("click", close);

    const bind = (id, key) => {
      const el = modalRoot.querySelector("#set-" + id);
      const val = modalRoot.querySelector("#sv-" + id);
      el.value = settings[key];
      val.textContent = fmt(key);
      el.addEventListener("input", () => { settings[key] = parseFloat(el.value); val.textContent = fmt(key); saveSettings(); });
    };
    bind("move", "moveSpeed");
    bind("accel", "accel");
    bind("scroll", "scrollSpeed");

    const dir = modalRoot.querySelector("#set-scrolldir");
    dir.checked = settings.scrollDir === -1;
    dir.addEventListener("change", () => { settings.scrollDir = dir.checked ? -1 : 1; saveSettings(); });

    modalRoot.querySelectorAll("#set-theme button").forEach((b) => {
      b.classList.toggle("on", b.dataset.theme === (settings.theme || "dark"));
      b.addEventListener("click", () => {
        settings.theme = b.dataset.theme; saveSettings(); applyTheme();
        modalRoot.querySelectorAll("#set-theme button").forEach((x) => x.classList.toggle("on", x === b));
      });
    });

    modalRoot.querySelector("#set-reset").addEventListener("click", () => {
      settings = Object.assign({}, SETTINGS_DEFAULTS); saveSettings(); applyTheme(); openSettings();
    });
    updateLogos();   // About 로고를 현재 테마에 맞게
  }
  document.getElementById("settings-btn").addEventListener("click", openSettings);

  // ═════════ 트랙패드 ═════════
  const ACCEL_CAP = 30;   // 가속 상한(px/이벤트). 배율/가속량/스크롤은 settings 에서 조절
  const TAP_MS = 250, TAP_MOVE = 8, DOUBLE_MS = 300;
  const FRICTION = 0.92, MOMENTUM_MIN = 0.04;
  const SWIPE3_THRESH = 45, PINCH_DECIDE = 12, ZOOM_STEP = 0.12;

  const pad = document.getElementById("trackpad");
  let startTime = 0, moved = false, maxTouches = 0;
  let dragging = false, armedForDrag = false;
  let last = null, lastCentroid = null;
  let scrollVX = 0, scrollVY = 0, lastScrollMoveT = 0, momentumRAF = null;
  let lastClickTime = 0, clickCount = 0, lastTapEnd = 0;
  let threeMode = false, g3fired = false, g3start = null, g3last = null;
  let twoMode = null, d0 = 0, c0 = null, lastZoomDist = 0;

  function now() { return performance.now(); }
  function centroid(touches) { let x = 0, y = 0; for (const t of touches) { x += t.clientX; y += t.clientY; } return { x: x / touches.length, y: y / touches.length }; }
  function dist2(touches) { const dx = touches[0].clientX - touches[1].clientX, dy = touches[0].clientY - touches[1].clientY; return Math.hypot(dx, dy); }
  function stopMomentum() { if (momentumRAF) { cancelAnimationFrame(momentumRAF); momentumRAF = null; } scrollVX = 0; scrollVY = 0; }
  function startMomentum() {
    if (Math.hypot(scrollVX, scrollVY) < MOMENTUM_MIN) return;
    let prev = now();
    const step = (t) => {
      const dt = Math.min(t - prev, 32); prev = t;
      scrollVX *= FRICTION; scrollVY *= FRICTION;
      if (Math.hypot(scrollVX, scrollVY) < MOMENTUM_MIN) { momentumRAF = null; return; }
      send({ t: "scroll", dx: scrollVX * dt * settings.scrollSpeed * settings.scrollDir, dy: scrollVY * dt * settings.scrollSpeed * settings.scrollDir });
      momentumRAF = requestAnimationFrame(step);
    };
    momentumRAF = requestAnimationFrame(step);
  }
  function fireSwipeIfNeeded() {
    if (g3fired || !g3start || !g3last) return;
    const dx = g3last.x - g3start.x, dy = g3last.y - g3start.y;
    if (Math.hypot(dx, dy) < SWIPE3_THRESH) return;
    const dir = Math.abs(dx) > Math.abs(dy) ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down");
    send({ t: "gesture", dir }); g3fired = true;
  }

  pad.addEventListener("touchstart", (e) => {
    e.preventDefault(); stopMomentum();
    const n = e.touches.length;
    if (n === 1) {
      startTime = now(); moved = false; maxTouches = 1; dragging = false;
      threeMode = false; g3fired = false; g3start = null; g3last = null; twoMode = null;
      last = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      armedForDrag = (now() - lastTapEnd) < DOUBLE_MS;
    } else { maxTouches = Math.max(maxTouches, n); armedForDrag = false; }
    if (n === 2) { twoMode = null; d0 = dist2(e.touches); c0 = centroid(e.touches); lastZoomDist = d0; }
    if (n >= 3 && !threeMode) { threeMode = true; g3start = centroid(e.touches); g3last = g3start; }
    lastCentroid = centroid(e.touches);
  }, { passive: false });

  pad.addEventListener("touchmove", (e) => {
    e.preventDefault();
    const len = e.touches.length;
    if (threeMode) { if (len >= 3) { g3last = centroid(e.touches); fireSwipeIfNeeded(); } moved = true; return; }
    if (len === 2) {
      const c = centroid(e.touches), d = dist2(e.touches);
      if (twoMode === null) {
        const distChange = Math.abs(d - d0), transChange = c0 ? Math.hypot(c.x - c0.x, c.y - c0.y) : 0;
        if (Math.max(distChange, transChange) > PINCH_DECIDE) { twoMode = distChange > transChange ? "pinch" : "scroll"; if (twoMode === "pinch") lastZoomDist = d; }
      }
      if (twoMode === "pinch") {
        const ratio = d / lastZoomDist;
        if (ratio > 1 + ZOOM_STEP) { send({ t: "zoom", dir: "in" }); lastZoomDist = d; }
        else if (ratio < 1 - ZOOM_STEP) { send({ t: "zoom", dir: "out" }); lastZoomDist = d; }
      } else if (twoMode === "scroll") {
        if (lastCentroid) {
          const dx = c.x - lastCentroid.x, dy = c.y - lastCentroid.y;
          const t = now(), dt = Math.max(t - lastScrollMoveT, 1);
          scrollVX = 0.6 * scrollVX + 0.4 * (dx / dt); scrollVY = 0.6 * scrollVY + 0.4 * (dy / dt); lastScrollMoveT = t;
          if (Math.abs(dx) > 0.1 || Math.abs(dy) > 0.1) send({ t: "scroll", dx: dx * settings.scrollSpeed * settings.scrollDir, dy: dy * settings.scrollSpeed * settings.scrollDir });
        }
      }
      lastCentroid = c; moved = true; armedForDrag = false;
    } else if (len === 1 && last) {
      const x = e.touches[0].clientX, y = e.touches[0].clientY;
      const dx = x - last.x, dy = y - last.y;
      if (Math.abs(dx) > TAP_MOVE || Math.abs(dy) > TAP_MOVE) moved = true;
      if (armedForDrag && !dragging && moved) { dragging = true; send({ t: "down", button: "left" }); }
      if (dx !== 0 || dy !== 0) {
        if (dragging) send({ t: "move", dx: dx * settings.moveSpeed, dy: dy * settings.moveSpeed });
        else { const speed = Math.hypot(dx, dy); const f = settings.moveSpeed * (1 + Math.min(speed, ACCEL_CAP) * settings.accel); send({ t: "move", dx: dx * f, dy: dy * f }); }
      }
      last = { x, y };
    }
  }, { passive: false });

  pad.addEventListener("touchend", (e) => {
    e.preventDefault();
    if (threeMode) {
      fireSwipeIfNeeded();
      if (e.touches.length === 0) { threeMode = false; g3fired = false; g3start = null; g3last = null; twoMode = null; last = null; lastCentroid = null; maxTouches = 0; armedForDrag = false; }
      return;
    }
    if (e.touches.length === 0) {
      if (dragging) { send({ t: "up", button: "left" }); dragging = false; }
      else {
        const duration = now() - startTime;
        if (!moved && duration < TAP_MS) {
          if (maxTouches >= 2) { send({ t: "click", button: "right" }); clickCount = 0; lastClickTime = 0; }
          else { const t = now(); clickCount = (t - lastClickTime < DOUBLE_MS) ? clickCount + 1 : 1; lastClickTime = t; send({ t: "click", button: "left", count: clickCount }); }
          lastTapEnd = now();
        } else if (moved && twoMode === "scroll" && (now() - lastScrollMoveT) < 120) startMomentum();
      }
      last = null; lastCentroid = null; maxTouches = 0; armedForDrag = false; twoMode = null;
    } else {
      if (e.touches.length === 1) last = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      lastCentroid = centroid(e.touches);
    }
  }, { passive: false });

  pad.addEventListener("touchcancel", () => {
    if (threeMode) fireSwipeIfNeeded();
    if (dragging) { send({ t: "up", button: "left" }); dragging = false; }
    threeMode = false; g3fired = false; g3start = null; g3last = null; twoMode = null;
    last = null; lastCentroid = null; maxTouches = 0; armedForDrag = false;
  }, { passive: false });

  renderDeck();
  applySheet(0, false);                 // 시작 시 트랙패드 시트 열림
  sheetHandle.classList.add("open");
  connect();
})();
