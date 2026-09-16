locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Purpose     = "LLMHostingPoC"
    },
    var.tags,
  )

  private_subnets = {
    for index, az in var.availability_zones : az => {
      az   = az
      cidr = var.private_subnet_cidrs[index]
    }
  }

  default_compute_pool    = "g7e-1gpu"
  default_serving_profile = "nemotron-nano"

  compute_pools = {
    g7e-1gpu = {
      resource_suffix      = "gpu"
      instance_type        = "g7e.2xlarge"
      gpu_count            = 1
      root_volume_size_gib = 200
      max_size             = 1
    }

    g7e-2gpu = {
      resource_suffix      = "g7e-2gpu"
      instance_type        = "g7e.12xlarge"
      gpu_count            = 2
      root_volume_size_gib = 400
      max_size             = 1
    }
  }

  serving_profiles = {
    nemotron-nano = {
      resource_suffix        = "vllm"
      compute_pool           = "g7e-1gpu"
      model_id               = "nvidia/NVIDIA-Nemotron-Nano-9B-v2-Japanese"
      container_image        = "vllm/vllm-openai@sha256:6766ce0c459e24b76f3e9ba14ffc0442131ef4248c904efdcbf0d89e38be01fe"
      gpu_count              = 1
      task_cpu               = 7168
      task_memory_mib        = 57344
      container_entry_point  = null
      container_environment  = []
      route_header_values    = []
      listener_rule_priority = null
      container_command = [
        "--model",
        "nvidia/NVIDIA-Nemotron-Nano-9B-v2-Japanese",
        "--host",
        "0.0.0.0",
        "--port",
        tostring(var.container_port),
        "--tensor-parallel-size",
        "1",
        "--max-num-seqs",
        "64",
        "--max-model-len",
        "32768",
        "--trust-remote-code",
        "--mamba-ssm-cache-dtype",
        "float32",
      ]
    }

    deepseek-v4-flash = {
      resource_suffix = "deepseek-v4-flash"
      compute_pool    = "g7e-2gpu"
      model_id        = "nvidia/DeepSeek-V4-Flash-NVFP4"
      # v0.26.0 includes matching FlashInfer 0.6.14 Python, cubin and JIT
      # packages, removing the runtime package override required by v0.25.0.
      container_image       = "vllm/vllm-openai@sha256:ffb2d59b1c059a5bd8d781320c9f5189de8293693b7d95da54befddaa54abf52"
      gpu_count             = 2
      task_cpu              = 45056
      task_memory_mib       = 458752
      container_entry_point = null
      container_environment = var.deepseek_v4_flash_enable_prefill_compilation ? [
        {
          # DeepSeek V4 auto-enables breakable CUDA Graphs, which overrides
          # mode=3 back to NONE. Opt out only for the explicit compile test.
          name  = "VLLM_USE_BREAKABLE_CUDAGRAPH"
          value = "0"
        }
      ] : []
      route_header_values    = ["deepseek-v4-flash"]
      listener_rule_priority = 100
      container_command = concat(
        [
          "nvidia/DeepSeek-V4-Flash-NVFP4",
          "--revision",
          "48bfe38c62be14e8d82f9e3be12fe5d30a2e38c8",
          "--host",
          "0.0.0.0",
          "--port",
          tostring(var.container_port),
          "--tensor-parallel-size",
          "2",
          "--max-num-seqs",
          "4",
          "--max-num-batched-tokens",
          tostring(var.deepseek_v4_flash_max_num_batched_tokens),
          "--max-model-len",
          "16384",
          "--gpu-memory-utilization",
          "0.95",
          "--kv-cache-dtype",
          "fp8",
          "--tokenizer-mode",
          "deepseek_v4",
          "--reasoning-parser",
          "deepseek_v4",
          "--tool-call-parser",
          "deepseek_v4",
          "--enable-auto-tool-choice",
          "--trust-remote-code",
          # Keep the proven decode-only configuration as the default while
          # allowing the prefill experiment to use the same serving profile.
          "--compilation-config",
          jsonencode(
            var.deepseek_v4_flash_enable_prefill_compilation ? {
              mode                    = 3
              cudagraph_mode          = "FULL_AND_PIECEWISE"
              cudagraph_capture_sizes = [1, 2, 4]
              } : {
              mode           = 0
              cudagraph_mode = "FULL_DECODE_ONLY"
              # Speculative verification schedules one target token plus every
              # draft token per request. Capture those token shapes as well as
              # the ordinary decode shapes; otherwise MTP falls back to eager
              # execution when the verification batch exceeds four tokens.
              cudagraph_capture_sizes = distinct(concat(
                [1, 2, 4],
                var.deepseek_v4_flash_mtp_speculative_tokens > 0 ? [
                  for batch_size in [1, 2, 4] :
                  batch_size * (1 + var.deepseek_v4_flash_mtp_speculative_tokens)
                ] : [],
              ))
            }
          ),
        ],
        var.deepseek_v4_flash_mtp_speculative_tokens > 0 ? [
          "--speculative-config",
          jsonencode({
            method                 = "mtp"
            num_speculative_tokens = var.deepseek_v4_flash_mtp_speculative_tokens
          }),
        ] : [],
      )
    }
  }

  container_secrets = var.huggingface_token_secret_arn == null ? [] : [
    {
      name      = "HF_TOKEN"
      valueFrom = var.huggingface_token_secret_arn
    },
    {
      name      = "HUGGING_FACE_HUB_TOKEN"
      valueFrom = var.huggingface_token_secret_arn
    }
  ]
}
