# DeepSeek V4 Flash on AWS EC2 G7e

AWS EC2 G7eへDeepSeek V4 Flash NVFP4を展開し、vLLMのOpenAI互換APIとして実行するためのPoCリポジトリです。

TerraformによるECS on EC2環境、GPU Compute Poolの起動と停止を行うスクリプト、ストリーミング性能を測るベンチマークツールを収録しています。

## 構成

```text
Internal ALB
    |
ECS Service
    |
ECS Capacity Provider
    |
Auto Scaling Group
    |
g7e.12xlarge
    └── ECS Task
          └── vLLM 0.26.0
                └── DeepSeek V4 Flash NVFP4
                    Tensor Parallel = 2
```

Terraformは次のリソースを作成します。

- VPC
- Public Subnet 1つ
- Private Subnet 2つ
- NAT Gateway
- Internal Application Load Balancer
- ECS Cluster
- ECS on EC2用のGPU Auto Scaling Group
- ECS Capacity Provider
- モデルごとのTask DefinitionとECS Service
- CloudWatch Logs
- ECR Repository

ECS ServiceとGPU Auto Scaling Groupの初期台数は0です。
Terraformを適用しただけではGPUインスタンスは起動しません。

## 費用上の注意

GPUインスタンスを停止していても、NAT Gateway、Application Load Balancer、Elastic IP、EBS、ECR、CloudWatch Logsなどの料金が発生する場合があります。

`ecs-start.sh`を実行すると、ECS Capacity Providerを介して`g7e.12xlarge`が起動します。
実行前にG系インスタンスのクォータ、G7eの提供状況、現在の料金を確認してください。

## 必要なもの

- AWS CLI
- Terraform 1.14系
- AWS認証情報
- G7eを起動できるService Quotas
- Docker HubとHugging Faceへ到達できるネットワーク
- 任意：aws-vault

モデルの利用条件は、各配布元のライセンスを確認してください。

## デプロイから測定まで

以下の手順では、AWS認証にaws-vaultを使用します。
aws-vaultを使わない場合は、各コマンドから`aws-vault exec "${AWS_VAULT_PROFILE}" --`を外し、AWS CLIとTerraformが認証情報を取得できる状態で実行してください。

### 1. 対象AWSアカウントの設定

操作対象のAWSアカウントとaws-vaultプロファイルを環境変数へ設定します。
運用スクリプトは、認証中のAWSアカウントが`AWS_ACCOUNT_ID`と一致しない場合に処理を中止します。

```bash
export AWS_ACCOUNT_ID="123456789012"
export AWS_VAULT_PROFILE="your-profile"
```

Terraformの設定例をコピーします。

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars
```

作成した`terraform.tfvars`の`aws_account_id`を対象AWSアカウントへ変更します。

```hcl
aws_account_id = "123456789012"
aws_region     = "ap-northeast-1"
```

### 2. Terraformの適用

Terraformを初期化し、フォーマットと構文を検証します。

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  terraform -chdir=infra/terraform init

aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  terraform -chdir=infra/terraform fmt -check -recursive

aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  terraform -chdir=infra/terraform validate
```

Planをファイルへ保存します。

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  terraform -chdir=infra/terraform plan \
  -out=deepseek-v4-flash.tfplan
```

Planに意図しない削除がないことと、料金が発生するリソースを確認してから適用します。

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  terraform -chdir=infra/terraform apply \
  deepseek-v4-flash.tfplan
```

Terraformの適用直後は、ECS ServiceとGPU Auto Scaling Groupが0台のため、GPU料金は発生しません。
ただし、NAT GatewayやApplication Load Balancerなどは作成時点から課金対象になります。

詳しい変数と設計は[Terraform README](infra/terraform/README.md)を参照してください。

### 3. Internal ALBのURL取得

Terraform outputからInternal ALBのURLを取得します。

```bash
export VLLM_URL="$(terraform -chdir=infra/terraform output -raw vllm_url)"
echo "${VLLM_URL}"
```

このALBはInternalです。
以降のAPI呼び出しは、VPC、VPN、踏み台ホストなど、ALBへ到達できるネットワークから実行してください。

### 4. GPU環境の起動

DeepSeekのECS Serviceを1へ変更します。
ECS Capacity Providerが必要なEC2容量を検知し、`g7e.12xlarge`を1台起動します。

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" \
  ./scripts/ecs-start.sh deepseek-v4-flash
```

EC2の起動、コンテナイメージの取得、約168GBのモデル取得、モデルロードが順番に行われます。
初回起動には時間がかかるため、次のコマンドでECS Service、Auto Scaling Group、直近のECSイベントを確認します。

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" \
  ./scripts/ecs-status.sh deepseek-v4-flash
```

`desired=1`、`running=1`、`pending=0`になった後、`/v1/models`へ接続できることを確認します。

```bash
curl --fail --show-error \
  -H 'X-LLM-Profile: deepseek-v4-flash' \
  "${VLLM_URL}/v1/models"
```

ALB Targetがhealthyになるまでは`503 Service Unavailable`になる場合があります。
その場合は`ecs-status.sh`でECSイベントを確認し、モデルロードの完了を待ってから再実行してください。

### 5. ベンチマーク

ベンチマークツールはOpenAI互換のストリーミングAPIを呼び出し、TTFT、E2E output tok/sec、Decode output tok/sec、Aggregate output tok/secを記録します。

```bash
python3 benchmark/streaming_benchmark.py \
  --url "${VLLM_URL}/v1/chat/completions" \
  --model nvidia/DeepSeek-V4-Flash-NVFP4 \
  --header-name X-LLM-Profile \
  --header-value deepseek-v4-flash \
  --input-tokens 256 \
  --concurrency 1 \
  --warmup 2 \
  --runs 5 \
  --max-tokens 256
```

`--input-tokens`を指定すると、ツールは定型文を繰り返し、vLLMの`/tokenize`でChat Template適用後の入力長を調整します。

各リクエストには異なる`cache_salt`を設定するため、Prefix Cacheはリクエスト間で再利用されません。

測定結果と条件は[Benchmark results](docs/benchmark-results.md)に記載しています。

### 6. GPU環境の停止

検証後は、ECS TaskとGPUインスタンスを停止します。

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" \
  ./scripts/ecs-stop.sh deepseek-v4-flash
```

`ecs-stop.sh`はECS Serviceを0へ変更し、同じCompute Poolを使う別Serviceがない場合にAuto Scaling Groupも0へ変更します。
処理は、ECS Taskの停止とEC2インスタンスの終了を確認してから完了します。

停止後の状態を確認します。

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" \
  ./scripts/ecs-status.sh deepseek-v4-flash
```

## 検証環境全体の削除

NAT GatewayやApplication Load Balancerを含む検証環境全体を削除する場合は、すべてのServing Profileを停止します。

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" \
  ./scripts/ecs-stop.sh all
```

Destroy Planを確認してから適用します。

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  terraform -chdir=infra/terraform plan \
  -destroy \
  -out=deepseek-v4-flash-destroy.tfplan

aws-vault exec "${AWS_VAULT_PROFILE}" -- \
  terraform -chdir=infra/terraform apply \
  deepseek-v4-flash-destroy.tfplan
```

削除後は、AWSコンソールまたはCost Explorerで想定外のリソースと料金が残っていないことを確認してください。

## テスト

```bash
python3 -m unittest benchmark.test_streaming_benchmark
```

## ディレクトリ

```text
benchmark/         OpenAI互換APIのストリーミングベンチマーク
docs/              公開可能な測定結果
infra/terraform/   AWS環境のTerraform
runtime/vllm/      vLLM実行構成の補足
scripts/           ECS ServiceとGPU ASGの起動、停止、確認
```

## 制約

- 検証環境は`ap-northeast-1`のG7eを前提としています。
- Internal ALBのため、VPCへ到達できる環境から呼び出す必要があります。
- ASGを0へ戻すとEC2とroot EBSが削除され、次回起動時にモデルを再取得します。
- `terraform.tfstate`とモデルウェイトはリポジトリへ保存しません。
- 掲載値は特定のモデルRevision、vLLM、入力条件で得た実測値であり、性能を保証するものではありません。

## License

ソースコードは[MIT License](LICENSE)で公開します。
モデル、コンテナイメージ、AWSサービスには、それぞれの提供元の利用条件が適用されます。
