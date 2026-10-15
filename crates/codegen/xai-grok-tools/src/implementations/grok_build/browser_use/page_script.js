(function (op, opts) {
  'use strict';
  // Runs in an isolated world: the page's scripts share the DOM but cannot see this state.
  const state = globalThis.__crokState || (globalThis.__crokState = { refs: new Map(), ids: new WeakMap() });
  let next = Math.max(1, opts.next | 0);
  const MAX_NAME = 150;
  const LIMIT = 50000;

  const clean = (value, max) => {
    const text = String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
    return text.length > max ? text.slice(0, max) + '…' : text;
  };
  const quote = (value) => '"' + String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  const refOf = (el) => {
    let id = state.ids.get(el);
    if (!id) {
      id = 'ref_' + next++;
      state.ids.set(el, id);
      state.refs.set(id, new WeakRef(el));
    }
    return id;
  };
  const byRef = (id) => {
    const held = state.refs.get(String(id));
    const el = held && held.deref();
    return el && el.isConnected ? el : null;
  };
  const stale = (id) => ({
    error: 'Error: ' + String(id) + ' is stale or not found on the current page. Re-read the page to get fresh references.',
  });

  const INTERACTIVE = new Set([
    'link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'listbox', 'option',
    'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
    'treeitem', 'clickable',
  ]);
  const NAME_FROM_CONTENT = new Set([
    'link', 'button', 'heading', 'tab', 'option', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
    'treeitem', 'cell', 'columnheader', 'rowheader', 'switch', 'clickable',
  ]);
  const STRUCTURE = new Set([
    'navigation', 'main', 'banner', 'contentinfo', 'complementary', 'form', 'dialog', 'alertdialog',
    'list', 'listitem', 'table', 'row', 'cell', 'columnheader', 'rowheader', 'region', 'article',
    'img', 'paragraph', 'group', 'heading', 'iframe', 'video', 'audio', 'separator', 'alert',
    'status', 'toolbar', 'menu', 'menubar', 'tablist', 'tabpanel', 'tree', 'grid', 'figure', 'search',
  ]);
  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK', 'TITLE']);

  const tagOf = (el) => el.tagName.toUpperCase();
  const inputRole = (el) => {
    switch ((el.getAttribute('type') || 'text').toLowerCase()) {
      case 'hidden': return null;
      case 'button': case 'submit': case 'reset': case 'image': case 'file': return 'button';
      case 'checkbox': return 'checkbox';
      case 'radio': return 'radio';
      case 'range': return 'slider';
      case 'number': return 'spinbutton';
      case 'search': return 'searchbox';
      default: return 'textbox';
    }
  };
  const roleOf = (el) => {
    const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
    if (explicit && explicit !== 'presentation' && explicit !== 'none' && explicit !== 'generic') return explicit;
    const outsideSections = () => !el.closest('article, section, main, aside, nav');
    switch (tagOf(el)) {
      case 'A': case 'AREA': return el.hasAttribute('href') ? 'link' : null;
      case 'BUTTON': case 'SUMMARY': return 'button';
      case 'INPUT': return inputRole(el);
      case 'TEXTAREA': return 'textbox';
      case 'SELECT': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
      case 'OPTION': return 'option';
      case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
      case 'IMG': return el.getAttribute('alt') === '' ? null : 'img';
      case 'SVG': return el.getAttribute('aria-label') || el.querySelector('title') ? 'img' : null;
      case 'NAV': return 'navigation';
      case 'MAIN': return 'main';
      case 'HEADER': return outsideSections() ? 'banner' : null;
      case 'FOOTER': return outsideSections() ? 'contentinfo' : null;
      case 'ASIDE': return 'complementary';
      case 'FORM': return 'form';
      case 'DIALOG': return 'dialog';
      case 'UL': case 'OL': case 'MENU': return 'list';
      case 'LI': return 'listitem';
      case 'TABLE': return 'table';
      case 'TR': return 'row';
      case 'TD': return 'cell';
      case 'TH': return 'columnheader';
      case 'ARTICLE': return 'article';
      case 'SECTION': return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
      case 'P': return 'paragraph';
      case 'IFRAME': case 'FRAME': return 'iframe';
      case 'VIDEO': return 'video';
      case 'AUDIO': return 'audio';
      case 'DETAILS': case 'FIELDSET': return 'group';
      case 'HR': return 'separator';
      case 'FIGURE': return 'figure';
      case 'SEARCH': return 'search';
    }
    if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return 'textbox';
    return null;
  };

  const textOf = (el) => clean(el.innerText !== undefined ? el.innerText : el.textContent, MAX_NAME);
  const nameOf = (el, role) => {
    const label = el.getAttribute('aria-label');
    if (label && label.trim()) return clean(label, MAX_NAME);
    const by = el.getAttribute('aria-labelledby');
    if (by) {
      const text = by.split(/\s+/)
        .map((id) => el.ownerDocument.getElementById(id))
        .filter(Boolean)
        .map((node) => node.textContent)
        .join(' ');
      if (text.trim()) return clean(text, MAX_NAME);
    }
    const tag = tagOf(el);
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
      const type = (el.getAttribute('type') || '').toLowerCase();
      if (type === 'button' || type === 'submit' || type === 'reset') return clean(el.value || type, MAX_NAME);
      if (type === 'image') return clean(el.getAttribute('alt') || 'image', MAX_NAME);
      if (el.labels && el.labels.length) {
        const text = Array.from(el.labels).map((l) => l.innerText || l.textContent).join(' ');
        if (text.trim()) return clean(text, MAX_NAME);
      }
      return clean(el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('name') || '', MAX_NAME);
    }
    if (tag === 'IMG' || tag === 'AREA') return clean(el.getAttribute('alt') || el.getAttribute('title') || '', MAX_NAME);
    if (tag === 'SVG') {
      const title = el.querySelector('title');
      return clean(title ? title.textContent : '', MAX_NAME);
    }
    if (tag === 'IFRAME' || tag === 'FRAME') {
      return clean(el.getAttribute('title') || el.getAttribute('name') || el.getAttribute('src') || '', MAX_NAME);
    }
    if (role && NAME_FROM_CONTENT.has(role)) {
      const text = textOf(el);
      if (text) return text;
    }
    return clean(el.getAttribute('title') || '', MAX_NAME);
  };

  const checkedOf = (el) => (typeof el.checked === 'boolean' && tagOf(el) === 'INPUT'
    ? el.checked
    : el.getAttribute('aria-checked') === 'true');
  const extras = (el, role) => {
    const parts = [];
    const tag = tagOf(el);
    if (role === 'link') {
      const href = el.getAttribute('href');
      if (href) parts.push('href=' + quote(clean(href, 120)));
    }
    if (role === 'heading') {
      const level = el.getAttribute('aria-level') || (/^H([1-6])$/.exec(tag) || [])[1];
      if (level) parts.push('level=' + level);
    }
    if (['textbox', 'searchbox', 'spinbutton', 'combobox', 'slider'].includes(role)) {
      if (tag === 'SELECT') {
        const option = el.selectedOptions && el.selectedOptions[0];
        if (option) parts.push('value=' + quote(clean(option.text, 80)));
      } else if (typeof el.value === 'string' && el.value) {
        const secret = (el.getAttribute('type') || '').toLowerCase() === 'password';
        parts.push('value=' + quote(secret ? '••••' : clean(el.value, 80)));
      } else if (el.isContentEditable) {
        const text = clean(el.innerText, 80);
        if (text) parts.push('value=' + quote(text));
      }
      const placeholder = el.getAttribute('placeholder');
      if (placeholder && placeholder.trim() && nameOf(el, role) !== clean(placeholder, MAX_NAME)) {
        parts.push('placeholder=' + quote(clean(placeholder, 80)));
      }
    }
    if (['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(role)) {
      parts.push(checkedOf(el) ? 'checked' : 'unchecked');
    }
    if ((role === 'option' || role === 'tab' || role === 'treeitem')
      && (el.selected === true || el.getAttribute('aria-selected') === 'true')) {
      parts.push('selected');
    }
    const expanded = el.getAttribute('aria-expanded');
    if (expanded === 'true') parts.push('expanded');
    else if (expanded === 'false') parts.push('collapsed');
    if (el.disabled === true || el.getAttribute('aria-disabled') === 'true') parts.push('disabled');
    if (tag === 'INPUT' && (el.getAttribute('type') || '').toLowerCase() === 'file') parts.push('file-input');
    return parts.length ? ' ' + parts.join(' ') : '';
  };

  const shown = (el) => {
    if (typeof el.checkVisibility === 'function') {
      return el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
    }
    const style = el.ownerDocument.defaultView.getComputedStyle(el);
    return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
  };
  // Where a same-origin frame's viewport sits in the top viewport
  const frameOffset = (doc) => {
    let x = 0;
    let y = 0;
    let win = doc.defaultView;
    while (win && win.frameElement) {
      const frame = win.frameElement;
      const r = frame.getBoundingClientRect();
      x += r.left + frame.clientLeft;
      y += r.top + frame.clientTop;
      win = frame.ownerDocument.defaultView;
    }
    return { x, y };
  };
  const rectOf = (el) => {
    const rects = Array.from(el.getClientRects()).filter((r) => r.width > 0 && r.height > 0);
    const r = rects.length === 1 || !rects.length ? el.getBoundingClientRect() : rects[0];
    const o = frameOffset(el.ownerDocument);
    return { left: r.left + o.x, top: r.top + o.y, width: r.width, height: r.height };
  };
  const inViewport = (r) => r.width > 0 && r.height > 0 && r.top + r.height > 0 && r.left + r.width > 0
    && r.top < window.innerHeight && r.left < window.innerWidth;
  const pointer = (el) => {
    try {
      return el.ownerDocument.defaultView.getComputedStyle(el).cursor === 'pointer';
    } catch (e) {
      return false;
    }
  };
  const clickableRole = (el, hasBox) => {
    if (!hasBox) return null;
    if (el.hasAttribute('onclick') || (el.hasAttribute('tabindex') && el.tabIndex >= 0)) return 'clickable';
    if (el.childElementCount <= 2 && pointer(el) && !(el.parentElement && pointer(el.parentElement))) return 'clickable';
    return null;
  };
  const childrenOf = (el) => {
    if (tagOf(el) === 'SLOT') {
      const assigned = el.assignedNodes({ flatten: true });
      return assigned.length ? assigned : Array.from(el.childNodes);
    }
    return Array.from(el.shadowRoot ? el.shadowRoot.childNodes : el.childNodes);
  };
  const frameDocument = (el) => {
    try {
      return el.contentDocument;
    } catch (e) {
      return null;
    }
  };

  const readPage = () => {
    const filter = opts.filter === 'interactive' || opts.filter === 'all' ? opts.filter : 'visible';
    const maxDepth = Math.max(1, Math.min(opts.depth || 15, 100));
    const lines = [];
    let chars = 0;
    let truncated = false;
    const emit = (depth, text) => {
      if (truncated) return;
      const line = '  '.repeat(depth) + text;
      if (chars + line.length + 1 > LIMIT) {
        truncated = true;
        return;
      }
      lines.push(line);
      chars += line.length + 1;
    };
    const visit = (node, depth, insideNamed) => {
      if (truncated || depth >= maxDepth) return;
      if (node.nodeType === 3) {
        if (filter === 'interactive' || insideNamed) return;
        const text = clean(node.textContent, 200);
        if (text) emit(depth, 'text ' + quote(text));
        return;
      }
      if (node.nodeType !== 1) return;
      const el = node;
      if (SKIP.has(tagOf(el)) || el.getAttribute('aria-hidden') === 'true' || !shown(el)) return;
      const rect = rectOf(el);
      const hasBox = rect.width > 0 && rect.height > 0;
      const role = roleOf(el) || clickableRole(el, hasBox);
      const interactive = !!role && INTERACTIVE.has(role);
      const printable = !!role && (interactive || (filter !== 'interactive' && STRUCTURE.has(role)));
      const placed = hasBox && (filter === 'all' || inViewport(rect));
      let childDepth = depth;
      let named = insideNamed;
      if (printable && placed) {
        const name = nameOf(el, role);
        emit(depth, role + (name ? ' ' + quote(name) : '') + ' [' + refOf(el) + ']' + extras(el, role));
        childDepth = depth + 1;
        named = named || (NAME_FROM_CONTENT.has(role) && !!name);
      }
      if (role === 'iframe') {
        const doc = frameDocument(el);
        if (doc && doc.body) visit(doc.body, childDepth, named);
        else if (printable && placed) emit(childDepth, 'text "(another site\'s frame: use screenshot and coordinates inside it)"');
        return;
      }
      if (tagOf(el) === 'SELECT' || tagOf(el) === 'TEXTAREA' || tagOf(el) === 'INPUT') return;
      for (const child of childrenOf(el)) visit(child, childDepth, named);
    };
    let start = document.body || document.documentElement;
    if (opts.ref) {
      start = byRef(opts.ref);
      if (!start) return stale(opts.ref);
    }
    visit(start, 0, false);
    return { text: lines.join('\n'), truncated };
  };

  const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const SYNONYMS = {
    button: ['button', 'btn', 'submit', 'press'],
    link: ['link', 'anchor', 'url'],
    textbox: ['field', 'input', 'box', 'text', 'textbox', 'textarea', 'entry'],
    searchbox: ['search', 'field', 'input', 'box'],
    checkbox: ['checkbox', 'check', 'tick', 'toggle'],
    radio: ['radio', 'option', 'choice'],
    combobox: ['dropdown', 'select', 'combo', 'combobox', 'menu', 'picker', 'list'],
    listbox: ['list', 'listbox', 'select'],
    img: ['image', 'img', 'picture', 'photo', 'icon', 'logo'],
    heading: ['heading', 'title', 'header', 'headline'],
    tab: ['tab'],
    menuitem: ['menu', 'item', 'option'],
    slider: ['slider', 'range'],
    switch: ['switch', 'toggle'],
    option: ['option', 'choice', 'item'],
    clickable: ['button', 'clickable', 'item'],
  };
  const find = () => {
    const query = clean(opts.query, 300).toLowerCase();
    const tokens = query.split(/[^\p{L}\p{N}_]+/u).filter((t) => t.length > 1 || /\p{N}/u.test(t));
    if (!tokens.length) return { error: 'Error: `query` must describe the element to find, such as "search field".' };
    const words = tokens.map((t) => new RegExp('(^|[^\\p{L}\\p{N}])' + escapeRegExp(t) + '($|[^\\p{L}\\p{N}])', 'u'));
    const results = [];
    const consider = (el) => {
      if (SKIP.has(tagOf(el))) return;
      const explicit = roleOf(el);
      const role = explicit || ((el.hasAttribute('onclick') || (el.hasAttribute('tabindex') && el.tabIndex >= 0)) ? 'clickable' : null);
      if (!role) return;
      const labelled = el.hasAttribute('aria-label') || el.hasAttribute('title');
      if (!(INTERACTIVE.has(role) || role === 'heading' || role === 'img' || (STRUCTURE.has(role) && labelled))) return;
      if (!shown(el)) return;
      const rect = rectOf(el);
      if (!(rect.width > 0 && rect.height > 0)) return;
      const name = nameOf(el, role).toLowerCase();
      const cls = typeof el.className === 'string' ? el.className : (el.className && el.className.baseVal) || '';
      const attrs = (['placeholder', 'title', 'aria-label', 'alt', 'name', 'id', 'value', 'data-testid', 'type']
        .map((a) => el.getAttribute(a) || '').join(' ') + ' ' + cls).toLowerCase();
      let score = 0;
      tokens.forEach((token, i) => {
        if (name === token) score += 6;
        else if (words[i].test(name)) score += 4;
        else if (name.includes(token)) score += 2;
        if (role === token || (SYNONYMS[role] || []).includes(token)) score += 2;
        if (attrs.includes(token)) score += 1;
      });
      if (score > 0) results.push({ el, role, score, order: results.length });
    };
    const scan = (root) => {
      for (const el of root.querySelectorAll('*')) {
        consider(el);
        if (el.shadowRoot) scan(el.shadowRoot);
        if (tagOf(el) === 'IFRAME') {
          const doc = frameDocument(el);
          if (doc) scan(doc);
        }
      }
    };
    scan(document);
    results.sort((a, b) => b.score - a.score || a.order - b.order);
    const best = results.slice(0, 20);
    if (!best.length) {
      return { text: 'No element matched ' + quote(clean(opts.query, 120)) + '. Try read_page with filter "interactive".' };
    }
    return {
      text: best.map((r) => {
        const name = nameOf(r.el, r.role);
        const outside = inViewport(rectOf(r.el)) ? '' : ' (outside the viewport)';
        return r.role + (name ? ' ' + quote(name) : '') + ' [' + refOf(r.el) + ']' + extras(r.el, r.role) + outside;
      }).join('\n'),
    };
  };

  const pageText = () => {
    let root = document.body || document.documentElement;
    let best = 0;
    for (const el of document.querySelectorAll('main, [role="main"], article')) {
      const length = (el.innerText || '').trim().length;
      if (length > best) {
        best = length;
        if (length > 500) root = el;
      }
    }
    const text = (root.innerText || root.textContent || '')
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
    return { text: 'Title: ' + document.title + '\nURL: ' + location.href + '\n\n' + text };
  };

  const fire = (el, type) => el.dispatchEvent(new Event(type, { bubbles: true }));
  const formInput = () => {
    const el = byRef(opts.ref);
    if (!el) return stale(opts.ref);
    const value = opts.value;
    const tag = tagOf(el);
    const type = (el.getAttribute('type') || '').toLowerCase();
    if (tag === 'SELECT') {
      const want = String(value);
      const options = Array.from(el.options);
      const option = options.find((o) => o.value === want)
        || options.find((o) => clean(o.text, 500) === clean(want, 500))
        || options.find((o) => o.text.toLowerCase().includes(want.toLowerCase()));
      if (!option) {
        const known = options.slice(0, 30).map((o) => quote(clean(o.text, 60))).join(', ');
        return { error: 'Error: ' + opts.ref + ' has no option ' + quote(want) + '. Its options are: ' + known + '.' };
      }
      el.value = option.value;
      option.selected = true;
      fire(el, 'input');
      fire(el, 'change');
      return { ok: true };
    }
    if (tag === 'INPUT' && (type === 'checkbox' || type === 'radio')) {
      const want = typeof value === 'boolean'
        ? value
        : ['true', '1', 'on', 'yes', 'checked'].includes(String(value).toLowerCase());
      if (el.checked !== want) el.click();
      return { ok: true };
    }
    if (tag === 'INPUT' && type === 'file') {
      return { error: 'Error: ' + opts.ref + ' is a file input; use file_upload.' };
    }
    if (tag === 'INPUT' || tag === 'TEXTAREA') {
      const proto = tag === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
      el.focus();
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, String(value));
      fire(el, 'input');
      fire(el, 'change');
      return { ok: true };
    }
    if (el.isContentEditable) {
      el.focus();
      el.textContent = String(value);
      el.dispatchEvent(new InputEvent('input', { bubbles: true }));
      return { ok: true };
    }
    return { error: 'Error: ' + opts.ref + ' is not a form field.' };
  };

  const center = () => {
    const el = byRef(opts.ref);
    if (!el) return stale(opts.ref);
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const r = rectOf(el);
    if (!(r.width > 0 && r.height > 0)) {
      return { error: 'Error: ' + opts.ref + ' has no visible area, so it cannot be clicked. Read the page again.' };
    }
    const x = r.left + r.width / 2;
    const y = r.top + r.height / 2;
    if (x < 0 || y < 0 || x >= window.innerWidth || y >= window.innerHeight) {
      return { error: 'Error: ' + opts.ref + ' could not be scrolled into view.' };
    }
    return { x, y };
  };

  const scrollTo = () => {
    const el = byRef(opts.ref);
    if (!el) return stale(opts.ref);
    el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
    return { ok: true };
  };

  if (op === 'element') return byRef(opts.ref);
  let result;
  switch (op) {
    case 'read_page': result = readPage(); break;
    case 'find': result = find(); break;
    case 'get_page_text': result = pageText(); break;
    case 'form_input': result = formInput(); break;
    case 'center': result = center(); break;
    case 'scroll_to': result = scrollTo(); break;
    default: result = { error: 'Error: unknown page operation ' + op };
  }
  result.next = next;
  return result;
})
