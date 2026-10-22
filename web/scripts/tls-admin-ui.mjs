// Real HTTPS browser traffic: no response fulfillment, relay or global trust changes.
import { chromium, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';

let input = '';
for await (const chunk of process.stdin) { input += chunk; assert(input.length < 4096); }
const { origin, credential, pin, output } = JSON.parse(input);
assert(/^https:\/\/localhost:\d+$/.test(origin));
assert(/^[A-Za-z0-9+/]{43}=$/.test(pin));
const secrets = [credential], errors = [];
let browser, page, stage = 'launch';
try {
  // Only this fresh browser process accepts this disposable leaf SPKI. Socket
  // tests separately verify the CA/hostname and reject untrusted/wrong-host TLS.
  browser = await chromium.launch({ channel: 'chrome', headless: true,
    args: ['--ignore-certificate-errors-spki-list=' + pin] });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, ignoreHTTPSErrors: false });
  await context.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort());
  page = await context.newPage();
  page.on('pageerror', () => errors.push('page error'));
  page.on('console', entry => { if (/content security policy|refused to execute|refused to apply/i.test(entry.text())) errors.push('CSP error'); });
  stage = 'HTTPS navigation and login';
  const navigation = await page.goto(origin);
  assert(navigation.status() === 200);
  const tls = await navigation.securityDetails();
  assert(/^TLS 1\.[23]$/.test(tls?.protocol) && tls.issuer === 'CodexOne synthetic TLS CA');
  await page.getByRole('link', { name: '访问密钥', exact: true }).click();
  await expect(page.getByRole('heading', { name: '管理员登录' })).toBeVisible();
  await page.getByLabel('管理员凭证', { exact: true }).fill(credential);
  await page.getByRole('button', { name: '登录管理台' }).click();
  await expect(page.getByRole('button', { name: '创建密钥', exact: true })).toBeEnabled();
  const cookie = (await context.cookies(origin)).find(item => item.name === '__Host-codexone_admin');
  assert(cookie?.secure && cookie.httpOnly && cookie.sameSite === 'Strict' && cookie.path === '/');
  secrets.push(cookie.value);
  assert(await page.evaluate(async () => (await fetch('/api/keys', { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: '{}' })).status) === 403);
  stage = 'create and persist';
  await page.getByRole('button', { name: '创建密钥', exact: true }).click();
  await page.getByLabel('主体标识', { exact: true }).fill('tls-browser');
  await page.getByRole('checkbox', { name: 'synthetic-text', exact: true }).check();
  await page.getByRole('button', { name: '创建 API Key', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: '保存一次性凭证' });
  await expect(dialog).toBeVisible();
  const secret = await dialog.getByLabel('新 API Key', { exact: true }).inputValue();
  assert(/^co1_[A-Za-z0-9_-]{43}$/.test(secret)); secrets.push(secret);
  await dialog.getByRole('button', { name: '我已保存，关闭' }).click();
  await page.reload();
  await page.getByRole('link', { name: '访问密钥', exact: true }).click();
  const row = page.getByRole('row').filter({ hasText: 'tls-browser' });
  await expect(row).toBeVisible();
  stage = 'disable and persist';
  await row.getByRole('button', { name: '禁用', exact: true }).click();
  await expect(row.getByRole('button', { name: '启用', exact: true })).toBeVisible();
  await page.reload();
  await page.getByRole('link', { name: '访问密钥', exact: true }).click();
  await expect(row.getByRole('button', { name: '启用', exact: true })).toBeVisible();
  assert(await page.evaluate(() => !localStorage.length && !sessionStorage.length));
  const html = await page.content();
  assert(secrets.every(secret => !html.includes(secret)) && errors.length === 0);
  await mkdir(output, { recursive: true });
  await page.screenshot({ path: resolve(output, 'desktop.png'), fullPage: true,
    mask: [page.locator('input[type="password"]'), page.locator('input.secret-value')] });
  stage = 'logout';
  await page.getByRole('button', { name: '退出登录', exact: true }).click();
  await expect(page.getByRole('heading', { name: '管理员登录' })).toBeVisible();
  assert(!(await context.cookies(origin)).some(item => item.name === '__Host-codexone_admin'));
  await page.reload();
  await page.getByRole('link', { name: '访问密钥', exact: true }).click();
  await expect(page.getByRole('heading', { name: '管理员登录' })).toBeVisible();
  console.log('PASS: Chrome direct HTTPS/Nginx TLS: login, secure session, CSRF refusal, create/clear/reload, disable persistence and logout; disposable leaf SPKI pin');
} catch {
  console.error('FAIL: real HTTPS management browser check at ' + stage);
  process.exitCode = 1;
} finally { await browser?.close(); }
