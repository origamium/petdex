<div align="center">

<img src="public/brand/petdex-desktop-icon.png" alt="Petdex" width="120" />

<h1>Petdex</h1>

<p>
  Codex 向けアニメーションコンパニオンの公開ギャラリー。
  <br />
  ペットの閲覧・インストール・投稿がコマンドひとつで。
</p>

<p>
  <a href="https://petdex.dev"><strong>petdex.dev</strong></a>
  &nbsp;·&nbsp;
  <a href="https://petdex.dev/built-with">Built with Petdex</a>
  &nbsp;·&nbsp;
  <a href="https://discord.gg/byhubdyBTe">Discord</a>
  &nbsp;·&nbsp;
  <a href="https://www.npmjs.com/package/petdex">npm</a>
</p>

<p>
  <a href="https://www.npmjs.com/package/petdex"><img src="https://img.shields.io/npm/v/petdex?style=flat-square&label=cli&color=000000" alt="npm version" /></a>
  <a href="https://github.com/crafter-station/petdex/stargazers"><img src="https://img.shields.io/github/stars/crafter-station/petdex?style=flat-square&color=000000" alt="GitHub stars" /></a>
  <a href="https://github.com/crafter-station/petdex/blob/main/LICENSE"><img src="https://img.shields.io/github/license/crafter-station/petdex?style=flat-square&color=000000" alt="MIT license" /></a>
  <a href="https://github.com/crafter-station/petdex/issues"><img src="https://img.shields.io/github/issues/crafter-station/petdex?style=flat-square&color=000000" alt="GitHub issues" /></a>
</p>

</div>

[English](./README.md) | 日本語

---

## Petdex とは

Petdex は、連携して動く 3 つの要素でできている。

1. **Web ギャラリー** — [petdex.dev](https://petdex.dev)。コミュニティが Codex スプライト形式のアニメーションペットを投稿・レビュー・公開する場所。
2. **CLI** — どのペットもコマンドひとつで手元のマシンにインストールし、そのまま Codex に届ける。
3. **デスクトップアプリ** — 画面上にペットを浮かべ、コーディングエージェントの動きにリアルタイムで反応させる。

ペットはひとつのフォルダ。フォルダはひとつの図鑑エントリ。どのエントリも `npx petdex install` ひとつで手に入る。

## クイックスタート

以下の手順で、ペットをインストールし、Codex に表示させ、デスクトップアプリに接続する。

1. 既存のペットをインストールする:

```sh
npx petdex install boba
```

`~/.petdex/pets/boba/` に `pet.json` とスプライトシートが入っていれば OK。

2. [petdex.dev/download](https://petdex.dev/download) からデスクトップアプリを入手する。
   macOS、Linux、Windows に対応。

3. アプリを開き、ペットの上で <kbd>Cmd</kbd>+<kbd>,</kbd> を押して設定を開く。
   **Pets** でペットを選び、**Agents** でコーディングエージェントをそれぞれワンクリックで接続する。
   ターミナル操作は不要。

ペットは作業画面の上に浮かび、エージェントがツールを呼び出すたびにアニメーションする。

## ユーザー向け

| やりたいこと | 方法 |
| --- | --- |
| ペットを探す | [petdex.dev](https://petdex.dev) を開く |
| ペットをインストールする | `npx petdex install <slug>` |
| 表示中のマスコットを切り替える | デスクトップアプリの設定を開く(<kbd>Cmd</kbd>+<kbd>,</kbd>) |
| デスクトップのフローターを動かす | [petdex.dev/download](https://petdex.dev/download) からダウンロード |
| ペットを作る | Codex 内で `hatch-pet` スキルを使うか、[Petdex クリエイターツール](https://petdex.dev/create)で作る |
| ペットを投稿する | `npx petdex submit ./my-pet/`、または Web の投稿フォームから |
| コミュニティに参加する | [Discord](https://discord.gg/byhubdyBTe) |

CLI の完全なリファレンス: [`packages/petdex-cli/README.md`](./packages/petdex-cli/README.md)

## 開発者向け

Petdex の上に何かを作りたい場合(デスクトップクライアント、ウェアラブル、SDK、Discord ボットなど何でも)、安定したインターフェースが 2 つある。

- **HTTP API** — `petdex.dev/api/manifest` が、承認済みの全ペットについて slug、スプライトシート URL、アニメーション状態、メタデータを返す。
- **ペットパッケージ形式** — どのペットも `pet.json` と `spritesheet.{webp,png}` の組み合わせ。スプライトシートは 192x208 フレームの 8x9 グリッド、または v2 の 8x11 グリッド。

これらを使ったオープンソース/ソース公開プロジェクトはすでに 21 個ある。一覧は [petdex.dev/built-with](https://petdex.dev/built-with) を参照。自分のプロジェクトは [issue テンプレート](https://github.com/crafter-station/petdex/issues/new?template=built-with.yml)から登録できる。

## アーキテクチャ

```text
crafter-station/petdex
├── src/
│   ├── app/[locale]/          公開サイト: ギャラリー、/pets/<slug>、/collections、/built-with、/community、/create、/download、/submit、/u/<handle> など
│   ├── app/api/cli/           CLI 用エンドポイント: OAuth 設定、投稿(zip → R2 署名付き URL)、重複チェック、登録
│   ├── app/api/manifest/      公開マニフェスト: 承認済み全ペットとスプライトシート URL
│   ├── app/api/admin/         管理者向けレビュー画面(投稿、編集、コレクション申請)
│   └── lib/db/schema.ts       Drizzle スキーマ(Postgres)
├── packages/
│   ├── petdex-cli/            npm の `petdex` カタログクライアント(auth、list、install、submit)
│   ├── petdex-desktop-native/ macOS / Linux / Windows 向けネイティブ SDK 製のフローティングマスコット
│   ├── petdex-desktop-windows/ 旧 Tauri 製 Windows 実装(リリース経路ではない)
│   └── discord-bot/           Petdex サーバー用 Discord.js ボット
├── public/built-with/         コミュニティページ用スクリーンショット
├── public/brand/              ロゴ、OS アイコン、Discord アイコン
└── drizzle/                   SQL マイグレーション(Postgres スキーマ履歴)
```

**Web**: Next.js 16、React 19、Tailwind、Drizzle、Postgres、Redis、Clerk、R2<br />
**CLI**: Bun + TypeScript。単一の npm バイナリとして配布。認証は Clerk OAuth + PKCE<br />
**デスクトップ**: ネイティブ SDK アプリ。`127.0.0.1:7777` でプロセス内の Zig 製フックサーバーが動く。現行のリリース経路には WebView も Node サイドカーもない

## ローカル開発

2 通りの方法がある。

| 目的 | コマンド | 準備 |
| --- | --- | --- |
| ローカルでフルスタックを動かす | `bun run dev:docker` | Docker または Podman。起動に約 30 秒 |
| 本番サービスに接続して動かす | `bun run dev` | `.env.local` の設定が必要(メンテナのみ) |

```sh
git clone https://github.com/crafter-station/petdex.git
cd petdex
bun install
bun run dev:docker
```

[localhost:3000](http://localhost:3000) を開く。詳しくは [`CONTRIBUTING.md`](./CONTRIBUTING.md) を参照。

## ペットパッケージ形式

ペットは 2 つのファイルでできている。

```text
my-pet/
├── pet.json                メタデータ: 名前、slug、タグ、vibes、種類、フレームサイズ、アニメーション状態
└── spritesheet.webp        192x208 px フレームの 8x9 グリッド、または v2 の 8x11 グリッド(.png も可)
```

ネイティブレンダラーは 9 つの状態行に対応している: `idle`、`running-right`、`running-left`、`waving`、`jumping`、`failed`、`waiting`、`running`、`review`。Codex と対応コーディングエージェントは、それぞれのアクティビティフックをこれらの状態に対応づける。v2 の 8x11 アトラスには、利用側クライアントが自由に使える行が 2 つ追加されている。

## コントリビュート

- **ペットを投稿する:** [petdex.dev/submit](https://petdex.dev/submit) または `npx petdex submit <path>`
- **プロジェクトを掲載する:** [Built with Petdex の issue](https://github.com/crafter-station/petdex/issues/new?template=built-with.yml) を作成
- **バグ修正・機能追加:** [`CONTRIBUTING.md`](./CONTRIBUTING.md) を読んでから PR を作成
- **交流する:** [Discord](https://discord.gg/byhubdyBTe) には、制作共有(`#wip`、`#ship-or-sink`)、フィードバック(`#cli-feedback`)、作品紹介(`#showcase`)のチャンネルがある

## ペットの権利と削除申請

ペットはユーザーが投稿したファンアート。Petdex は元となる IP について一切の権利を主張しない。キャラクターの権利者でペットの削除を希望する場合は、[削除申請](https://github.com/crafter-station/petdex/issues/new?template=takedown.yml)を提出してほしい。48 時間以内にレビューする。

## ライセンス

ソースコードは [MIT](./LICENSE)。ペットのアセットは投稿者に帰属し、ライセンスは投稿者が宣言したものに従う。

---

<div align="center">

<a href="https://crafter.run">Crafter Station</a> 制作。
リード: <a href="https://x.com/RaillyHugo">@RaillyHugo</a>

</div>
