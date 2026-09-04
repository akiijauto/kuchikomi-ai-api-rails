# kuchikomi-ai-api-rails

[![CI](https://github.com/akiijauto/kuchikomi-ai-api-rails/actions/workflows/ci.yml/badge.svg)](https://github.com/akiijauto/kuchikomi-ai-api-rails/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-3.4-CC342D.svg)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/Rails-8.1-CC0000.svg)](https://rubyonrails.org/)

稼働中の個人開発サービス **クチコミ返信AI**（口コミへの返信文をAIが下書きするSaaS）の API を、
**Ruby on Rails の APIモード**で実装したもの。

同じ API を Next.js・Go でも実装しており、**3つの実装が同一のデータベース・同一のスキーマを見て
AWS 上で同時に稼働する**ことを実測している。その比較の全体像は元リポジトリ
[kuchikomi-ai-multi-stack](https://github.com/akiijauto/kuchikomi-ai-multi-stack) にある。

---

## エンドポイント

| メソッド | パス | 内容 |
|---|---|---|
| `GET` | `/api/health` | 死活監視。認証基盤にもDBにも依存しない |
| `POST` | `/api/generate` | 認証 → 入力検証 → 利用回数の上限チェック → 返信文の生成 |
| `POST` | `/api/profile` | 認証 → 入力検証 → プロフィール更新 |
| `POST` | `/api/demo/token` | デモ用トークン発行。`DEMO_MODE=1` のときだけ**経路そのものが存在する** |

ステータスコードとエラー文言は Next.js版・Go版に合わせてある。同じ画面から呼び先を差し替えるだけで動く。

---

## 設計判断

### 1. Rails のマイグレーションを持たない

テーブル定義の正本は元リポジトリの `web/supabase/schema.sql` のままにし、Rails 側は既存の表を使うだけにした。
`db/migrate` を書くと**同じ表の定義が2箇所に増える**。
この演習の主旨は「**同じスキーマに別言語の実装を載せる**」ことなので、定義を複製する理由がない。

CI もこの方針に従い、**毎回その正本を取りに行って**テストを流している（`.github/workflows/ci.yml`）。

### 2. 利用回数の上限判定を Ruby に持ってこなかった

DB の `public.increment_usage` をそのまま呼んでいる。

「今の件数を読む → 判定する → 書く」をアプリ側で書くと、同時に2本来たときに上限を超えられる。
DB関数は1文の中で判定と加算を行うので、**実装言語が変わっても保証が変わらない**。
Next.js版・Go版と同じ関数を呼んでいるため、上限の挙動は自動的に一致する。

```ruby
# app/services/usage_counter.rb
# increment_usage の中の auth.uid() が読む値を立てる。
# 第3引数 true はトランザクション内だけ有効という意味で、
# 接続を使い回しても他のリクエストへ漏れない。
exec("select set_config('request.jwt.claim.sub', $1, true)", [text_param("sub", user_id)])
row = exec("select public.increment_usage($1) as count", [text_param("month", month)])
```

**AWS 上での実測**：Go版と Rails版を交互に呼ぶと `used` が 1→5 と進み、
**6回目はどちらから呼んでも429**で止まる。入り口が増えても枠は増えない。

### 3. PostgreSQL のエラーコードで判定する

上限超過は SQLSTATE `P0001`、プラン不明は `P0002` で判定している。
**メッセージ文字列で判定すると、DB側の文言を変えた瞬間に静かに壊れる。**

### 4. 認証は JWT を自前で検証した

Next.js版は `supabase-js` の `auth.getUser()` が裏でやっている。Rails にその依存は無いので、
Supabase が発行した JWT を `jwt` gem で検証している。やることは同じで、
「署名が正しいか」と「誰なのか（`sub`）」を取り出すだけ。

受け入れる署名方式は `HS256` に限定している（`JWT.decode(token, secret, true, { algorithm: "HS256" })`）。

### 5. RLS を当てにせず、Rails 側でも自分の行に限定した

本番の Supabase では行レベルセキュリティが最後の砦になる。
しかし Rails が**テーブル所有者のロールで接続すると、RLS は素通りする**。
**同じスキーマでも、誰として接続するかで守りが変わる。**

```ruby
profile = Profile.find_by(id: current_user_id)
```

この絞り込みは飾りではない。テストでも「他人の行が変わらないこと」を確認している。

### 6. デモ用の口はコントローラではなくルーティングで塞いだ

```ruby
post "demo/token", to: "api/demo#token" if ENV["DEMO_MODE"] == "1"
```

コントローラ内で判定する形にすると、設定を間違えたときに経路が生きたままになる。
これは「誰でもログイン済みになれる入口」なので、**存在しないことが保証される側**に倒した。

### 7. `SECRET_KEY_BASE` を外から渡し、`master.key` をイメージに焼かない

`master.key` をイメージへ入れると、イメージを取得できる人が資格情報を全部読める。
Rails は `SECRET_KEY_BASE` を直接渡せば credentials を読まずに起動できる。

---

## 詰まった点の記録

**「作る」つもりが既にあった**
テストヘルパで `auth.users` に挿入したあと `Profile.create!` したところ、主キー重複で11件が落ちた。
原因は `schema.sql` の `on_auth_user_created` トリガーで、
**`auth.users` への挿入時点で `profiles` の行が自動で作られていた**こと。
作成ではなく更新に直して解消。落ちたおかげでトリガーが効いていることの確認にもなった。

**SDKの引数名は推測せず実物を見た**
Anthropic の Ruby SDK は `system:` ではなく `system_:`（`Kernel#system` と衝突するため）、
構造化出力は `format:` ではなく `format_:`（送信時に `format` へ変換）。
`gem environment gemdir` から実物の定義を読んで確認した。
TypeScript版の書き方から推測していたら、鍵が無い環境では気づけないまま埋め込んでいた。

**`rails new --skip-git` は `.gitignore` を作らない**
そのため `config/master.key` がコミットされていた。公開前ゲートが検出し、
追跡から外して鍵を再生成、履歴からも除去した。
**Rails を新規作成したら必ず `.gitignore` の有無を確認すること。**

---

## 構成

```
app/controllers/api/   base（認証） / generate / profiles / health / demo
app/services/          reply_generator（生成） / usage_counter（上限） / plans
app/models/profile.rb  public.profiles に対応（マイグレーションでは作らない）
lib/tasks/bootstrap.rake  LOAD_SCHEMA=1 のとき起動時にスキーマを投入する
spec/                  RSpec（リクエストスペック）
public/demo.html       ブラウザから試せるデモ画面
```

---

## 環境変数

| 変数 | 必須 | 内容 |
|---|---|---|
| `DATABASE_URL` | ✅ | `postgresql://user:pass@host:5432/db` |
| `SUPABASE_JWT_SECRET` | ✅ | トークンの検証鍵 |
| `SECRET_KEY_BASE` | 本番で✅ | これを渡せば `master.key` は不要 |
| `RAILS_FORCE_SSL` | | TLS終端が無い構成では `false`。**既定値そのものは変えていない** |
| `DEMO_MODE` | | `1` のときだけデモ用トークンの口が生える |
| `LOAD_SCHEMA` | | `1` のとき起動時に `db/bootstrap/*.sql` を適用する |
| `ANTHROPIC_API_KEY` | | 無ければデモ返信（`mock: true`）を返す |
| `GENERATION_MODEL` | | 既定 `claude-sonnet-4-6`（他の2実装と同じ） |

`RAILS_FORCE_SSL` の既定を `false` にしていないのは、
**そうすると後で本物の本番を作ったときに「SSLが切れていることに気づかない」**ため。

---

## 動かす

```bash
bundle install
export DATABASE_URL=postgresql://postgres:postgres@localhost:5432/kuchikomi
export SUPABASE_JWT_SECRET=dev-secret
export DEMO_MODE=1
bin/rails server
# → http://localhost:3000/demo.html
```

スキーマは元リポジトリから取得して流し込む。

```bash
BASE=https://raw.githubusercontent.com/akiijauto/kuchikomi-ai-multi-stack/main
curl -fsSL "$BASE/db/init/00_supabase_compat.sql" | psql "$DATABASE_URL"
curl -fsSL "$BASE/web/supabase/schema.sql"        | psql "$DATABASE_URL"
```

AWS 上では RDS に外から接続できない（`publicly_accessible = false`、踏み台もALBも無い）ため、
`LOAD_SCHEMA=1` で起動すると**アプリ自身が** `rails db:bootstrap` を実行してスキーマを投入する。

---

## テスト

```bash
DATABASE_URL=postgresql://... bundle exec rspec --format documentation
```

**14件。** 確認している内容:

- 認証なし / 別の鍵で署名 / 期限切れ → すべて401
- 入力検証（短すぎる口コミ・範囲外の星・未知のtone）→ 400
- 店名未設定は400
- デモ返信3案 + 署名の付与 + 利用回数の加算
- 無料プランの上限5件で429、6件目は加算されない
- プロプランは5件を超えても通る
- **自分の行だけが更新される**（他人の行が変わらない）

---

## ライセンス

MIT License（[LICENSE](LICENSE)）
