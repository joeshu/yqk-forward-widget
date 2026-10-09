# 部署一起看 ForwardWidget 0.5.0

## 当前仓库的直接订阅

上传至 `joeshu/yqk-forward-widget` 后，可以直接使用 GitHub Raw，无需开启 Pages：

https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/yqk.fwd

它引用同仓库的 yqk-0.5.0.js。发布新版时先上传新的版本化脚本，再更新根目录订阅；保留旧版本文件。以下 Pages 流程是可选项，只有工作流部署成功后 Pages 地址才可用。

## 先理解部署内容

这是静态订阅，不是需要在服务器上长期运行的 Node 应用。
服务器提供 `.fwd`（JSON 订阅目录）和 `.js`（组件程序）的 HTTPS 直链；程序下载后在手机应用内运行，再由手机直接请求一起看 API 和视频资源。
服务端不需要安装 npm 依赖、不需要运行 `yqk.js`、不需要代理视频，也不需要放置账号凭据。
部署静态文件不会解决手机网络无法访问源站、源站下架、权限限制或某条第三方线路失效的问题。

## 1. 根据自己的真实域名生成发布目录

解压完整包，在 `yqk-widget` 目录执行（本地需要 Node >=24；此步骤不需要 npm install）：

```bash
node deploy.cjs https://你的项目.vercel.app publish
```

请把示例域名替换成你已确定的服务域名。工具不会创建服务或占用这个域名。
输出目录须不存在或为空；工具不会覆盖已有发布目录。更新时可以改用 `publish-0.5.0` 等新目录。

工具自动生成：

| 文件 | 用途 |
| --- | --- |
| yqk.fwd | 应用内添加的订阅，JS 地址与版本自动同步 |
| yqk-0.5.0.js | 版本化脚本，降低新旧缓存混用风险 |
| vercel.json | Vercel 静态托管与响应头配置 |
| _headers | Cloudflare Pages 的响应头配置 |
| release.json | 发布版本及 JS SHA-256，用于人工核对 |

如果想使用 `/Resource/Yqk/` 目录：

```bash
node deploy.cjs https://你的域名/Resource/Yqk publish
```

输出会包含对应子目录。上传整个 `publish` 的内容到站点根目录，不要再套一层 `publish`，也不要重复增加 `Resource/Yqk`。

## 2A. GitHub Pages（直接从 GitHub 发布订阅）

GitHub 存放源码，GitHub Pages 提供 HTTPS 静态直链。公开仓库在 GitHub Free 下可使用 Pages；私有仓库可用性取决于 GitHub 计划。

1. 当前目标仓库为 `joeshu/yqk-forward-widget`；迁移时选定自己的仓库。
2. 把解压后 `yqk-widget` 内的项目文件放到仓库根目录，包含 `.github/workflows/pages.yml`。不要只上传 ZIP，也不要在仓库根目录再套一层 `yqk-widget`。Web 上传可能忽略隐藏目录，需确认该工作流文件确实存在。
3. 默认分支使用 main；其他名称需要修改工作流的 branches。
4. 仓库 Settings → Pages → Build and deployment → Source 选择 GitHub Actions。
5. 提交到 main 后自动运行；若文件先上传后才开启 Pages，可在 Actions 中选择 Test and publish widget subscription → Run workflow。
6. 等待 build 和 deploy 两个 job 成功，打开 Settings → Pages 给出的实际站点地址。

工作流先安装锁定依赖并运行本地回归，再使用 GitHub 提供的实际 Pages URL 生成订阅，最后只上传发布目录。
它不会在每次 CI 中请求一起看生产 API 或下载视频，不需要你配置额外的访问令牌。

若采用建议的仓库名，部署成功后的默认地址是：

```text
https://joeshu.github.io/yqk-forward-widget/yqk.fwd
https://joeshu.github.io/yqk-forward-widget/yqk-0.5.0.js
```

上面是预期地址，未部署前不是可用链接。如果账号、仓库名或自定义域名不同，以 Pages 显示的实际地址为准。

手动生成 Pages 目录时：

```bash
node deploy.cjs https://joeshu.github.io/yqk-forward-widget publish --pages
```

Pages 的上传目录已挂载在 `/仓库名/` 下，`--pages` 会把 yqk.fwd 和 JS 放在发布目录根部，避免重复生成 `/仓库名/仓库名/`。
不要为 Pages 使用不带 `--pages` 的生成方式。

GitHub Pages 不应用 Vercel 的 vercel.json 或 Cloudflare 的 _headers；该模式不会生成这两个文件。
`.fwd` 的 Content-Type 由 GitHub 决定，可能不是 application/json，验收时应核对真实 JSON 内容、JS 地址及客户端实际导入。
将生产 `.fwd` URL 添加到应用订阅入口。不是 GitHub 的 `blob/main/...` 文件浏览页。
源码提交会触发重发；修改 WidgetMetadata.version 后自动引用新的版本化 JS。
每次 Pages 上传替换整个站点，如需保留旧版本 JS，应额外保留对应文件到发布目录；旧客户端更新订阅前可能仍引用旧文件。

本地已验证发布文件布局及仓库前缀；尚未在你账号下远程运行该工作流或验证 Pages 下载。

## 2B. Vercel 部署（适合已有 Vercel 账号）

1. 确定项目的生产域名，例如你项目设置中显示的 `xxx.vercel.app`。不要将会改变的预览部署域名写进订阅。
2. 执行上面的生成命令，进入输出目录。
3. 使用 Vercel 官方 CLI：

```bash
npm install -g vercel
cd publish
vercel login
vercel --prod
```

首次发布按提示关联或创建你自己的项目。若项目名尚未确定，先创建项目并取得域名，再生成发布目录。
项目框架使用 Other/无框架；不添加构建命令，不把本包的测试 package.json 当作发布项目。
生成目录中的 `vercel.json` 指定静态输出根目录与两个文件的 Content-Type。
部署后确认生产 URL 与生成时填入的域名一致；不一致则重新生成并发布。

订阅和 JS 必须允许应用匿名访问，不能返回 Vercel 登录页、密码页或其他部署保护页面。
本说明不要求关闭整个账号的安全设置；只应将你打算公开的这份静态订阅部署设为可匿名读取。

## 2C. Cloudflare Pages（可选）

官方 Direct Upload 支持上传目录或 ZIP。创建 Pages 项目并确定生产域名后，重新以该域名生成发布目录，将目录内容上传发布。
使用生产地址 `https://项目.pages.dev/yqk.fwd`，而不是临时预览域名。
`_headers` 用于配置原始文件响应头；不需要 Worker、Functions 或框架构建。
Direct Upload 与 Git 集成的项目模式有差异，选择前请查官方说明，不要假设两者可直接切换。

## 2D. 自有服务器（Nginx）

已有 HTTPS 站点时，将生成目录中的文件内容上传到该站点的静态根目录。
发布文件放在域名对应的目录，而不是 Node 后台。使用你已有的证书、域名和运维流程。

在现有 server 中按实际路径配置（此例是根目录发布）：

```nginx
location = /yqk.fwd {
    types { }
    default_type application/json;
    charset utf-8;
    add_header Cache-Control "public, max-age=60, must-revalidate";
    add_header Access-Control-Allow-Origin "*";
    add_header X-Content-Type-Options nosniff;
    try_files $uri =404;
}

location = /yqk-0.5.0.js {
    types { }
    default_type application/javascript;
    charset utf-8;
    add_header Cache-Control "public, max-age=60, must-revalidate";
    add_header Access-Control-Allow-Origin "*";
    add_header X-Content-Type-Options nosniff;
    try_files $uri =404;
}
```

`root` 继续使用你的现有静态根目录；子目录发布时需相应修改这两个 location。
更改后先检查配置再按你的运维流程 reload。不要把未知 URL 重写为 index.html，否则不存在的脚本也可能返回 HTTP 200 的网页。

## 3. 部署验收与导入

```bash
curl -f -i https://你的域名/yqk.fwd
curl -f -i https://你的域名/yqk-0.5.0.js
```

验收要点：

- 两个地址实际 HTTP 200，无登录、验证码、反爬或跳转到网页的页面。
- `.fwd` 内容是 JSON，widgets[0].url 指向可以下载的原始 JS。
- 可配置响应头的平台上 `.fwd` Content-Type 使用 application/json，JS 使用 application/javascript。GitHub Pages MIME 类型由平台决定，以真实文件内容和客户端导入结果验收。
- JS 中 `WidgetMetadata.version` 和订阅版本均为 0.5.0。
- 可通过 release.json 中的 SHA-256 核对 JS 字节；UTF-8 文件不要被服务器转换或压缩混淆后手工改写。
- 确认手机网络也能访问，不仅是电脑或服务器可访问。

在 Forward/Rex 的组件订阅入口添加 `.fwd` HTTPS 地址，更新订阅后先搜索“流浪地球”，进入“流浪地球2”的默认线路对应分集测试。
再验证分类分页、电视剧分集和其他线路。客户端入口名称可能随版本不同；本包未做原生 iPhone UI 验收。

## 4. 更新与回滚

以后更新脚本时，确保 WidgetMetadata.version 增加，重新运行发布工具。
先上传新版本 JS，验证可读取，再替换稳定地址的 yqk.fwd，最后在应用内刷新订阅。
不要删除仍可能被旧订阅引用的版本化 JS。回滚时恢复上一版 `.fwd` 及其对应 JS。
客户端自身也可能缓存订阅，因此服务器缓存过期后仍需在应用内主动更新。

## 常见问题

- 订阅下载成功但没有模块：检查是否把 GitHub 文件浏览页/网站 HTML 当成 JS 直链，或 `.fwd` 仍指向 example.invalid。
- 网页可以看，应用请求失败：排查手机代理/DNS、API 域名连通性以及客户端版本，不是静态服务没运行 Node。
- 只有某条播放线路失败：源站线路问题，切换其他线路；不会绕过登录或会员权限。
- 旧版本一直不变：同时检查订阅版本、WidgetMetadata.version、版本化文件名、CDN 和客户端缓存。

## 官方资料

- https://github.com/InchStudio/ForwardWidgets
- https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages
- https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages
- https://vercel.com/docs/project-configuration/vercel-json
- https://vercel.com/docs/cli/deploy
- https://developers.cloudflare.com/pages/get-started/direct-upload/
- https://developers.cloudflare.com/pages/configuration/headers/

Raw 订阅由仓库公开文件提供；Pages 是否上线，以 Actions 部署结果和实际地址的 HTTP 响应为准。
