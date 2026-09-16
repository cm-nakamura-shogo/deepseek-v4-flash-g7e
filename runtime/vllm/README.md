# vLLM runtime

The PoC uses upstream `vllm/vllm-openai` images pinned by multi-architecture manifest digest in the ECS task definitions. Nemotron and DeepSeek may use different vLLM releases because their supported execution paths differ.

DeepSeek initially required a runtime FlashInfer override on vLLM 0.25.0. vLLM 0.26.0 includes the matching FlashInfer 0.6.14 Python, cubin and JIT cache packages, so the profile now uses that upstream image directly without installing packages at Task startup.

The DeepSeek profile uses full decode-only CUDA Graphs for batch sizes 1, 2 and 4. `torch.compile` remains disabled so the configuration is limited to the optimization that was measured on G7e. See `../../docs/benchmark-results.md` for the benchmark result.

Add a custom `Dockerfile` only when a required patch is unavailable in a pinned upstream release. Do not bake model weights or Hugging Face tokens into an image. Push custom images to the ECR repository created by Terraform and set `container_image` to an immutable image digest.
