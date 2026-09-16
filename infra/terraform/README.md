# ECS on EC2 GPU PoC infrastructure

This Terraform configuration prepares model-specific vLLM services on shared, hardware-oriented Compute Pools in `ap-northeast-1`. It does not create API Gateway yet.

## Architecture

```text
Future API Gateway REST API (response streaming)
                  |
             VPC Link V2
                  |
          Internal ALB :80
             /          \
            /            \ X-LLM-Profile: deepseek-v4-flash
           v              v
  Nemotron Service   DeepSeek Service
  Task Definition    Task Definition
           |              |
    g7e-1gpu Pool     g7e-2gpu Pool
    g7e.2xlarge       g7e.12xlarge
    GPU x1            GPU x2
```

The VPC, NAT Gateway, ECS Cluster, ALB, IAM roles and task security group are shared. Compute Pools and Serving Profiles are independent:

- A Compute Pool owns a Launch Template, ASG and ECS Capacity Provider.
- A Serving Profile module owns a Task Definition, Target Group and log group.
- The root module owns each ECS Service because it joins a Serving Profile, Compute Pool and ALB route.
- A Serving Profile selects a Compute Pool, allowing multiple model profiles to share compatible hardware over time.

The repeated resources are implemented by `modules/compute-pool` and `modules/serving-profile`. Version-controlled profile definitions are in `locals.tf`.

## Current Compute Pools

| Pool | Instance | GPUs | Root EBS | ASG min/desired/max |
|---|---|---:|---:|---:|
| `g7e-1gpu` | `g7e.2xlarge` | 1 | 200 GiB | `0/0/1` |
| `g7e-2gpu` | `g7e.12xlarge` | 2 | 400 GiB | `0/0/1` |

## Current Serving Profiles

| Profile | Model | Pool | Runtime | Initial context |
|---|---|---|---|---:|
| `nemotron-nano` | `nvidia/NVIDIA-Nemotron-Nano-9B-v2-Japanese` | `g7e-1gpu` | vLLM 0.12.0 digest | 32K |
| `deepseek-v4-flash` | `nvidia/DeepSeek-V4-Flash-NVFP4` | `g7e-2gpu` | vLLM 0.26.0 digest | 16K |

DeepSeek uses model revision `48bfe38c62be14e8d82f9e3be12fe5d30a2e38c8`, TP=2 and FP8 KV cache. The first measurement used vLLM 0.25.0 in eager mode and installed part of FlashInfer 0.6.14 at Task startup to work around its incompatible 0.6.13 pin. The current profile pins vLLM 0.26.0, which ships the matching FlashInfer 0.6.14 Python, cubin and JIT packages. It captures full decode-only CUDA Graphs for batch sizes 1, 2 and 4 while leaving `torch.compile` disabled, matching the profile's `max-num-seqs=4` limit.

The first two-GPU measurement completed on 2026-08-30. At concurrency 1 and 256 forced output tokens, the eager baseline was 10.39 output tokens/s. The current decode-only CUDA Graph profile reached a median 103.95 output tokens/s under the same conditions. See `../../docs/benchmark-results.md` for the published results and measurement caveats.

The follow-up matrix uses a 16K model context so that 8K input plus 256 output tokens fit without changing the GPU, TP or batching limits. With actual 254 input tokens, concurrency 4 reached a median aggregate 297.09 output tokens/s and a median 74.62 output tokens/s per request. At 8,185 input tokens and concurrency 4, those values were 172.28 and 43.46 output tokens/s. See `../../docs/benchmark-results.md`.

The DeepSeek scheduler token budget defaults to `4096` and can be changed without editing the profile definition by setting `deepseek_v4_flash_max_num_batched_tokens`. The benchmark compared `2048`, `4096`, `8192` and `16384` while keeping the model, revision, GPU, TP, KV cache and compilation settings fixed. `4096` gave the best latency/throughput balance: at 8,185 input tokens and concurrency 4 it reduced median TTFT from 1,702.6 ms to 1,568.4 ms and raised aggregate throughput from 172.28 to 178.30 output tokens/s. Larger budgets gained at most another 1.8% aggregate throughput but materially worsened median TTFT in at least one concurrency-4 condition. See `../../docs/benchmark-results.md`.

The proven compilation default remains `mode=0` with `FULL_DECODE_ONLY`. The experiment tested vLLM compile (`mode=3`) with `FULL_AND_PIECEWISE`, but vLLM 0.26.0 reported that DeepSeek V4 does not support `torch.compile`; throughput declined in eight of nine conditions and median TTFT increased in all nine. The candidate also reduced the logged GPU KV cache capacity from 60,269 to 57,697 tokens, so it was not adopted. `deepseek_v4_flash_enable_prefill_compilation=true` remains available only to reproduce the experiment. DeepSeek V4 otherwise auto-enables breakable CUDA Graphs and resets the compilation mode to `NONE`, so the experimental switch also sets `VLLM_USE_BREAKABLE_CUDAGRAPH=0`. See `../../docs/benchmark-results.md`.

The DeepSeek profile enables one-token MTP speculative decoding by default. The benchmark found a roughly 65% to 67% draft acceptance rate and improved aggregate output throughput by 13.0% to 33.0% across the fixed 1/2/4-concurrency matrix. Speculative verification uses `concurrency * (1 + speculative tokens)` token shapes, so the profile automatically extends the decode CUDA Graph capture sizes; MTP=1 and four concurrent requests require capture size 8. Without that graph, four-concurrency throughput fell back from 298.69 to 65.78 output tok/s. With it, the same condition reached 358.41 output tok/s.

Set `deepseek_v4_flash_mtp_speculative_tokens=0` to reproduce the non-MTP baseline. Values 2 and 3 remain available for controlled comparison, but MTP=3 was not adopted: only 29.8% of all draft tokens were accepted, and its first draft position already performed slightly worse than MTP=1 in the one-concurrency tests. MTP also reduces the logged KV cache capacity from 60,269 to 50,182 tokens and vLLM 0.26.0 warns that `min_p` and `logit_bias` do not work with speculative decoding. Do not combine MTP with the prefill-compilation switch. See `../../docs/benchmark-results.md`.

The Nemotron model revision remains unpinned to preserve the configuration used for the first measurement. Pin it before a formal repeatable benchmark.

## ALB routing

Nemotron remains the default ALB target for compatibility. Select DeepSeek with an HTTP header:

```bash
curl \
  -H 'X-LLM-Profile: deepseek-v4-flash' \
  http://internal-alb.example/v1/models
```

ALB routes requests but does not start a stopped profile. A request to a profile with desired count 0 will fail until its Task is healthy.

## Deliberate defaults

- Account is restricted to the explicit `aws_account_id` value.
- Region is `ap-northeast-1`.
- Every ECS Service starts with desired count `0`.
- Every GPU ASG starts with min/desired/max `0/0/1`.
- The ECS-optimized AL2023 GPU AMI is pinned to `ami-017b6c4af9d973664`.
- Container images use multi-architecture manifest digests that include `linux/amd64`.
- The internal ALB has a 300-second idle timeout for streamed responses.
- Tasks use host IPC as recommended by the vLLM Docker recipe.
- No SSH ingress is created. Use SSM for the host and ECS Exec for the container.
- Prompt and response bodies are not added to infrastructure logs.

## Before apply

1. Confirm that all ECS Services and GPU ASGs are at zero.
2. Confirm model licenses and access requirements.
3. If a model requires authentication, create the Secrets Manager value outside Terraform and set only `huggingface_token_secret_arn`.
4. Confirm G-family On-Demand quota and current G7e capacity.
5. Review NAT Gateway, ALB, public IPv4, EBS and GPU costs.
6. Require a plan with no unexpected destroy.
7. Decide whether local Terraform state is acceptable. Configure an S3 backend before team operation.

Terraform intentionally does not manage secret values or create a public endpoint.

## Validate and plan

From the repository root:

```bash
mise exec terraform@1.14.4 -- terraform -chdir=infra/terraform init
mise exec terraform@1.14.4 -- terraform -chdir=infra/terraform fmt -check -recursive
mise exec terraform@1.14.4 -- terraform -chdir=infra/terraform validate
aws-vault exec "${AWS_VAULT_PROFILE}" -- mise exec terraform@1.14.4 -- \
  terraform -chdir=infra/terraform plan -out=llm-poc.tfplan
```

Do not apply until cost-bearing resources and the absence of unexpected destroy actions have been reviewed.

To plan one candidate for the DeepSeek prefill sweep while its Service and ASG remain at zero:

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- mise exec terraform@1.14.4 -- \
  terraform -chdir=infra/terraform plan \
  -var='deepseek_v4_flash_max_num_batched_tokens=4096'
```

Apply only the reviewed candidate, start `deepseek-v4-flash`, run the fixed benchmark matrix, and stop the profile before applying the next candidate. A candidate changes the DeepSeek Task Definition and ECS Service revision; it does not resize or start the GPU Compute Pool by itself.

To plan the prefill compilation candidate:

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- mise exec terraform@1.14.4 -- \
  terraform -chdir=infra/terraform plan \
  -var='deepseek_v4_flash_enable_prefill_compilation=true'
```

To reproduce the non-MTP baseline while keeping the current checkpoint and Compute Pool:

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- mise exec terraform@1.14.4 -- \
  terraform -chdir=infra/terraform plan \
  -var='deepseek_v4_flash_mtp_speculative_tokens=0'
```

## Start, stop and inspect

All operational scripts require an explicit profile:

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" ./scripts/ecs-start.sh nemotron-nano
aws-vault exec "${AWS_VAULT_PROFILE}" -- env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" ./scripts/ecs-status.sh nemotron-nano
aws-vault exec "${AWS_VAULT_PROFILE}" -- env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" ./scripts/ecs-exec.sh nemotron-nano
aws-vault exec "${AWS_VAULT_PROFILE}" -- env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" ./scripts/ecs-stop.sh nemotron-nano

aws-vault exec "${AWS_VAULT_PROFILE}" -- env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" ./scripts/ecs-start.sh deepseek-v4-flash
aws-vault exec "${AWS_VAULT_PROFILE}" -- env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" ./scripts/ecs-status.sh deepseek-v4-flash
aws-vault exec "${AWS_VAULT_PROFILE}" -- env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" ./scripts/ecs-stop.sh deepseek-v4-flash

aws-vault exec "${AWS_VAULT_PROFILE}" -- env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" ./scripts/ecs-status.sh all
aws-vault exec "${AWS_VAULT_PROFILE}" -- env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" ./scripts/ecs-stop.sh all
```

`ecs-start.sh` refuses to start a second profile while another is active. Deliberate concurrent GPU spend requires:

```bash
aws-vault exec "${AWS_VAULT_PROFILE}" -- env AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" ./scripts/ecs-start.sh deepseek-v4-flash --allow-concurrent
```

`ecs-stop.sh` waits for Tasks to stop. It scales a Compute Pool to zero only when no other active Serving Profile references that Pool, then waits for ASG instances to terminate.

`ecs-exec.sh` requires the AWS Session Manager plugin on the operator machine.

## Container bootstrap and ECR

There is no ECR bootstrap dependency. Both profiles pull pinned upstream vLLM images directly from Docker Hub. The empty ECR repository is reserved for a custom or mirrored image when a required fix is not available in a pinned upstream release.

Because desired count is zero after apply, creating Task Definitions and Services does not pull images or model weights and does not launch GPU instances.

## Cost and persistence behavior

Scaling an ASG to zero terminates its EC2 instance. The encrypted root EBS volume, Docker layers and Hugging Face model cache are deleted. A subsequent cold start downloads them again.

This is especially significant for the approximately 168 GB DeepSeek checkpoint. Splitting ASGs and Services removes Terraform switching time but does not remove EC2 boot, image pull, model download or model load time.

The following continue to incur charges while every ECS Service is at zero:

- NAT Gateway and its Elastic IP
- Application Load Balancer
- ECR image storage
- CloudWatch Logs storage

If cold-start time becomes material, prepare a model-specific EBS snapshot or AMI. Reusing a detached EBS volume automatically is excluded for now because it introduces AZ placement, attachment and recovery logic.

## API Gateway follow-up

After direct vLLM and ALB baseline measurements, add a REST API with response transfer mode `STREAM`, VPC Link V2 and this internal ALB as the private integration target. Measure added TTFT, request latency, disconnect rate and cost separately.
