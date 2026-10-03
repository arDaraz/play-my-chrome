import {isAbsolute} from 'node:path';
import {pathToFileURL} from 'node:url';
import {SkillError} from './errors.mjs';

const pageTimeout = 15000;

const arities = {'tab-list': 0, 'tab-new': [0, 1], 'tab-select': 1, 'tab-close': 0,
  goto: 1, snapshot: 0, click: 1, fill: 2, press: 1, eval: 1, run: 1, screenshot: 1};

export function validateCommand(command, args) {
  if (!Object.hasOwn(arities, command) || !Array.isArray(args) || args.some(arg => typeof arg !== 'string')) {
    throw new SkillError('Unknown command or invalid arguments. Run --help.');
  }
  const arity = arities[command];
  if (!(Array.isArray(arity) ? arity.includes(args.length) : arity === args.length)) {
    throw new SkillError(`Invalid argument count for ${command}. Run --help.`);
  }
  if (['run', 'screenshot'].includes(command) && !isAbsolute(args[0])) {
    throw new SkillError(`${command} requires an absolute file path.`);
  }
}

class BrowserCommands {
  tabs = new Map();
  ownedTabs = new Set();
  selected;
  sequence = 0;
  scriptSequence = 0;

  constructor(browser, profileScope) { this.browser = browser; this.profileScope = profileScope; }

  tabId(page) {
    if (!this.tabs.has(page)) this.tabs.set(page, String(++this.sequence));
    return this.tabs.get(page);
  }

  select(page) {
    page.setDefaultTimeout(pageTimeout);
    page.setDefaultNavigationTimeout(pageTimeout);
    this.selected = page;
  }

  selectedPage() {
    if (!this.selected || this.selected.isClosed()) throw new SkillError('Select an open tab with tab-select, or create one with tab-new.');
    return this.selected;
  }

  async listTabs() {
    const scopedPages = await Promise.all((await this.browser.pages()).map(async page =>
      !this.profileScope || await this.profileScope.includes(page) ? page : undefined));
    return Promise.all(scopedPages.filter(Boolean).map(async page => ({
      id: this.tabId(page), selected: page === this.selected, owned: this.ownedTabs.has(page),
      url: page.url(), title: await page.title(),
    })));
  }

  async newTab([url = 'about:blank']) {
    const page = await this.browser.newPage();
    try { await this.profileScope?.assertPage(page); }
    catch (error) { await page.close(); throw error; }
    this.ownedTabs.add(page);
    this.select(page);
    if (url !== 'about:blank') await page.goto(url, {waitUntil: 'domcontentloaded'});
    return {id: this.tabId(page), url: page.url()};
  }

  async selectTab([id]) {
    const page = [...this.tabs].find(([tab, storedId]) => storedId === id && !tab.isClosed())?.[0];
    if (!page) throw new SkillError('The tab ID is unavailable. Run tab-list again.');
    await this.profileScope?.assertPage(page);
    this.select(page);
    return {id: this.tabId(page), url: page.url()};
  }

  async closeTab() {
    const page = this.selectedPage();
    if (!this.ownedTabs.has(page)) throw new SkillError('tab-close only closes tabs created by this skill. Close existing user tabs in Chrome.');
    await page.close();
    this.ownedTabs.delete(page);
    this.tabs.delete(page);
    this.selected = undefined;
    return {closed: true};
  }

  async navigate([url]) {
    const page = this.selectedPage();
    await page.goto(url, {waitUntil: 'domcontentloaded'});
    return {url: page.url()};
  }

  async snapshot() {
    const page = this.selectedPage();
    return {url: page.url(), tree: await page.accessibility.snapshot()};
  }

  async runScript([path]) {
    const script = await import(`${pathToFileURL(path).href}?run=${++this.scriptSequence}`);
    if (typeof script.default !== 'function') throw new SkillError('The run script must export a default async function that receives page.');
    return script.default(this.selectedPage());
  }

  async screenshot([path]) {
    await this.selectedPage().screenshot({path});
    return {path};
  }
}

export function createBrowserCommands(browser, profileScope) {
  const controller = new BrowserCommands(browser, profileScope);
  const commands = {
    'tab-list': () => controller.listTabs(), 'tab-new': args => controller.newTab(args),
    'tab-select': args => controller.selectTab(args), 'tab-close': () => controller.closeTab(),
    goto: args => controller.navigate(args), snapshot: () => controller.snapshot(),
    click: ([selector]) => controller.selectedPage().locator(selector).click(),
    fill: ([selector, text]) => controller.selectedPage().locator(selector).fill(text),
    press: ([key]) => controller.selectedPage().keyboard.press(key),
    eval: ([expression]) => controller.selectedPage().evaluate(expression),
    run: args => controller.runScript(args), screenshot: args => controller.screenshot(args),
  };
  return async (command, args) => {
    validateCommand(command, args);
    if (!['tab-new', 'tab-list', 'tab-select'].includes(command)) await profileScope?.assertPage(controller.selectedPage());
    return commands[command](args);
  };
}
