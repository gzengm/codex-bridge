import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../../Packages/BridgeCore/Sources/BridgeDesktopUI/Resources/pages-settings.js', import.meta.url), 'utf8');

class Element {
  constructor(tag, className, text = '') {
    Object.assign(this, { tag, className, textContent: text, children: [], listeners: {}, value: '', disabled: false });
  }
  appendChild(child) { this.children.push(child); return child; }
  setAttribute(key, value) { this[key] = value; }
  addEventListener(event, listener) { this.listeners[event] = listener; }
  click() { if (!this.disabled) this.listeners.click?.(); }
  change(value) { if (!this.disabled) { this.value = value; this.onChange?.(value); } }
}

function harness(mode = 'auto', projectID = null) {
  const root = new Element('main');
  const fields = new Map();
  const commands = [];
  const confirmations = [];
  const S = {
    node: (tag, cls, text) => new Element(tag, cls, text),
    clear: element => { element.children = []; },
    section: (container, title) => { const section = new Element('section', '', title); container.appendChild(section); return section; },
    selectField: (label, value, options, onChange) => {
      const wrapper = new Element('label', '', label);
      const control = new Element('select');
      Object.assign(control, { value: value ?? '', options, onChange });
      wrapper.appendChild(control);
      const field = { wrapper, control };
      fields.set(label, field);
      return field;
    },
    choices: (_current, options) => options,
    safeArray: value => Array.isArray(value) ? value : [],
    button: title => new Element('button', '', title),
    badge: title => new Element('span', '', title),
    empty: () => {}, pageHeader: () => {},
  };
  const component = () => ({ root: new Element('div'), update() {} });
  const global = {
    CodexBridgeDesktopPageSupport: S,
    CodexBridgeDesktopFormDraft: {
      selectOptions: (control, options) => { control.options = options; },
      bind: controls => ({ update: values => { for (const key in values) controls[key].value = values[key]; } }),
    },
    CodexBridgeDesktopSettingsModels: { preferences: component },
    CodexBridgeDesktopSettingsAgents: { create: component },
    CodexBridgeDesktopSettingsQoderPermissions: { create: component },
    CodexBridgeDesktopDirect: { create: component },
    CodexBridgeDesktopSettingsInstructions: { create: component },
    confirm: message => { confirmations.push(message); return global.consent; },
    consent: true,
  };
  vm.runInNewContext(source, { window: global, document: { getElementById: () => root } });
  const page = {
    header: {}, directApprovalMode: mode, directFullAccessProjectID: projectID,
    directApprovalOptions: [{ id: 'require', title: '每次询问' }, { id: 'auto', title: '自动' }, { id: 'full-access', title: '完全访问' }],
    directFullAccessProjectOptions: [{ id: 'first', title: 'First fixture' }, { id: 'second', title: 'Second fixture' }],
    taskStartApprovalMode: 'require', taskStartApprovalOptions: [{ id: 'require', title: '每次询问' }, { id: 'auto', title: '自动' }],
    canSaveApprovalModes: true, keepServiceRunningAfterExit: true,
  };
  const render = () => global.CodexBridgeDesktopSettingsPage.render(page, (command, payload) => commands.push({ command, payload }));
  render();
  function find(element, title) { return element.textContent === title ? element : element.children.map(child => find(child, title)).find(Boolean); }
  return { global, page, fields, commands, confirmations, render, enable: find(root, '确认启用此项目完全访问') };
}

test('three Direct options and unchanged legacy/task selection', () => {
  for (const mode of ['require', 'auto']) {
    const h = harness(mode);
    assert.deepEqual(h.fields.get('Direct 操作').control.options.map(item => item.title), ['每次询问', '自动', '完全访问']);
    assert.equal(h.fields.get('Direct 操作').control.value, mode);
    assert.deepEqual(h.fields.get('远程任务启动').control.options.map(item => item.id), ['require', 'auto']);
    assert.equal(h.commands.length, 0);
  }
});

test('full access requires explicit project and confirmation', () => {
  const h = harness();
  h.fields.get('Direct 操作').control.change('full-access');
  assert.equal(h.commands.length, 0);
  assert.equal(h.fields.get('完全访问项目').control.value, '');
  assert.equal(h.enable.disabled, true);
  h.fields.get('完全访问项目').control.change('first');
  assert.equal(h.commands.length, 0);
  h.enable.click();
  assert.equal(h.confirmations.length, 1);
  assert.match(h.confirmations[0], /First fixture/);
  assert.match(h.confirmations[0], /本机文件/);
  assert.match(h.confirmations[0], /网络拒绝/);
  assert.match(h.confirmations[0], /其他项目及 Agent 权限不变/);
  assert.deepEqual(JSON.parse(JSON.stringify(h.commands)), [{ command: 'setDirectApprovalMode', payload: { mode: 'full-access', projectID: 'first', confirmed: true } }]);
});

test('cancel leaves saved policy and project unchanged', () => {
  const h = harness();
  h.global.consent = false;
  h.fields.get('Direct 操作').control.change('full-access');
  h.fields.get('完全访问项目').control.change('second');
  h.enable.click();
  assert.equal(h.commands.length, 0);
  assert.equal(h.fields.get('Direct 操作').control.value, 'auto');
  assert.equal(h.fields.get('完全访问项目').control.value, '');
});

test('saved scope, explicit scope replacement and revocation', () => {
  const h = harness('full-access', 'first');
  assert.equal(h.fields.get('完全访问项目').control.value, 'first');
  assert.equal(h.enable.disabled, true);
  h.fields.get('完全访问项目').control.change('second');
  assert.equal(h.commands.length, 0);
  h.enable.click();
  assert.equal(h.commands[0].payload.projectID, 'second');
  h.fields.get('Direct 操作').control.change('require');
  assert.equal(h.commands[1].payload.mode, 'require');
});

test('unavailable service disables opt-in and legacy changes', () => {
  const h = harness();
  h.page.canSaveApprovalModes = false;
  h.render();
  assert.equal(h.fields.get('Direct 操作').control.disabled, true);
  assert.equal(h.fields.get('完全访问项目').control.disabled, true);
  assert.equal(h.enable.disabled, true);
  h.enable.click();
  assert.equal(h.commands.length, 0);
});
