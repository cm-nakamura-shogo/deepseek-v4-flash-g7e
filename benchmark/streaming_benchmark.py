#!/usr/bin/env python3

from __future__ import annotations

import argparse
import concurrent.futures
import json
import statistics
import threading
import time
import urllib.request
from typing import cast
from urllib.parse import urlsplit, urlunsplit


def percentile_95(values: list[float]) -> float:
    if len(values) == 1:
        return values[0]
    return statistics.quantiles(values, n=100, method="inclusive")[94]


def request_headers(args: argparse.Namespace) -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if args.header_name and args.header_value:
        headers[args.header_name] = args.header_value
    return headers


def tokenize_prompt(args: argparse.Namespace, prompt: str) -> int:
    parsed = urlsplit(args.url)
    tokenize_url = urlunsplit((parsed.scheme, parsed.netloc, "/tokenize", "", ""))
    body = {
        "model": args.model,
        "messages": [{"role": "user", "content": prompt}],
        "add_generation_prompt": True,
    }
    request = urllib.request.Request(
        tokenize_url,
        data=json.dumps(body).encode(),
        headers=request_headers(args),
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=args.timeout) as response:
        return int(json.load(response)["count"])


def build_sized_prompt(args: argparse.Namespace) -> tuple[str, int]:
    if args.input_tokens is None:
        return args.prompt, tokenize_prompt(args, args.prompt)

    suffix = "\n以上は性能測定用の入力です。内容を簡潔に要約してください。"
    unit = "This is deterministic benchmark input text. "

    def candidate(repetitions: int) -> tuple[str, int]:
        prompt = unit * repetitions + suffix
        return prompt, tokenize_prompt(args, prompt)

    low = 0
    high = max(args.input_tokens, 1)
    high_prompt, high_count = candidate(high)
    while high_count < args.input_tokens:
        low = high
        high *= 2
        high_prompt, high_count = candidate(high)

    while low + 1 < high:
        middle = (low + high) // 2
        _, count = candidate(middle)
        if count < args.input_tokens:
            low = middle
        else:
            high = middle

    low_prompt, low_count = candidate(low)
    choices = [(low_prompt, low_count), (high_prompt, high_count)]
    return min(choices, key=lambda item: abs(item[1] - args.input_tokens))


def run_request(
    args: argparse.Namespace,
    prompt: str,
    cache_salt: str,
    start_event: threading.Event,
) -> dict[str, float | int | str]:
    body = {
        "model": args.model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": args.max_tokens,
        "seed": args.seed,
        "stream": True,
        "stream_options": {"include_usage": True},
        "ignore_eos": True,
        "cache_salt": cache_salt,
    }

    request = urllib.request.Request(
        args.url,
        data=json.dumps(body).encode(),
        headers=request_headers(args),
        method="POST",
    )

    start_event.wait()
    started = time.perf_counter()
    first_token_at = None
    prompt_tokens = 0
    completion_tokens = 0
    finish_reason = ""
    generated_text = []

    with urllib.request.urlopen(request, timeout=args.timeout) as response:
        for raw_line in response:
            line = raw_line.decode("utf-8").strip()
            if not line.startswith("data: "):
                continue

            data = line[6:]
            if data == "[DONE]":
                break

            event = json.loads(data)
            usage = event.get("usage")
            if usage:
                prompt_tokens = usage.get("prompt_tokens", prompt_tokens)
                completion_tokens = usage.get("completion_tokens", completion_tokens)

            for choice in event.get("choices", []):
                delta = choice.get("delta", {})
                fragments = [
                    delta.get("reasoning_content"),
                    delta.get("reasoning"),
                    delta.get("content"),
                ]
                nonempty = [fragment for fragment in fragments if fragment]
                if nonempty:
                    if first_token_at is None:
                        first_token_at = time.perf_counter()
                    generated_text.extend(nonempty)
                if choice.get("finish_reason"):
                    finish_reason = choice["finish_reason"]

    finished = time.perf_counter()
    if first_token_at is None:
        raise RuntimeError("The stream completed without a generated token.")
    if completion_tokens <= 0:
        raise RuntimeError("The final stream event did not contain completion_tokens.")
    if prompt_tokens <= 0:
        raise RuntimeError("The final stream event did not contain prompt_tokens.")

    total_seconds = finished - started
    ttft_seconds = first_token_at - started
    decode_seconds = finished - first_token_at
    decode_tokens = max(completion_tokens - 1, 0)

    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "finish_reason": finish_reason,
        "generated_characters": len("".join(generated_text)),
        "ttft_ms": ttft_seconds * 1000,
        "total_seconds": total_seconds,
        "e2e_output_tokens_per_second": completion_tokens / total_seconds,
        "decode_output_tokens_per_second": (
            decode_tokens / decode_seconds if decode_seconds > 0 else 0
        ),
    }


def run_round(
    args: argparse.Namespace,
    prompt: str,
    phase: str,
    round_index: int,
) -> dict[str, object]:
    start_event = threading.Event()
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=args.concurrency
    ) as executor:
        futures = [
            executor.submit(
                run_request,
                args,
                prompt,
                f"{phase}-{round_index}-{request_index}-{time.time_ns()}",
                start_event,
            )
            for request_index in range(args.concurrency)
        ]
        started = time.perf_counter()
        start_event.set()
        results = [future.result() for future in futures]
        finished = time.perf_counter()

    wall_seconds = finished - started
    total_completion_tokens = sum(
        int(result["completion_tokens"]) for result in results
    )
    return {
        "phase": phase,
        "round": round_index,
        "concurrency": args.concurrency,
        "wall_seconds": wall_seconds,
        "total_completion_tokens": total_completion_tokens,
        "aggregate_output_tokens_per_second": total_completion_tokens / wall_seconds,
        "requests": results,
    }


def metric_summary(values: list[float]) -> dict[str, float]:
    return {
        "min": min(values),
        "median": statistics.median(values),
        "mean": statistics.mean(values),
        "p95": percentile_95(values),
        "max": max(values),
    }


def summarize(rounds: list[dict[str, object]]) -> dict[str, dict[str, float]]:
    results = [
        result
        for round_result in rounds
        for result in cast(list, round_result["requests"])
    ]
    metrics = [
        "prompt_tokens",
        "ttft_ms",
        "total_seconds",
        "e2e_output_tokens_per_second",
        "decode_output_tokens_per_second",
    ]
    summary = {
        "aggregate_output_tokens_per_second": metric_summary(
            [
                float(round_result["aggregate_output_tokens_per_second"])
                for round_result in rounds
            ]
        )
    }
    for metric in metrics:
        values = [float(result[metric]) for result in results]
        summary[metric] = metric_summary(values)
    return summary


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--header-name")
    parser.add_argument("--header-value")
    parser.add_argument("--prompt", default="日本の首都について簡潔に説明してください。")
    parser.add_argument("--input-tokens", type=int)
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--timeout", type=float, default=900)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.concurrency < 1:
        raise ValueError("--concurrency must be at least 1")
    if args.input_tokens is not None and args.input_tokens < 1:
        raise ValueError("--input-tokens must be at least 1")

    prompt, actual_input_tokens = build_sized_prompt(args)
    metadata = {
        "concurrency": args.concurrency,
        "url": args.url,
        "model": args.model,
        "requested_input_tokens": args.input_tokens,
        "tokenized_input_tokens": actual_input_tokens,
        "warmup_rounds": args.warmup,
        "measured_rounds": args.runs,
        "max_tokens": args.max_tokens,
        "ignore_eos": True,
        "temperature": 0,
        "seed": args.seed,
    }
    print(json.dumps({"metadata": metadata}, ensure_ascii=False), flush=True)

    for index in range(args.warmup):
        round_result = run_round(args, prompt, "warmup", index + 1)
        print(json.dumps(round_result, ensure_ascii=False), flush=True)

    rounds = []
    for index in range(args.runs):
        round_result = run_round(args, prompt, "measured", index + 1)
        rounds.append(round_result)
        print(json.dumps(round_result, ensure_ascii=False), flush=True)

    print(json.dumps({"summary": summarize(rounds)}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
