<div align="center">

<img src="public/brand/petdex-desktop-icon.png" alt="Petdex" width="120" />

<h1>Petdex</h1>

<p>
  コーディングエージェントのためのアニメーションするデスクトップコンパニオン。
  <br />
  Claude Code、Codex、Cursor ほか計 19 種を見守り、話しかけにも応じるペット。
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
  <a href="https://github.com/origamium/petdex/stargazers"><img src="https://img.shields.io/github/stars/origamium/petdex?style=flat-square&color=000000" alt="GitHub stars" /></a>
  <a href="https://github.com/origamium/petdex/blob/main/LICENSE"><img src="https://img.shields.io/github/license/origamium/petdex?style=flat-square&color=000000" alt="MIT license" /></a>
  <a href="https://github.com/origamium/petdex/issues"><img src="https://img.shields.io/github/issues/origamium/petdex?style=flat-square&color=000000" alt="GitHub issues" /></a>
</p>

</div>

[English](./README.md) | 日本語

---

## Petdex とは

Petdex は、連携して動く 3 つの要素でできている。

1. **Web ギャラリー** — [petdex.dev](https://petdex.dev)。コミュニティが Codex スプライト形式のアニメーションペットを投稿・レビュー・公開する場所。
2. **CLI** — どのペットもコマンドひとつで手元のマシンにインストールし、そのまま Codex に届ける。
3. **デスクトップアプリ** — 画面上にペットを浮かべ、コーディングエージェントの動きにリアルタイムで反応させ、ペット自身の口調で話しかけてくる。

ペットはひとつのフォルダ。フォルダはひとつの図鑑エントリ。どのエントリも `npx petdex install` ひとつで手に入る。

> このリポジトリは [crafter-station/petdex](https://github.com/crafter-station/petdex) を大幅に拡張したフォーク。
> ギャラリー、CLI、ペット形式は上流と互換のまま。変更の大半はデスクトップアプリにあり、以下にまとめる。

## このフォークの違い

デスクトップアプリ(`packages/petdex-desktop-native`)は [Native SDK](https://github.com/vercel-labs/native) で作り直した。WebView も Node サイドカーもなく、浮かぶだけのマスコットから、エージェント作業のそばに置く小さな相棒へ育っている。

- **19 種のコーディングエージェントを 1 匹のペットに。** Claude Code、Codex、Gemini CLI、OpenCode、Cursor、Junie、Antigravity、Devin CLI、Grok Build、Copilot CLI、Windsurf / Devin Desktop、Amp、Droid、Qoder、Kimi Code、CodeBuddy、OMP、Hermes、DeepSeek Harness を、設定 → Connections から接続できる。フックやプラグインはホスト側の既存設定にマージされ(他のエントリは保持、隣にバックアップを作成)、Herdr のペインも反映される。対応表と上流側の制約は [`docs/agent-integration-support.md`](./docs/agent-integration-support.md) を参照。
- **エージェントバブル。** 会話ごとにエージェントのロゴ付きバブルがペットの上に浮かぶ。クリックでカードが開き、プロジェクト、状態、モデル、推論エフォート、直近のテキストを確認でき、Warp のペインや Terminal のタブへ飛べる。待機中のバブルは光り、完了したものにはチェックが付く。
- **ペットとチャット。** ペットをクリックして話しかける。接続先は ChatGPT、またはローカルの OpenAI 互換サーバー(LM Studio、Ollama)。人格は `pet.json`、任意の `persona.md`、`~/.petdex/personas/<slug>.md` から読み込む。履歴はローカルの SQLite に保存され、頼んだ事柄を少数だけ覚えてくれる。ダブルクリックでエージェントの状況報告が聞ける。
- **ペットから話しかける(任意)。** 数分おきの雑談と、エージェントが待っているときの声かけ。どちらも初期状態ではオフで、チャットを閉じている間や Focus Mode 中は黙っている。
- **タイマー。** チャット下に常駐するポモドーロとカウントダウン。完了はペットが自分の口調で知らせる。チャットからも操作できる(`25分タイマー始めて`、`timer start`)。
- **使用量の上限(macOS)。** 各エージェントの 5 時間枠と週枠がどれだけ使われ、いつリセットされるかをペットの横に表示する。ペット自身もこの数字を把握している。
- **MCP サーバー。** Node 20+ 用のサーバーを同梱(`petdex_set_state`、`petdex_show_bubble`、`petdex_report_usage`、`petdex_status`、`petdex_get_sessions`)。エージェント側の任意の操作と読み出しに使え、13 ホスト向けのインストーラーがある。
- **SSH 経由のリモートエージェント。** 別マシンのエージェントも、監視付きのリバーストンネル越しに同じペットを動かせる。[デスクトップ README](./packages/petdex-desktop-native/README.md#remote-agents-ssh) を参照。
- **言語と外観。** UI は英語と日本語。Auto / Light / Dark、ペットのサイズは 0.4〜2 倍、マルチディスプレイ対応の配置。

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
   **Pets** でペットを選び、**Connections** でコーディングエージェントをそれぞれワンクリックで接続する。
   ターミナル操作は不要。

ペットは作業画面の上に浮かび、エージェントがツールを呼び出すたびにアニメーションする。クリックすればチャットできる。

## ユーザー向け

| やりたいこと | 方法 |
| --- | --- |
| ペットを探す | [petdex.dev](https://petdex.dev) を開く |
| ペットをインストールする | `npx petdex install <slug>` |
| 表示中のマスコットを切り替える | デスクトップアプリの設定を開く(<kbd>Cmd</kbd>+<kbd>,</kbd>) |
| デスクトップのフローターを動かす | [petdex.dev/download](https://petdex.dev/download) からダウンロード |
| ペットとチャットする | ペットをクリック、または <kbd>Cmd</kbd>+<kbd>K</kbd> |
| コーディングエージェントを接続する | 設定 → Connections |
| ペットを作る | Codex 内で `hatch-pet` スキルを使うか、[Petdex クリエイターツール](https://petdex.dev/create)で作る |
| ペットを投稿する | `npx petdex submit ./my-pet/`、または Web の投稿フォームから |
| コミュニティに参加する | [Discord](https://discord.gg/byhubdyBTe) |

CLI の完全なリファレンス: [`packages/petdex-cli/README.md`](./packages/petdex-cli/README.md)
デスクトップの完全なリファレンス: [`packages/petdex-desktop-native/README.md`](./packages/petdex-desktop-native/README.md)

## 開発者向け

Petdex の上に何かを作りたい場合(デスクトップクライアント、ウェアラブル、SDK、Discord ボットなど何でも)、安定したインターフェースが 2 つある。

- **HTTP API** — `petdex.dev/api/manifest` が、承認済みの全ペットについて slug、スプライトシート URL、アニメーション状態、メタデータを返す。
- **ペットパッケージ形式** — どのペットも `pet.json` と `spritesheet.{webp,png}` の組み合わせ。スプライトシートは 192x208 フレームの 8x9 グリッド、または v2 の 8x11 グリッド。
- **ローカルのデスクトップ向けインターフェース** — デスクトップアプリは `127.0.0.1:7777` でトークン保護されたエージェントフックを受け付け、状態の設定、バブル表示、使用量報告、セッションカードの読み出しができる MCP サーバーも同梱する。詳細は [`docs/agent-integration-support.md`](./docs/agent-integration-support.md)。

これらを使ったオープンソース/ソース公開プロジェクトはすでに 21 個ある。一覧は [petdex.dev/built-with](https://petdex.dev/built-with) を参照。自分のプロジェクトは [issue テンプレート](https://github.com/origamium/petdex/issues/new?template=built-with.yml)から登録できる。

## アーキテクチャ

```text
petdex
├── src/
│   ├── app/[locale]/          公開サイト: ギャラリー、/pets/<slug>、/collections、/built-with、/community、/create、/download、/submit、/u/<handle> など
│   ├── app/api/cli/           CLI 用エンドポイント: OAuth 設定、投稿(zip → R2 署名付き URL)、重複チェック、登録
│   ├── app/api/manifest/      公開マニフェスト: 承認済み全ペットとスプライトシート URL
│   ├── app/api/admin/         管理者向けレビュー画面(投稿、編集、コレクション申請)
│   └── lib/db/schema.ts       Drizzle スキーマ(Postgres)
├── packages/
│   ├── petdex-cli/            npm の `petdex` カタログクライアント(auth、list、install、submit)
│   ├── petdex-desktop-native/ macOS / Linux / Windows 向けネイティブ SDK(Zig)製デスクトップペット: フック、チャット、タイマー、使用量、MCP、SSH リモート
│   └── discord-bot/           Petdex サーバー用 Discord.js ボット
├── docs/                      エージェント連携の対応表、検証メモ、ChatGPT ペット連携
├── public/built-with/         コミュニティページ用スクリーンショット
├── public/brand/              ロゴ、OS アイコン、Discord アイコン
└── drizzle/                   SQL マイグレーション(Postgres スキーマ履歴)
```

**Web**: Next.js 16、React 19、Tailwind、Drizzle、Postgres、Redis、Clerk、R2<br />
**CLI**: Bun + TypeScript。単一の npm バイナリとして配布。認証は Clerk OAuth + PKCE<br />
**デスクトップ**: ネイティブ SDK アプリ(Zig)。`127.0.0.1:7777` でプロセス内のフックサーバーが動き、チャット履歴はローカルの SQLite、同梱の MCP サーバー(Node 20+)は任意。WebView も Node サイドカーもない。ビルドには Zig 0.16.0 と `make` が必要で、詳細は [README](./packages/petdex-desktop-native/README.md#build--run) を参照

## ローカル開発

2 通りの方法がある。

| 目的 | コマンド | 準備 |
| --- | --- | --- |
| ローカルでフルスタックを動かす | `bun run dev:docker` | Docker または Podman。起動に約 30 秒 |
| 本番サービスに接続して動かす | `bun run dev` | `.env.local` の設定が必要(メンテナのみ) |

```sh
git clone https://github.com/origamium/petdex.git
cd petdex
bun install
bun run dev:docker
```

[localhost:3000](http://localhost:3000) を開く。詳しくは [`CONTRIBUTING.md`](./CONTRIBUTING.md) を参照。

デスクトップアプリは `packages/petdex-desktop-native` で `make dev PETDEX_PET=boba` を実行する。

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
- **プロジェクトを掲載する:** [Built with Petdex の issue](https://github.com/origamium/petdex/issues/new?template=built-with.yml) を作成
- **バグ修正・機能追加:** [`CONTRIBUTING.md`](./CONTRIBUTING.md) を読んでから PR を作成
- **交流する:** [Discord](https://discord.gg/byhubdyBTe) には、制作共有(`#wip`、`#ship-or-sink`)、フィードバック(`#cli-feedback`)、作品紹介(`#showcase`)のチャンネルがある

## ペットの権利と削除申請

ペットはユーザーが投稿したファンアート。Petdex は元となる IP について一切の権利を主張しない。キャラクターの権利者でペットの削除を希望する場合は、[削除申請](https://github.com/origamium/petdex/issues/new?template=takedown.yml)を提出してほしい。48 時間以内にレビューする。

## ライセンス

ソースコードは [MIT](./LICENSE)。ペットのアセットは投稿者に帰属し、ライセンスは投稿者が宣言したものに従う。

---

<div align="center">

フォーク保守: <a href="https://github.com/origamium">origamium</a>
オリジナルの Petdex: <a href="https://crafter.run">Crafter Station</a>、リード <a href="https://x.com/RaillyHugo">@RaillyHugo</a>

</div>
