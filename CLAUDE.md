# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

このリポジトリはUbuntu環境のセットアップスクリプトを管理するためのプロジェクトです。現在、k3sノードのセットアップに関連するスクリプトが含まれています。

## リポジトリ構造

```
ubuntu-setup/
├── README.md                    # プロジェクトの説明文書
├── CLAUDE.md                    # このファイル
└── k3s-node_ubuntu24.04.sh      # Ubuntu 24.04向けk3sノードセットアップスクリプト
```

## k3s-node_ubuntu24.04.sh の機能

このスクリプトはUbuntu 24.04のVPSインスタンスをk3sノードとして初期設定します：

### コマンドラインオプション
- `--ssh-port PORT`: SSHポートを指定（デフォルト: 2222）
- `--hostname NAME`: ホスト名を指定（デフォルト: 変更なし）
- `-h, --help`: ヘルプを表示

### 主な機能

1. **パーティション設定**:
   - システムパーティションを40GBに調整
   - 残りの容量をLonghorn用パーティション（/var/lib/longhorn）として設定

2. **VPNツール**: 
   - Tailscale, Cloudflared のインストール

3. **セキュリティ**: 
   - SSHポートを指定されたポート（デフォルト2222）に変更
   - fail2banによる不正アクセス防止
   - 自動セキュリティアップデート（unattended-upgrades）

4. **k3s準備**:
   - swapの無効化
   - カーネルモジュール（overlay, br_netfilter）のロード
   - ネットワーク設定の最適化（IP転送、ブリッジ設定）
   - inotify制限の引き上げ

5. **ローカルネットワーク**: 
   - enp7s0インターフェースでローカルネットワークにDHCP参加
   - 取得したIPは`/etc/k3s-local-ip`に保存

6. **システム設定**:
   - タイムゾーンをAsia/Tokyoに設定
   - journaldのログサイズ制限（最大2GB）
   - 必要なカーネルモジュール（dm_crypt）のロード

7. **運用ツール**: 
   - htop, iotop, net-tools, jq
   - open-iscsi, nfs-common（ストレージ関連）

### 実行例
```bash
# デフォルト設定で実行
./k3s-node_ubuntu24.04.sh

# SSHポートとホスト名を指定
./k3s-node_ubuntu24.04.sh --ssh-port 2222 --hostname k3s-node-01

# curlから実行
curl -fsSL https://raw.githubusercontent.com/miiton/ubuntu-setup/refs/heads/main/k3s-node_ubuntu24.04.sh | bash -s -- --ssh-port 2222 --hostname k3s-node-01
```

## 開発時の注意事項

1. **スクリプトの実行権限**: シェルスクリプトを作成・編集する際は、実行権限の付与を忘れずに行ってください:
   ```bash
   chmod +x k3s-node_ubuntu24.04.sh
   ```

2. **シェルスクリプトの記述**: 
   - シバン（shebang）を必ず先頭に記述: `#!/bin/bash`
   - エラーハンドリングを適切に実装
   - 変数は`"${変数名}"`の形式で参照

3. **セキュリティ**: 
   - セットアップスクリプトには機密情報を直接記述しない
   - 必要に応じて環境変数や外部設定ファイルを使用

4. **ログ出力**:
   - スクリプトの実行ログは自動的に `/var/log/k3s-node-setup.log` に保存されます
   - 標準出力と標準エラー出力の両方が記録されます

## 今後の拡張予定

このリポジトリは初期段階にあり、以下のような拡張が想定されます：
- 各種開発環境のセットアップスクリプト
- システム設定の自動化スクリプト
- インストール済みパッケージの管理