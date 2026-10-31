# 第三方许可清单

离线记录锁定依赖的版本、声明许可和本地许可正文可用性。

## 范围与分发

本项目主体使用 MIT；第三方代码继续受各自许可约束。本清单基于当前锁文件及本 worktree 离线安装所得文件，不是依赖漏洞审计或法律意见。没有联网补查，也不从包名推断许可证。平台可选包未安装时标为待核验。

容器构建在 `deploy/Dockerfile` 中收集 Swift checkouts 与 npm 生产依赖的 LICENSE/NOTICE/COPYING，分发到 `/opt/codexone/licenses/swift`、`/opt/codexone/licenses/npm`，项目 LICENSE 在 `/opt/codexone/LICENSE`；系统包原有版权材料须保留。安装验证要求运行依赖具有许可正文，不能因清单存在就声称实际镜像已验收。

独立二进制和 SPA 分发也必须附上适用 LICENSE、版权与 NOTICE，参见[发版规则](docs/development/releasing.md)。`web/licenses` 为漏带许可正文的锁定包提供补充。

## npm 锁定依赖

“正文已读”表示实际读取本地随包许可文件，不表示对所有嵌入代码完成权利审查；声明来自锁文件。MIT AND ISC AND BSD-3-Clause 必须同时保留，MIT OR CC0-1.0 保留双许可选择，不擅自替依赖改许可。MPL-2.0 的 lightningcss 为构建依赖；分发或修改工具本身须核对 MPL 的文件级及源码义务。

| 包 | 版本 | 声明许可 | 离线正文 |
|---|---|---|---|
| `@adobe/css-tools` | 4.5.0 | MIT | 正文已读：`LICENSE` |
| `@asamuzakjp/css-color` | 7.1.7 | MIT | 正文已读：`LICENSE` |
| `@asamuzakjp/dom-selector` | 10.0.4 | MIT | 正文已读：`LICENSE` |
| `@babel/code-frame` | 7.29.7 | MIT | 正文已读：`LICENSE` |
| `@babel/helper-validator-identifier` | 7.29.7 | MIT | 正文已读：`LICENSE` |
| `@babel/runtime` | 7.29.10 | MIT | 正文已读：`LICENSE` |
| `@bramus/specificity` | 2.4.3 | MIT | 正文已读：`LICENSE` |
| `@csstools/color-helpers` | 6.1.2 | MIT-0 | 正文已读：`LICENSE.md` |
| `@csstools/css-calc` | 3.4.3 | MIT | 正文已读：`LICENSE.md` |
| `@csstools/css-color-parser` | 4.2.6 | MIT | 正文已读：`LICENSE.md` |
| `@csstools/css-parser-algorithms` | 4.0.2 | MIT | 正文已读：`LICENSE.md` |
| `@csstools/css-syntax-patches-for-csstree` | 1.1.15 | MIT-0 | 正文已读：`LICENSE.md` |
| `@csstools/css-tokenizer` | 4.0.2 | MIT | 正文已读：`LICENSE.md` |
| `@exodus/bytes` | 1.16.0 | MIT | 正文已读：`LICENSE` |
| `@floating-ui/core` | 1.8.0 | MIT | 正文已读：`LICENSE` |
| `@floating-ui/dom` | 1.8.0 | MIT | 正文已读：`LICENSE` |
| `@floating-ui/react` | 0.27.20 | MIT | 正文已读：`LICENSE` |
| `@floating-ui/react-dom` | 2.1.9 | MIT | 正文已读：`LICENSE` |
| `@floating-ui/utils` | 0.2.12 | MIT | 正文已读：`LICENSE` |
| `@jridgewell/resolve-uri` | 3.1.2 | MIT | 正文已读：`LICENSE` |
| `@jridgewell/sourcemap-codec` | 1.6.0 | MIT | 正文已读：`LICENSE` |
| `@jridgewell/trace-mapping` | 0.3.31 | MIT | 正文已读：`LICENSE` |
| `@mantine/charts` | 9.7.3 | MIT | 正文已读：`LICENSE` |
| `@mantine/core` | 9.7.3 | MIT | 正文已读：`LICENSE` |
| `@mantine/form` | 9.7.3 | MIT | 正文已读：`LICENSE` |
| `@mantine/hooks` | 9.7.3 | MIT | 正文已读：`LICENSE` |
| `@mantine/notifications` | 9.7.3 | MIT | 正文已读：`LICENSE` |
| `@mantine/store` | 9.7.3 | MIT | 正文已读：`LICENSE` |
| `@oxc-project/types` | 0.155.0 | MIT | 正文已读：`LICENSE` |
| `@oxlint/binding-android-arm-eabi` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-android-arm64` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-darwin-arm64` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-darwin-x64` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-freebsd-x64` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-linux-arm-gnueabihf` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-linux-arm-musleabihf` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-linux-arm64-gnu` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-linux-arm64-musl` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-linux-ppc64-gnu` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-linux-riscv64-gnu` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-linux-riscv64-musl` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-linux-s390x-gnu` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-linux-x64-gnu` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-linux-x64-musl` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-openharmony-arm64` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-win32-arm64-msvc` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-win32-ia32-msvc` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@oxlint/binding-win32-x64-msvc` | 1.89.0 | MIT | 待核验（本地无许可正文） |
| `@playwright/test` | 1.64.1 | Apache-2.0 | 正文已读：`LICENSE`, `NOTICE` |
| `@reduxjs/toolkit` | 2.13.0 | MIT | 正文已读：`LICENSE` |
| `immer` | 11.2.9 | MIT | 正文已读：`LICENSE` |
| `@remix-run/route-pattern` | 0.22.1 | MIT | 正文已读：`LICENSE` |
| `@rolldown/binding-android-arm-eabi` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-android-arm64` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-darwin-arm64` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-darwin-x64` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-freebsd-x64` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-linux-arm-gnueabihf` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-linux-arm64-gnu` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-linux-arm64-musl` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-linux-ppc64-gnu` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-linux-s390x-gnu` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-linux-x64-gnu` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-linux-x64-musl` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-openharmony-arm64` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-win32-arm64-msvc` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/binding-win32-x64-msvc` | 1.2.15 | MIT | 待核验（本地无许可正文） |
| `@rolldown/pluginutils` | 1.0.1 | MIT | 正文已读：`LICENSE` |
| `@standard-schema/spec` | 1.1.0 | MIT | 正文已读：`LICENSE` |
| `@standard-schema/utils` | 0.3.0 | MIT | 正文已读：`LICENSE` |
| `@tabler/icons` | 3.35.0 | MIT | 正文已读：`LICENSE`, `icons/outline/license-off.svg`, `icons/outline/license.svg` |
| `@tabler/icons-react` | 3.35.0 | MIT | 正文已读：`LICENSE` |
| `@tanstack/query-core` | 5.104.5 | MIT | 正文已读：`LICENSE` |
| `@tanstack/react-query` | 5.104.5 | MIT | 正文已读：`LICENSE` |
| `@testing-library/dom` | 10.4.2 | MIT | 正文已读：`LICENSE` |
| `@testing-library/jest-dom` | 7.0.1 | MIT | 正文已读：`LICENSE` |
| `dom-accessibility-api` | 0.6.3 | MIT | 正文已读：`LICENSE.md` |
| `@testing-library/react` | 16.3.3 | MIT | 正文已读：`LICENSE` |
| `@types/aria-query` | 5.0.4 | MIT | 正文已读：`LICENSE` |
| `@types/chai` | 5.2.3 | MIT | 正文已读：`LICENSE` |
| `@types/d3-array` | 3.2.2 | MIT | 正文已读：`LICENSE` |
| `@types/d3-color` | 3.1.3 | MIT | 正文已读：`LICENSE` |
| `@types/d3-ease` | 3.0.2 | MIT | 正文已读：`LICENSE` |
| `@types/d3-interpolate` | 3.0.4 | MIT | 正文已读：`LICENSE` |
| `@types/d3-path` | 3.1.1 | MIT | 正文已读：`LICENSE` |
| `@types/d3-scale` | 4.0.9 | MIT | 正文已读：`LICENSE` |
| `@types/d3-shape` | 3.2.0 | MIT | 正文已读：`LICENSE` |
| `@types/d3-time` | 3.0.4 | MIT | 正文已读：`LICENSE` |
| `@types/d3-timer` | 3.0.2 | MIT | 正文已读：`LICENSE` |
| `@types/deep-eql` | 4.0.2 | MIT | 正文已读：`LICENSE` |
| `@types/estree` | 1.0.9 | MIT | 正文已读：`LICENSE` |
| `@types/node` | 22.20.5 | MIT | 正文已读：`LICENSE` |
| `@types/react` | 19.3.0 | MIT | 正文已读：`LICENSE` |
| `@types/react-dom` | 19.3.0 | MIT | 正文已读：`LICENSE` |
| `@types/use-sync-external-store` | 0.0.6 | MIT | 正文已读：`LICENSE` |
| `@typescript/typescript-aix-ppc64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-darwin-arm64` | 7.0.2 | Apache-2.0 | 正文已读：`LICENSE`, `NOTICE.txt` |
| `@typescript/typescript-darwin-x64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-freebsd-arm64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-freebsd-x64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-linux-arm` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-linux-arm64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-linux-loong64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-linux-mips64el` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-linux-ppc64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-linux-riscv64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-linux-s390x` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-linux-x64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-netbsd-arm64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-netbsd-x64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-openbsd-arm64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-openbsd-x64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-sunos-x64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-win32-arm64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@typescript/typescript-win32-x64` | 7.0.2 | Apache-2.0 | 待核验（本地无许可正文） |
| `@vitejs/plugin-react` | 6.1.2 | MIT | 正文已读：`LICENSE` |
| `@vitest/mocker` | 5.0.5 | MIT | 正文已读：`LICENSE` |
| `@vitest/spy` | 5.0.5 | MIT | 正文已读：`LICENSE` |
| `ansi-regex` | 5.0.1 | MIT | 正文已读：`license` |
| `ansi-styles` | 5.2.0 | MIT | 正文已读：`license` |
| `aria-query` | 5.3.0 | Apache-2.0 | 正文已读：`LICENSE` |
| `assertion-error` | 2.0.1 | MIT | 正文已读：`LICENSE` |
| `bidi-js` | 1.1.0 | MIT | 正文已读：`LICENSE.txt` |
| `chai` | 6.3.0 | MIT | 正文已读：`LICENSE` |
| `clsx` | 2.1.1 | MIT | 正文已读：`license` |
| `cookie-es` | 3.1.1 | MIT | 正文已读：`LICENSE` |
| `css-tree` | 3.2.1 | MIT | 正文已读：`LICENSE` |
| `css.escape` | 1.5.1 | MIT | 正文已读：`LICENSE-MIT.txt` |
| `csstype` | 3.2.3 | MIT | 正文已读：`LICENSE` |
| `d3-array` | 3.2.4 | ISC | 正文已读：`LICENSE` |
| `d3-color` | 3.1.0 | ISC | 正文已读：`LICENSE` |
| `d3-ease` | 3.0.1 | BSD-3-Clause | 正文已读：`LICENSE` |
| `d3-format` | 3.1.2 | ISC | 正文已读：`LICENSE` |
| `d3-interpolate` | 3.0.1 | ISC | 正文已读：`LICENSE` |
| `d3-path` | 3.1.0 | ISC | 正文已读：`LICENSE` |
| `d3-scale` | 4.0.2 | ISC | 正文已读：`LICENSE` |
| `d3-shape` | 3.2.0 | ISC | 正文已读：`LICENSE` |
| `d3-time` | 3.1.0 | ISC | 正文已读：`LICENSE` |
| `d3-time-format` | 4.1.0 | ISC | 正文已读：`LICENSE` |
| `d3-timer` | 3.0.1 | ISC | 正文已读：`LICENSE` |
| `data-urls` | 8.0.0 | MIT | 正文已读：`LICENSE.txt` |
| `decimal.js` | 10.6.0 | MIT | 待核验（本地无许可正文） |
| `decimal.js-light` | 2.5.1 | MIT | 待核验（本地无许可正文） |
| `dequal` | 2.0.3 | MIT | 正文已读：`license` |
| `detect-libc` | 2.1.2 | Apache-2.0 | 正文已读：`LICENSE` |
| `detect-node-es` | 1.1.0 | MIT | 正文已读：`LICENSE` |
| `dom-accessibility-api` | 0.5.16 | MIT | 正文已读：`LICENSE.md` |
| `dom-helpers` | 5.2.1 | MIT | 正文已读：`LICENSE` |
| `entities` | 8.1.0 | BSD-2-Clause | 正文已读：`LICENSE` |
| `es-module-lexer` | 2.3.2 | MIT | 正文已读：`LICENSE` |
| `es-toolkit` | 1.53.1 | MIT | 正文已读：`LICENSE`, `NOTICE` |
| `estree-walker` | 3.0.3 | MIT | 正文已读：`LICENSE` |
| `eventemitter3` | 5.0.4 | MIT | 正文已读：`LICENSE` |
| `expect-type` | 1.4.0 | Apache-2.0 | 正文已读：`LICENSE` |
| `fast-deep-equal` | 3.1.3 | MIT | 正文已读：`LICENSE` |
| `fdir` | 6.5.0 | MIT | 正文已读：`LICENSE` |
| `fsevents` | 2.3.3 | MIT | 正文已读：`LICENSE` |
| `get-nonce` | 1.0.1 | MIT | 正文已读：`LICENSE` |
| `html-encoding-sniffer` | 7.0.0 | MIT | 正文已读：`LICENSE.txt` |
| `immer` | 10.2.0 | MIT | 正文已读：`LICENSE` |
| `indent-string` | 4.0.0 | MIT | 正文已读：`license` |
| `internmap` | 2.0.3 | ISC | 正文已读：`LICENSE` |
| `is-potential-custom-element-name` | 1.0.1 | MIT | 正文已读：`LICENSE-MIT.txt` |
| `js-tokens` | 4.0.0 | MIT | 正文已读：`LICENSE` |
| `jsdom` | 30.1.3 | MIT | 正文已读：`LICENSE.txt` |
| `klona` | 2.0.6 | MIT | 正文已读：`license` |
| `lightningcss` | 1.33.0 | MPL-2.0 | 正文已读：`LICENSE` |
| `lightningcss-android-arm64` | 1.33.0 | MPL-2.0 | 待核验（本地无许可正文） |
| `lightningcss-darwin-arm64` | 1.33.0 | MPL-2.0 | 正文已读：`LICENSE` |
| `lightningcss-darwin-x64` | 1.33.0 | MPL-2.0 | 待核验（本地无许可正文） |
| `lightningcss-freebsd-x64` | 1.33.0 | MPL-2.0 | 待核验（本地无许可正文） |
| `lightningcss-linux-arm-gnueabihf` | 1.33.0 | MPL-2.0 | 待核验（本地无许可正文） |
| `lightningcss-linux-arm64-gnu` | 1.33.0 | MPL-2.0 | 待核验（本地无许可正文） |
| `lightningcss-linux-arm64-musl` | 1.33.0 | MPL-2.0 | 待核验（本地无许可正文） |
| `lightningcss-linux-x64-gnu` | 1.33.0 | MPL-2.0 | 待核验（本地无许可正文） |
| `lightningcss-linux-x64-musl` | 1.33.0 | MPL-2.0 | 待核验（本地无许可正文） |
| `lightningcss-win32-arm64-msvc` | 1.33.0 | MPL-2.0 | 待核验（本地无许可正文） |
| `lightningcss-win32-x64-msvc` | 1.33.0 | MPL-2.0 | 待核验（本地无许可正文） |
| `loose-envify` | 1.4.0 | MIT | 正文已读：`LICENSE` |
| `lru-cache` | 11.5.3 | BlueOak-1.0.0 | 正文已读：`LICENSE.md` |
| `lz-string` | 1.5.0 | MIT | 正文已读：`LICENSE` |
| `magic-string` | 1.4.3 | MIT | 正文已读：`LICENSE` |
| `mdn-data` | 2.27.1 | CC0-1.0 | 正文已读：`LICENSE` |
| `min-indent` | 1.0.1 | MIT | 正文已读：`license` |
| `nanoid` | 3.3.20 | MIT | 正文已读：`LICENSE` |
| `object-assign` | 4.1.1 | MIT | 正文已读：`license` |
| `obug` | 3.0.0 | MIT | 正文已读：`LICENSE` |
| `oxlint` | 1.89.0 | MIT | 正文已读：`LICENSE` |
| `parse5` | 8.0.1 | MIT | 正文已读：`LICENSE` |
| `picocolors` | 1.1.1 | ISC | 正文已读：`LICENSE` |
| `picomatch` | 4.0.7 | MIT | 正文已读：`LICENSE` |
| `playwright` | 1.64.1 | Apache-2.0 | 正文已读：`LICENSE`, `NOTICE` |
| `playwright-core` | 1.64.1 | Apache-2.0 | 正文已读：`LICENSE`, `NOTICE` |
| `postcss` | 8.5.31 | MIT | 正文已读：`LICENSE` |
| `prettier` | 3.9.10 | MIT | 正文已读：`LICENSE` |
| `pretty-format` | 27.5.1 | MIT | 正文已读：`LICENSE` |
| `prop-types` | 15.8.1 | MIT | 正文已读：`LICENSE` |
| `react-is` | 16.13.1 | MIT | 正文已读：`LICENSE` |
| `punycode` | 2.3.1 | MIT | 正文已读：`LICENSE-MIT.txt` |
| `react` | 19.3.1 | MIT | 正文已读：`LICENSE` |
| `react-dom` | 19.3.1 | MIT | 正文已读：`LICENSE` |
| `react-is` | 17.0.2 | MIT | 正文已读：`LICENSE` |
| `react-number-format` | 5.4.5 | MIT | 正文已读：`LICENSE` |
| `react-redux` | 9.3.1 | MIT | 正文已读：`LICENSE.md` |
| `react-remove-scroll` | 2.7.2 | MIT | 正文已读：`LICENSE` |
| `react-remove-scroll-bar` | 2.3.8 | MIT | 正文已读：`react-remove-scroll-bar/LICENSE` |
| `react-router` | 8.5.0 | MIT | 正文已读：`LICENSE.md` |
| `react-style-singleton` | 2.2.3 | MIT | 正文已读：`LICENSE` |
| `react-transition-group` | 4.4.5 | BSD-3-Clause | 正文已读：`LICENSE` |
| `recharts` | 3.9.0 | MIT | 正文已读：`LICENSE` |
| `redent` | 3.0.0 | MIT | 正文已读：`license` |
| `redux` | 5.0.1 | MIT | 正文已读：`LICENSE.md` |
| `redux-thunk` | 3.1.0 | MIT | 正文已读：`LICENSE.md` |
| `require-from-string` | 2.0.2 | MIT | 正文已读：`license` |
| `reselect` | 5.2.0 | MIT | 正文已读：`LICENSE` |
| `rolldown` | 1.2.15 | MIT | 正文已读：`LICENSE` |
| `saxes` | 6.0.0 | ISC | 待核验（本地无许可正文） |
| `scheduler` | 0.28.0 | MIT | 正文已读：`LICENSE` |
| `source-map-js` | 1.2.2 | BSD-3-Clause | 正文已读：`LICENSE` |
| `std-env` | 4.3.0 | MIT | 待核验（本地无许可正文） |
| `strip-indent` | 3.0.0 | MIT | 正文已读：`license` |
| `tabbable` | 6.5.0 | MIT | 正文已读：`LICENSE` |
| `tagged-tag` | 1.0.0 | MIT | 正文已读：`license` |
| `tiny-invariant` | 1.3.3 | MIT | 正文已读：`LICENSE` |
| `tinybench` | 6.2.2 | MIT | 正文已读：`LICENSE` |
| `tinyexec` | 1.3.1 | MIT | 正文已读：`LICENSE` |
| `tinyglobby` | 0.2.17 | MIT | 正文已读：`LICENSE` |
| `tldts` | 7.4.19 | MIT | 正文已读：`LICENSE` |
| `tldts-core` | 7.4.19 | MIT | 正文已读：`LICENSE` |
| `tough-cookie` | 6.0.2 | BSD-3-Clause | 正文已读：`LICENSE` |
| `tr46` | 7.0.0 | MIT | 正文已读：`LICENSE.md` |
| `tslib` | 2.8.1 | 0BSD | 正文已读：`LICENSE.txt` |
| `type-fest` | 5.10.0 | (MIT OR CC0-1.0) | 正文已读：`license-cc0`, `license-mit` |
| `typescript` | 7.0.2 | Apache-2.0 | 正文已读：`LICENSE`, `NOTICE.txt`, `vendor/vscode-jsonrpc/License.txt` |
| `undici` | 8.12.3 | MIT | 正文已读：`LICENSE`, `lib/web/fetch/LICENSE`, `lib/milo/LICENSE.md` |
| `undici-types` | 6.21.0 | MIT | 正文已读：`LICENSE` |
| `use-callback-ref` | 1.3.3 | MIT | 正文已读：`LICENSE` |
| `use-sidecar` | 1.1.3 | MIT | 正文已读：`LICENSE` |
| `use-sync-external-store` | 1.7.0 | MIT | 正文已读：`LICENSE` |
| `victory-vendor` | 37.4.1 | MIT AND ISC AND BSD-3-Clause | 正文已读：`LICENSE.txt`, `lib-vendor/d3-format/LICENSE`, `lib-vendor/d3-shape/LICENSE`, `lib-vendor/d3-array/LICENSE`, `lib-vendor/d3-scale/LICENSE`, `lib-vendor/d3-color/LICENSE`, `lib-vendor/d3-timer/LICENSE`, `lib-vendor/d3-time-format/LICENSE`, `lib-vendor/d3-interpolate/LICENSE`, `lib-vendor/d3-time/LICENSE`, `lib-vendor/d3-path/LICENSE`, `lib-vendor/d3-voronoi/LICENSE`, `lib-vendor/d3-ease/LICENSE`, `lib-vendor/internmap/LICENSE` |
| `vite` | 8.3.5 | MIT | 正文已读：`LICENSE.md` |
| `vitest` | 5.0.5 | MIT | 正文已读：`LICENSE.md` |
| `w3c-xmlserializer` | 6.0.0 | MIT | 正文已读：`LICENSE.md` |
| `webidl-conversions` | 8.0.1 | BSD-2-Clause | 正文已读：`LICENSE.md` |
| `whatwg-mimetype` | 5.0.0 | MIT | 正文已读：`LICENSE.txt` |
| `whatwg-url` | 17.3.0 | MIT | 正文已读：`LICENSE.txt` |
| `why-is-node-running` | 3.2.1 | MIT | 正文已读：`LICENSE` |
| `xml-name-validator` | 5.0.0 | Apache-2.0 | 正文已读：`LICENSE.txt` |
| `xmlchars` | 2.2.0 | MIT | 正文已读：`LICENSE` |
| `zod` | 4.6.7 | MIT | 正文已读：`LICENSE` |

## Swift 锁定依赖

本 worktree 无 `.build/checkouts`，Package.resolved 未提供许可字段；以下全部待核验，不以组织或惯例猜测许可。发版前须读取锁定源码的 LICENSE/NOTICE/COPYING，特别核对 swift-crypto、swift-nio-ssl 及其嵌入加密库的多来源通知。

| 包 | 锁定版本 | 许可证 |
|---|---|---|
| `async-http-client` | 1.36.2 | 待核验（无本地 checkout） |
| `async-kit` | 1.22.0 | 待核验（无本地 checkout） |
| `console-kit` | 4.16.2 | 待核验（无本地 checkout） |
| `multipart-kit` | 4.7.1 | 待核验（无本地 checkout） |
| `routing-kit` | 4.9.3 | 待核验（无本地 checkout） |
| `swift-algorithms` | 1.2.1 | 待核验（无本地 checkout） |
| `swift-asn1` | 1.7.3 | 待核验（无本地 checkout） |
| `swift-async-algorithms` | 1.1.7 | 待核验（无本地 checkout） |
| `swift-atomics` | 1.3.1 | 待核验（无本地 checkout） |
| `swift-certificates` | 1.21.0 | 待核验（无本地 checkout） |
| `swift-collections` | 1.7.3 | 待核验（无本地 checkout） |
| `swift-configuration` | 1.3.0 | 待核验（无本地 checkout） |
| `swift-crypto` | 4.5.2 | 待核验（无本地 checkout） |
| `swift-distributed-tracing` | 1.7.2 | 待核验（无本地 checkout） |
| `swift-http-structured-headers` | 1.7.0 | 待核验（无本地 checkout） |
| `swift-http-types` | 1.8.0 | 待核验（无本地 checkout） |
| `swift-log` | 1.16.1 | 待核验（无本地 checkout） |
| `swift-metrics` | 2.12.0 | 待核验（无本地 checkout） |
| `swift-nio` | 2.104.0 | 待核验（无本地 checkout） |
| `swift-nio-extras` | 1.35.1 | 待核验（无本地 checkout） |
| `swift-nio-http2` | 1.46.0 | 待核验（无本地 checkout） |
| `swift-nio-ssl` | 2.37.5 | 待核验（无本地 checkout） |
| `swift-nio-transport-services` | 1.28.0 | 待核验（无本地 checkout） |
| `swift-numerics` | 1.1.1 | 待核验（无本地 checkout） |
| `swift-service-context` | 1.5.1 | 待核验（无本地 checkout） |
| `swift-service-lifecycle` | 2.13.0 | 待核验（无本地 checkout） |
| `swift-system` | 1.8.1 | 待核验（无本地 checkout） |
| `vapor` | 4.122.2 | 待核验（无本地 checkout） |
| `websocket-kit` | 2.16.2 | 待核验（无本地 checkout） |

## 相关文档

[项目许可](LICENSE) · [来源声明](docs/reference/provenance.md) · [npm 补充许可](web/licenses/README.md)
