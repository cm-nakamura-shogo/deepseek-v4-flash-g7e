from __future__ import annotations

import threading
import time
import unittest
from argparse import Namespace
from unittest import mock

from benchmark import streaming_benchmark


def fake_result() -> dict[str, float | int | str]:
    return {
        "prompt_tokens": 256,
        "completion_tokens": 256,
        "finish_reason": "length",
        "generated_characters": 256,
        "ttft_ms": 100.0,
        "total_seconds": 2.5,
        "e2e_output_tokens_per_second": 102.4,
        "decode_output_tokens_per_second": 106.0,
    }


class StreamingBenchmarkTest(unittest.TestCase):
    def test_run_round_starts_requests_concurrently(self) -> None:
        args = Namespace(concurrency=4)

        def fake_run_request(
            args: Namespace,
            prompt: str,
            cache_salt: str,
            start_event: threading.Event,
        ) -> dict[str, float | int | str]:
            start_event.wait()
            time.sleep(0.05)
            return fake_result()

        with mock.patch.object(
            streaming_benchmark, "run_request", side_effect=fake_run_request
        ):
            result = streaming_benchmark.run_round(args, "prompt", "measured", 1)

        self.assertLess(float(result["wall_seconds"]), 0.15)
        self.assertEqual(result["total_completion_tokens"], 1024)
        self.assertEqual(len(result["requests"]), 4)

    def test_summarize_includes_aggregate_and_per_request_metrics(self) -> None:
        rounds = [
            {
                "aggregate_output_tokens_per_second": 200.0,
                "requests": [fake_result(), fake_result()],
            },
            {
                "aggregate_output_tokens_per_second": 220.0,
                "requests": [fake_result(), fake_result()],
            },
        ]

        summary = streaming_benchmark.summarize(rounds)

        self.assertEqual(
            summary["aggregate_output_tokens_per_second"]["median"], 210.0
        )
        self.assertEqual(summary["prompt_tokens"]["median"], 256.0)
        self.assertEqual(summary["ttft_ms"]["median"], 100.0)


if __name__ == "__main__":
    unittest.main()
