#!/usr/bin/env python3
"""BatteryOracle forecasting engine.

Reads a JSON request on stdin with the Mac's system power draw on a 15-minute grid
and returns Mistral Timestral's probabilistic forecast of future power draw.
The app turns that into battery levels, so the model never needs to know when
you plug the charger in.

Request:  {"start": unix_ts, "step": 900, "power": [W or null, ...],
           "plugged": [0/1 or null, ...], "horizon": 96, "model": "mistralai/Timestral-5M"}
Response: {"start": unix_ts, "step": 900, "levels": [0.01 ... 0.99],
           "quantiles": [[W per step] per level], "model": str, "elapsed": s}
"""
import json
import math
import os
import sys
import time

DAY, WEEK = 86400.0, 7 * 86400.0


def calendar_covariates(start, step, n):
    """Known-future covariates: smooth time of day / week plus a weekend indicator."""
    rows = [[], [], [], [], []]
    for i in range(n):
        t = start + i * step
        lt = time.localtime(t)
        local = t + lt.tm_gmtoff
        rows[0].append(math.sin(2 * math.pi * local / DAY))
        rows[1].append(math.cos(2 * math.pi * local / DAY))
        rows[2].append(math.sin(2 * math.pi * local / WEEK))
        rows[3].append(math.cos(2 * math.pi * local / WEEK))
        rows[4].append(1.0 if lt.tm_wday >= 5 else 0.0)
    return rows


def load_model(name):
    from timestral import TimestralForecaster
    try:
        return TimestralForecaster.from_pretrained(name, local_files_only=True)
    except Exception:
        return TimestralForecaster.from_pretrained(name)


def main():
    t0 = time.perf_counter()
    req = json.load(sys.stdin)
    import numpy as np
    import torch

    torch.set_num_threads(max(1, min(2, os.cpu_count() or 1)))

    nan = float("nan")
    power = np.array([nan if v is None else v for v in req["power"]], dtype=np.float32)
    plugged = np.array([nan if v is None else v for v in req["plugged"]], dtype=np.float32)
    start, step, horizon = req["start"], req["step"], int(req.get("horizon", 96))
    name = req.get("model", "mistralai/Timestral-5M")

    keep = min(len(power), 32768)
    power, plugged = power[-keep:], plugged[-keep:]
    start += (len(req["power"]) - keep) * step

    known = np.array(calendar_covariates(start, step, keep + horizon), dtype=np.float32)
    model = load_model(name)
    with torch.inference_mode():
        fc = model.forecast(
            power[None, None, :],
            prediction_length=horizon,
            past_covariates=plugged[None, None, :],
            known_covariates=known[None, :, :],
        )

    q = np.clip(np.asarray(fc.quantiles)[0, 0], 0, None)  # (horizon, levels)
    json.dump({
        "start": start + keep * step,
        "step": step,
        "levels": [float(x) for x in fc.quantile_levels],
        "quantiles": np.round(q.T, 3).tolist(),
        "model": name.split("/")[-1],
        "elapsed": round(time.perf_counter() - t0, 3),
    }, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # report to the app instead of crashing silently
        json.dump({"error": f"{type(e).__name__}: {e}"}, sys.stdout)
        sys.exit(1)
