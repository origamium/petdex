Pets 通知・MCP 連携の監査（2026-09-17）

その後の連携拡張（Copilot CLI／Windsurf／Amp／Droid、MCP 診断・会話読み取り）の実装と検証は、[最新の対応表](agent-integration-support.md) に記録。以下の件数・MCP バージョンは初回修正時点の記録。

**修正後の状態（同日追記）**

以下の初回監査で確認した不具合に対し、製品コードと回帰テストを更新した。自動通知はホストの hooks／plugin に戻し、MCP は任意の操作と情報補足に限定した。下記「初回監査」以降は修正前の証拠であり、現在の実装の説明ではない。

| 初回指摘 | 実施した修正 |
| --- | --- |
| 1・公開版との不一致 | Desktop に単独の Node 用 MCP サーバーを同梱。`npx petdex@latest` 依存を除去し、Desktop 起動時に同梱ファイルを更新。実際の `.mjs` を Node で起動して 4 ツールを確認 |
| 2・自動イベントの欠落 | Claude／Codex／Gemini の hooks と OpenCode plugin を復元。Cursor／Junie／Antigravity／Devin／Grok のホスト固有 hooks を追加。ユーザーや他の連携が設定した hooks を維持し、再インストールによる重複を防止 |
| 3・会話別状態と metadata | MCP の活動ツールで session ID を必須化。会話別状態、モデル、推論強度、作業ディレクトリ、端末復帰先を転送。native runner にホスト別 ID と完了／失敗／中断の正規化を追加 |
| 4・SSH のローカル設定変更 | remote staging 専用の明示的な root を導入。ローカル `CODEX_HOME`／`XDG_CONFIG_HOME` が別の値でも無変更であることを回帰テストで確認 |
| 5・OpenCode 設定 | 既存 V1／V2 を維持し、V2 に余分な直下 entry を作らない。新規 MCP 設定は V2。JSONC のコメント／末尾カンマを読み、使用中の JSONC に書き戻す |
| 6・古い使用量 | rollout と報告ファイルを測定時刻で比較。再開会話と `CODEX_HOME` に対応。期限切れや 1 時間超の観測は不明として非表示にし、0% を捏造しない |
| 7・認証保存形式 | Gemini の macOS Keychain／暗号化 FileKeychain／旧 OAuth JSON を読み取り。Antigravity は別の Keychain item と go-keyring envelope を使用。両アプリの token を流用しない |
| 8・取得元による上書き | ファイル由来とネット由来の観測を別々に保持し、新しい有効値を採用。ネット認証不在で新しい MCP 報告を消さない。最大 16 window とモデル／プール名を保持 |
| 9・MCP protocol | ping、notification 無応答、バージョン交渉、入力検証、`isError`、順序を保った EOF 処理を追加。使用量は timestamp 付きで atomic write |
| 10・誤った接続表示 | MCP 登録だけでは自動通知設定済みとしない。設定画面の表示を「自動通知設定済み」に変更。disabled entry、TOML の別 table、Devin の Windows 保存先を修正 |

新規テストは一時ホーム、疑似 HTTP、疑似 credential を使用した。実アカウントの token 取得・refresh・quota API 呼び出し、実ユーザーのエージェント設定変更は行っていない。

| 修正後の検証 | 結果 |
| --- | --- |
| CLI `bun test src/hooks` | 79 pass、0 fail（MCP 専用 10 件を含む） |
| CLI build／typecheck | 成功 |
| 同梱 MCP asset の生成内容チェック | 成功。CI にも追加 |
| Native `make test` | 440/440 pass、model contract／analysis 成功 |
| Native macOS `make build` | 成功 |
| hooks 設定モジュールの Windows／Linux 向けコンパイル | 成功。GUI／実ホストでの実行検証を意味しない |

**反映方法とサポート境界**

修正ビルドで Desktop を更新し、Settings → Connections から対象エージェントの Install／Update を実行してホストを再起動する。これにより旧 MCP entry を置き換え、自動通知 hooks を復元する。MCP の登録だけがある環境は「Hooks not installed」と表示する。無効化した hooks を起動時に勝手に有効化する移行は行わない。今回、稼働中 Desktop の置き換え／再起動やリリースは実施していない。

- Junie hooks は CLI EAP の TUI／batch 向け。ACP／server／IDE では使えず、一部イベントに session ID がない。成功終了が許可承認になる `PermissionRequest` は登録しない。[Junie hooks](https://junie.jetbrains.com/docs/junie-cli-hooks.html)。
- Cursor は prompt、tool result／failure、stop／session end を監視する。権限判断を返す pre-tool hooks は登録せず、一般的な承認ダイアログ待機を保証しない。user hooks は Cursor Cloud Agents には届かない。[Cursor hooks](https://cursor.com/docs/hooks)。
- MCP ツールには Node 20+ とホストからの明示的な呼び出しが必要。hooks／plugin の自動通知自体は MCP サーバーを必要としない。ホスト再起動、project override、global opt-out、対応バージョンは引き続き配信に影響する。
- 使用量の自動取得は macOS に限る。Antigravity の file-only 認証、未確認の credential layout、各サービスの未公開 quota 仕様は対応済みとしない。OpenCode／Devin 等の報告受付は、上流 provider の quota 自動取得を意味しない。
- 使用量の表示単位はエージェントであり、複数アカウントを独立した行として表示する実装ではない。アカウント名を取得できない観測に、推測したアカウント名を付けない。
- 全ホスト・全バージョンの GUI／CLI end-to-end、実 SSH host、実 quota endpoint は未検証。今回の結果を全機能・全環境での動作保証とはしない。

認証形式の照合元：[Gemini OAuth storage](https://raw.githubusercontent.com/google-gemini/gemini-cli/main/packages/core/src/code_assist/oauth-credential-storage.ts)、[Gemini FileKeychain](https://raw.githubusercontent.com/google-gemini/gemini-cli/main/packages/core/src/services/fileKeychain.ts)、[go-keyring macOS 実装](https://raw.githubusercontent.com/zalando/go-keyring/master/keyring_darwin.go)。対応表と導入手順は [Desktop README](../packages/petdex-desktop-native/README.md#usage-limits) にも反映した。

**初回監査（以下は修正前）**

**初回判定：従来の通知機能を十分にサポートしたとは言えない。** MCP の設定生成と基本通信は実装されているが、公開パッケージとの不一致、自動イベント通知の欠落、会話別の状態情報の欠落がある。設定画面の Connected 相当の判定を、通知が実際に動くことの保証には使えない。

対象は `7e174e8`、`a5c7259` の MCP 移行と、調査時点の未コミット変更。CLI、ネイティブアプリ、SSH writeback、使用量取得、公式設定仕様、npm 配布物を確認した。製品コード・実ユーザーの設定・認証情報は変更していない。再現用コードと仮想ホームは `/tmp/petdex-mcp-audit` に分離した。

**1. [P1・実物で再現] インストーラーが起動する公開版に新機能が入っていない**

[agent_mcp.zig](../packages/petdex-desktop-native/src/agent_mcp.zig) の `mcp_args` は `npx -y petdex@latest mcp-server` を生成する。調査時に npm registry の `latest` を取得すると **1.3.0** だった。その tarball の実際の `dist/petdex.js` を起動し、外向き HTTP をテスト用の応答に置き換えて確認した。

| 項目 | 手元の実装 | 公開版 1.3.0 |
| --- | --- | --- |
| `tools/list` | 4 tools | 3 tools |
| `petdex_report_usage` | 使用量ファイルを保存 | `-32601 Unknown tool` |
| `PETDEX_MCP_AGENT=codex` | `agent_source: codex` | `agent_source: antigravity` 固定 |
| `session_id` / `busy` | bubble に転送 | 転送しない |

つまり手元のネイティブ版をビルドしても、この設定から動く MCP サーバーは古い。全通知が Antigravity 扱いになり、会話の分離・稼働中表示・使用量報告も新実装どおりには動かない。新 CLI のリリースと、その配布物自体の互換性確認が必要。`@latest` 化だけでは解決しない。[取得した registry metadata](https://registry.npmjs.org/petdex/latest)、[検証した 1.3.0 配布物](https://registry.npmjs.org/petdex/-/petdex-1.3.0.tgz)。

**2. [P1・コード／仕様で確認] 自動フックを削除しても MCP が代わりにイベントを受け取るわけではない**

[agent_hooks.zig](../packages/petdex-desktop-native/src/agent_hooks.zig) の `installClaude`（701 行付近）、`installGemini`、`installCodex`、`installOpencode`（1899 行付近）は MCP 設定を書いた後に Petdex の hooks／plugin を取り除く。一方、[mcp-server.ts](../packages/petdex-cli/src/hooks/mcp-server.ts) は `tools/call` を待つサーバーで、ホストの tool start、permission request、turn completion、turn failure を購読していない。

ツール説明の「before and after every tool use」「starts or finishes a meaningful step」はモデルへの依頼にすぎない。MCP の tools はモデルが選んで呼び出す機能であり、登録しただけではライフサイクル通知にならない。Claude Code の `PermissionRequest`、`Stop`、`StopFailure` などは別の hooks インターフェースである。[MCP Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)、[Claude Code hooks](https://code.claude.com/docs/en/hooks-guide)。

モデルが Petdex を呼ばないターン、承認画面で止まった時、API エラーでモデルが返答できない時、中断・異常終了を確実には検出できない。従来の通知の代替としては未達。自動イベントを送る hooks／plugin／監視アダプターを維持し、MCP は任意の説明文や操作を補う役割にする必要がある。SSH Codex の既存 watcher は残っているため、この指摘を「すべての Codex 経路で監視が消えた」とは解釈しないこと。

**3. [P1・送信 payload で再現] MCP では会話ごとの承認待ち・失敗を表現できない**

[mcp-server.ts](../packages/petdex-cli/src/hooks/mcp-server.ts) の 364 行／392 行付近では、`petdex_set_state` に session がなく、`petdex_show_bubble` に `agent_state` がない。ツール呼び出しに `agent_state: "failed"` を加えても送信時に落ちることを再現した。

[main.zig](../packages/petdex-desktop-native/src/main.zig) の `bubbleState`（3765 行付近）は `agent_state == failed` で失敗バッジを判定し、状態がない場合の waiting は「最新の吹き出し＋ペット全体の waiting」へフォールバックする。`set_state(failed)` だけでは、その会話の失敗バッジにはならない。複数会話で waiting の対象がずれ、完了を意味する `busy:false` だけでは失敗と完了を区別できない。待機時の案内にも影響する。

また `session_id` は任意で、自動取得・生成がない。省略したクライアントは [hook_server.zig](../packages/petdex-desktop-native/src/hook_server.zig) の空キーを共有し、別会話が上書きされる。

同じ送信経路で `source_app`、`source_tty`、`source_cwd`、`warp_focus_url`、`model`、`effort` も落ちる。したがって既存 UI が対応していても、MCP だけの新規通知では「Warp／Terminal で開く」、自動的なプロジェクト名、モデル・推論強度を提供できない。会話 ID と会話別状態を必須の共通イベントとして扱い、取得できる実行元情報をアダプターが添える必要がある。

**4. [P1・隔離環境で再現] SSH の設定生成がローカルの設定を変更する**

[remote_writeback.zig](../packages/petdex-desktop-native/src/remote_writeback.zig) の `runInstaller`（154 行付近）は fake home を引数に渡してローカル用 installer を再利用する。しかし新しい [agent_mcp.zig](../packages/petdex-desktop-native/src/agent_mcp.zig) の `presenceDir` は、渡された home よりグローバルな `env_codex_home`／`env_xdg_config_home` を優先する。

再現では、ローカル役の `CODEX_HOME/config.toml` に `model = "local-model"` だけを置き、別の fake home に対して remote Codex installer を実行した。実際にローカル役のファイルへ `[mcp_servers.petdex]` が追記された。実ユーザーの設定ではなく `/tmp` 内だけで再現した。

このままだとリモートへの install 操作がローカル環境を変更し、staging から読み戻すファイルには必要な変更が載らない。OpenCode の `XDG_CONFIG_HOME` も同じ構造。remote 用には env override を持ち込まない明示的な設定パスを渡すべきで、既に Hermes にある `installHermesAt` 型の分離が参考になる。

**5. [P1・生成結果で再現] OpenCode V2 の設定形式がまだ混在している**

[agent_mcp.zig](../packages/petdex-desktop-native/src/agent_mcp.zig) の `mergeOpencodeMcp`（479 行付近）は常に V1 の `mcp.petdex` を書き、既存の `mcp.servers` がある時だけ V2 にも書く。`{"mcp":{"servers":{}}}` を入力した再現で両方のキーが生成された。新規設定は V1 のキーだけになる。

V2 公式仕様はサーバーを `mcp.servers` 配下に置き、`mcp` 直下にサーバー名を置かない。今回の `enabled` を除く変更は内側の entry のみで、外側の形式は直っていない。V2 の新規インストール／既存設定の双方について対応完了とは言えない。[OpenCode V2 MCP](https://opencode.ai/v2/docs/mcp-servers)。調査時は公開 `config.json` の取得結果に V1 の定義も残っていたため、公開 schema URL だけに依存せず、対応する実クライアント版ごとの検証が必要。

加えて `.jsonc` を探す処理があっても、読み取り・削除は `std.json.parseFromSlice(..., .{})` の strict JSON。コメント付きの正常な OpenCode JSONC を渡すと未接続判定になった。削除側も同じ parse を使うため、その形式を処理できない。OpenCode はコメントと末尾カンマを正式にサポートしている。[OpenCode Config](https://opencode.ai/v2/docs/config)。

**6. [P2・数値を再現] Codex 使用量の「最新」の選び方が誤っている**

[usage.zig](../packages/petdex-desktop-native/src/usage.zig) の `readFiles`（409 行付近）は報告ファイルがあれば無条件に採用し、rollout を読まない。旧 Stop hook や一度だけの MCP 報告が残ると、その後の新しい rollout を恒久的に隠す。期限が過ぎた window は `current` により 0% になるため、古い値を新鮮な「0%」として見せる。

再現：期限切れの報告ファイルと、72% を示す新しい rollout を用意すると **0%** が表示値になった。

フォールバック側の `findNewestRollout`（435 行付近）も更新時刻ではなくパス名の辞書順で選ぶ。昨日開始した会話を今日再開して 72% になっても、今日作成して放置した会話の 20% を選んだ。

さらに `windowsFromCodexSessions`（423 行付近）は `~/.codex/sessions` 固定で、新しく MCP installer が対応した `CODEX_HOME` を使用しない。独自 root に 72% の rollout を置いた追加テストでは値が `null` になった。使用量の取得元にも同じ root 解決が必要。ファイル／アカウント／測定時刻を記録し、実際の新しさで選び、期限切れは「不明／古いデータ」と区別する必要がある。

**7. [P2・公式実装との不一致] Gemini／Antigravity の認証取得をカバーできていない**

[usage.zig](../packages/petdex-desktop-native/src/usage.zig) の `googleToken`（683 行付近）は `.gemini/oauth_creds.json` だけを読む。[main.zig](../packages/petdex-desktop-native/src/main.zig) はそこから得た同じ token を Gemini と Antigravity に使う。

Gemini の公式 `OAuthCredentialStorage` は secure storage を使用し、旧 `oauth_creds.json` を移行後に削除する実装を持つ。この保存形態では正しくログイン済みでも現在の reader には token が見つからない。[Gemini 公式 credential storage](https://raw.githubusercontent.com/google-gemini/gemini-cli/main/packages/core/src/code_assist/oauth-credential-storage.ts)。

Antigravity CLI も公式仕様に secure keyring が記載されている。インストール済みの公式 `agy` バイナリには Keyring LoadToken／SaveToken と file fallback の経路があり、`oauth_creds.json` の文字列はなかった。ディレクトリの存在だけで Gemini の token と Antigravity の選択アカウントが同一だとは保証できない。[Antigravity CLI reference](https://www.antigravity.google/docs/cli/reference/)。

したがって README の「両者はこの JSON の sign-in を共有する」はサポート範囲を広く言いすぎている。各アプリの既存認証保存先とアカウントを識別し、読めない場合を明示する必要がある。今回、実アカウントの token 取得・更新・quota API 呼び出しは行っていないため、HTTP 200 の取得成功までは保証しない。

**8. [P2・コードで確認] MCP から報告した使用量をネット取得が消す／上書きする**

[usage.zig](../packages/petdex-desktop-native/src/usage.zig) のコメントは報告ファイル優先とするが、[main.zig](../packages/petdex-desktop-native/src/main.zig) の `refreshUsage` はファイルを読んだ直後に `fetchUsage` を実行する。該当 provider の credential がなければ `set(agent, null)`、HTTP 応答時も `onUsageResponse` が無条件に値を置き換える。

例えば MCP で Grok の使用量を正常に保存しても、Grok credential がない環境ではネット取得のタイミングで行が消える。次のファイル読み取りで戻り、5 分ごとの取得で再び消える。古い報告ファイルがある場合は逆に新しいネット値を 1 分ごとの read が上書きする。取得元を分離して保持し、新しさ・有効性を比較してから表示値を選ぶ必要がある。

**9. [P2・stdio で再現] MCP の基本的な接続維持処理が不足している**

[mcp-server.ts](../packages/petdex-cli/src/hooks/mcp-server.ts) の `handleRequest`（314 行付近）は `ping` を `-32601` にし、`notifications/cancelled` にも error response を返す。両方とも手元版と公開版で再現した。仕様は ping に空の result、notification に無応答を要求する。初期化と tools/list の成功だけで全クライアント互換とは判断できない。[MCP Ping](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/ping)、[MCP Base Protocol](https://modelcontextprotocol.io/specification/2025-11-25/basic)。

ツール実行失敗も `textResult` の通常成功として返され、`isError` を設定しない。デスクトップ未起動、401、429、入力不正を区別できず、失敗時の案内には廃止済みの `petdex up`／`petdex hooks on` が残る。MCP SDK の利用、または同等のプロトコル適合テストが必要。

**10. [P2・再現／公式仕様] 接続判定と OS 対応に抜けがある**

[agent_mcp.zig](../packages/petdex-desktop-native/src/agent_mcp.zig) の `entryLooksCurrent`／`tomlHasPetdex` は主に command と args を見るだけで、起動、tools/list、デスクトップまでの疎通を確認しない。Devin 用の正しい entry に `disabled:true` を加えても `.current` となることを再現した。Devin はこのフラグで接続を無効化する仕様なので、接続中の表示と実際が食い違う。[Devin MCP configuration](https://docs.devin.ai/cli/extensibility/mcp/configuration)。

同じ公式仕様では Devin の Windows 保存先は `%APPDATA%\devin\mcp_config.json` だが、現在の `presenceDir(.devin)` は全 OS で `~/.config/devin`。Windows では検出も設定の書き込み先も合わない。Windows／Linux の実クライアント試験は今回行っていない。GUI 起動時の `npx`／Node.js の PATH、offline、起動 timeout、project override、無効化・承認設定も別途確認が必要。

**現時点のサポート範囲**

「設定の基本形を確認」は、実クライアントで自動通知まで成功したという意味ではない。以下の MCP 9 エージェントには、共通して 1〜3・9 の制約がある。

| エージェント | 通知の現在の接続方法 | 使用量の実装と残る制約 |
| --- | --- | --- |
| Claude Code | user scope MCP。旧 hooks を除去 | statusline relay を維持。MCP 移行で通知イベントの自動性は失う |
| Codex | TOML MCP。旧 hooks を除去。SSH watcher は残る | report file／rollout。鮮度・再開会話・CODEX_HOME に問題 |
| Gemini CLI | settings.json の MCP。旧 hooks を除去 | 新規 Code Assist polling。credential 保存形態の対応不足、実 API 成功未検証 |
| OpenCode | V1／V2 MCP 生成。旧 plugin を除去 | report file のみ。選択した上流 provider の quota を自動取得する実装はない |
| Cursor | ~/.cursor/mcp.json | usage-summary polling と report file。MCP 起動の実機確認は未実施 |
| Junie | ~/.junie/mcp/mcp.json | macOS の JetBrains quota XML と report file。CLI だけで XML がない環境は取得できない |
| Antigravity | ~/.gemini/config/mcp_config.json、legacy 検出あり | 新規 summary polling。独自 credential／アカウントの扱いが不足 |
| Devin CLI | 専用 JSON MCP | report file のみ。Windows の保存先が不一致 |
| Grok CLI | TOML MCP | 新規 billing polling。有効な consumer token のみ、実 API 成功未検証 |
| Qoder／Kimi Code／CodeBuddy／OMP／Hermes／DSH | hooks／plugin 系を継続 | usage agent の許可リスト追加は受信対応のみ。各サービスの quota 自動取得にはならない |
| Copilot | 専用 MCP installer なし | 既存 endpoint polling と report file |

設定基本形の照合先：[Claude Code](https://code.claude.com/docs/en/mcp)、[Codex](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)、[Gemini](https://geminicli.com/docs/tools/mcp-server/)、[Cursor](https://prod.cursor.com/help/customization/mcp)、[Junie](https://junie.jetbrains.com/docs/junie-cli-mcp-configuration.html)、[Antigravity](https://www.antigravity.google/docs/mcp)、[Grok](https://docs.x.ai/build/features/mcp-servers)。

使用量の表示精度にも制限がある。`Windows` は最大 2 件で model／pool／account を保持しない。Gemini は残りが少ない 2 モデルだけ、Antigravity は同じ期間の最も消費した bucket に集約するため、詳細を開いても「どのモデルの制限か」が分からない。全モデル／全プールの詳細サポートとは言えない。

**実行した検証**

| 検証 | 結果 |
| --- | --- |
| CLI `bun test src/hooks` | 73 pass、0 fail。MCP 専用はうち 4 件 |
| CLI `bun run build` | 成功 |
| CLI `bun run typecheck` | 成功 |
| Native `make test` | 429/429 pass、model contract／analysis 成功 |
| Native macOS `make build` | 成功。初回は Zig cache の sandbox 制限で失敗し、権限付き再実行で成功 |
| npm 1.3.0 と手元版への stdio probe | 公開版差異、payload 欠落、ping／notification の不適合を再現 |
| コピーした Zig source への追加ケース | stale report、再開した旧 session、CODEX_HOME、V2 のキー混在、disabled entry、remote staging、JSONC の計 7 ケースで期待条件に不合格 |

追加ケースは製品ファイルへ書かず `/tmp/petdex-mcp-audit/src` のコピーに置いた。MCP の HTTP は stub で payload を記録したため、稼働中のペットへテスト通知を送っていない。Google／Grok を含む実アカウントの quota 取得、全エージェントの GUI／CLI end-to-end、Windows／Linux、実 SSH host へのインストールは未検証。これらを成功済みとは扱わない。

既存 MCP テストは起動前 stdout、初期化、framing、tools/list が中心で、実 tools/call、配布物、per-session state、エラー応答、設定のクライアント側 validation、移行後の自動通知を保証していない。既存テストがすべて緑でも上記の欠落は検出できない。

**対応完了と判定するために必要なこと**

1. 新 CLI の配布物で agent・session・usage を検証し、対応版が存在することを確認してから desktop の installer を切り替える。
2. 自動通知の hooks／plugin／watcher と MCP の役割を定め、start → waiting → resumed → done／failed／cancelled を決定的に送れるようにする。
3. 複数会話を同時に動かし、状態・通知音・案内・端末復帰先が混ざらないことを確認する。
4. 各クライアント版に合う JSON／JSONC／TOML を生成し、設定保存に加えて実プロセス起動と tools/list を確認する。SSH staging はローカルの env と分離する。
5. quota に provider、account、model／pool、observed_at、source、取得状態を保持し、古い値・認証切れ・未対応・0% を区別する。
6. desktop 未起動、再起動、401／403／429、無効化、独自 config root、credential 移行、offline、既存インストールからの更新／削除を検証する。

監査時の source SHA-256 先頭 16 桁：`agent_mcp.zig=104ab1c687ee34bc`、`agent_hooks.zig=0c0ba48da3f74a9d`、`main.zig=47f693729101e60a`、`usage.zig=2419f3d3417a9cdd`、`remote_writeback.zig=4931cc868e9dda0f`、`hook_server.zig=bf8750007d0ca894`、`mcp-server.ts=314892960b958c8f`。調査中に既存変更の staging 状態は変化したが、監査対象の製品ファイルをこちらから変更・stage していない。
