#!/usr/bin/env python3
"""Generate screening artifacts for the voice-link open-source toolkit.

The main simulation scripts produce the baseline link results. This module
fills the review-driven gaps from the step-sequence revision plan with reproducible
CSV tables and manuscript figures:

* residual S-band Doppler and rain-margin sensitivity for the 2.4 kbps bearer;
* Markov transition consistency checks against the target LOS probabilities;
* public D2C inverse-anchor checks in the measurement space available from the
  public Starlink D2C paper;
"""
from __future__ import annotations

import csv
import json
import math
import shutil
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.ticker import PercentFormatter
import numpy as np

try:
    from .paths import GEO_SATPHONE_DIR, SCREENING_ANALYSIS_DIR, SHARED_FIGURES_DIR, SCREENING_PLOTS_DIR
except ImportError:  # Allow direct execution from this directory during debugging.
    from paths import GEO_SATPHONE_DIR, SCREENING_ANALYSIS_DIR, SHARED_FIGURES_DIR, SCREENING_PLOTS_DIR

PLOTS = SHARED_FIGURES_DIR
GEO_OUT = GEO_SATPHONE_DIR
VOICE_LINK_PLOTS = SCREENING_PLOTS_DIR
SCREENING_OUT = SCREENING_ANALYSIS_DIR
for path in [PLOTS, GEO_OUT, VOICE_LINK_PLOTS, SCREENING_OUT]:
    path.mkdir(parents=True, exist_ok=True)

for fp in [
    "C:/Windows/Fonts/msyh.ttc",
    "C:/Windows/Fonts/simhei.ttf",
    "C:/Windows/Fonts/simsun.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Medium.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
]:
    if Path(fp).exists():
        font_manager.fontManager.addfont(fp)
        font_name = font_manager.FontProperties(fname=fp).get_name()
        plt.rcParams["font.family"] = font_name
        plt.rcParams["font.sans-serif"] = [font_name, "DejaVu Sans"]
        break
plt.rcParams["axes.unicode_minus"] = False
plt.rcParams["pdf.fonttype"] = 42
plt.rcParams["ps.fonttype"] = 42
plt.rcParams.update(
    {
        "font.size": 9,
        "axes.labelsize": 9,
        "axes.titlesize": 9,
        "legend.fontsize": 8,
        "xtick.labelsize": 8,
        "ytick.labelsize": 8,
        "figure.dpi": 150,
    }
)

COLORS = {
    "mc": "#D55E00",
    "exact": "#0072B2",
    "lb": "#6A3D9A",
    "ub": "#4D4D4D",
    "accent": "#009E73",
    "warn": "#E69F00",
    "bad": "#C44E52",
}

SCENARIOS = [
    {
        "key": "open_plain",
        "scenario_model_key": "open",
        "label": "Open plain",
        "p_los": 0.96,
        "sigma_db": 2.5,
        "theta_mean": 8.0,
        "nlos_loss_db": 8.0,
        "p_ll": 0.985,
        "dwell_class": "open LMS, long LOS / short NLOS",
    },
    {
        "key": "forest_edge",
        "scenario_model_key": "suburban",
        "label": "Forest edge",
        "p_los": 0.78,
        "sigma_db": 5.0,
        "theta_mean": 13.0,
        "nlos_loss_db": 14.0,
        "p_ll": 0.965,
        "dwell_class": "vegetation edge, intermittent NLOS",
    },
    {
        "key": "canyon_valley",
        "scenario_model_key": "urban",
        "label": "Canyon valley",
        "p_los": 0.58,
        "sigma_db": 8.0,
        "theta_mean": 22.0,
        "nlos_loss_db": 22.0,
        "p_ll": 0.930,
        "dwell_class": "terrain-blocked LMS / urban-proxy tail",
    },
    {
        "key": "moving_trail",
        "scenario_model_key": "car",
        "label": "Moving trail",
        "p_los": 0.65,
        "sigma_db": 7.0,
        "theta_mean": 26.0,
        "nlos_loss_db": 18.0,
        "p_ll": 0.900,
        "dwell_class": "mobility/posture driven transitions",
    },
    {
        "key": "tent_shelter",
        "scenario_model_key": "indoor_window",
        "label": "Tent/shelter",
        "p_los": 0.35,
        "sigma_db": 9.0,
        "theta_mean": 32.0,
        "nlos_loss_db": 26.0,
        "p_ll": 0.880,
        "dwell_class": "shelter-edge / persistent NLOS",
    },
]

APP_PROFILES = {
    "text_10kbps": {"label": "10 kbps text", "rate_bps": 10_000.0},
    "voice_text_100kbps": {"label": "100 kbps voice+text", "rate_bps": 100_000.0},
    "rich_1mbps": {"label": "1 Mbps rich stress", "rate_bps": 1_000_000.0},
}

REFERENCE_THRESHOLDS_DB: dict[float, float] = {}
REFERENCE_AVAILABILITY: dict[tuple[str, float], dict[str, float]] = {}
PYTHON_BASELINE_TOLERANCE = 0.02


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(rows[0].keys())
    for row in rows[1:]:
        for key in row.keys():
            if key not in fieldnames:
                fieldnames.append(key)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def copy_to_paper_plots(stem: str, paper_dir: Path) -> None:
    for suffix in [".png", ".pdf"]:
        src = PLOTS / f"{stem}{suffix}"
        if src.exists():
            shutil.copy2(src, paper_dir / src.name)


def save_plot(fig: plt.Figure, stem: str, *, paper_dir: Path | None = None, tight: bool = True) -> None:
    if tight:
        fig.tight_layout()
    fig.savefig(PLOTS / f"{stem}.png", dpi=220, bbox_inches="tight", pad_inches=0.05)
    fig.savefig(PLOTS / f"{stem}.pdf", bbox_inches="tight", pad_inches=0.05)
    plt.close(fig)
    if paper_dir is not None:
        copy_to_paper_plots(stem, paper_dir)


def polish_axes(ax, grid_axis: str = "y") -> None:
    ax.grid(True, axis=grid_axis, color="#D9D9D9", linewidth=0.6, alpha=0.85)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)


def fspl_db(distance_km: float, freq_mhz: float) -> float:
    return 32.44 + 20.0 * math.log10(distance_km) + 20.0 * math.log10(freq_mhz)


def noise_dbm(bw_hz: float, nf_db: float = 4.0, temp_k: float = 290.0) -> float:
    return -228.6 + 10.0 * math.log10(temp_k) + 10.0 * math.log10(bw_hz) + nf_db + 30.0


def orientation_gain_db(theta_deg: np.ndarray | float, g_peak_dbi: float = 2.0, exponent: float = 1.7) -> np.ndarray:
    theta = np.minimum(np.abs(theta_deg), 85.0)
    gain_drop = 10.0 * exponent * np.log10(np.maximum(np.cos(np.radians(theta)), 1e-3))
    return np.maximum(-10.0, g_peak_dbi + gain_drop)


def ul_snr_db(bw_hz: float, theta_deg: np.ndarray | float, pt_dbm: float = 34.0) -> np.ndarray:
    rx_dbm = pt_dbm + orientation_gain_db(theta_deg) + 40.0 - fspl_db(36000.0, 1995.0) - 0.5 - 1.0
    return rx_dbm - noise_dbm(bw_hz, nf_db=2.0)


def exact_lognormal_capacity(gamma0_db: float, sigma_db: float, eps: float, added_loss_db: float = 0.0) -> float:
    # Acklam-style inverse-normal constants are overkill here; eps is fixed.
    # Phi^{-1}(0.01) to sufficient precision for reproducible tables.
    z_eps = -2.3263478740408408
    sigma_nat = math.log(10.0) / 10.0 * sigma_db
    gamma0 = 10.0 ** ((gamma0_db - added_loss_db) / 10.0)
    return math.log2(1.0 + gamma0 * math.exp(sigma_nat * z_eps))


def uncoded_qpsk_ber(ebn0_db: float) -> float:
    eb = 10.0 ** (ebn0_db / 10.0)
    return 0.5 * math.erfc(math.sqrt(eb))


def generate_doppler_rain() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    symbol_rate_hz = 1200.0
    # Trackers close over a few symbols; a 5 ms coherent window exposes the
    # residual-frequency sensitivity requested by the review plan.
    for coherent_ms, tracker_case in [(1.0, "tracked"), (5.0, "slow_tracking")]:
        t_coh = coherent_ms / 1000.0
        for fd_hz in [0, 20, 50, 75, 100, 150, 200]:
            sinc = abs(np.sinc(fd_hz * t_coh))
            loss_db = -20.0 * math.log10(max(sinc, 1e-6))
            for ebn0_ref_db in [0.7, 3.0, 6.0]:
                ber = uncoded_qpsk_ber(ebn0_ref_db + 4.2 - loss_db)
                rows.append(
                    {
                        "mode": "doppler_ber",
                        "tracker_case": tracker_case,
                        "coherent_window_ms": coherent_ms,
                        "residual_doppler_hz": fd_hz,
                        "symbol_rate_hz": symbol_rate_hz,
                        "ebn0_ref_db": ebn0_ref_db,
                        "coherent_loss_db": loss_db,
                        "coded_ber_proxy": max(ber, 1e-8),
                    }
                )

    gamma0_db = 11.706656016154298
    sigma_db = 6.0
    rain_cases = [
        ("clear", "none", 0.0),
        ("temperate_0p01", "ITU-R P.618/P.838 temperate high-percentile proxy", 0.5),
        ("humid_0p01", "humid mid-latitude proxy", 1.0),
        ("tropical_0p01", "ITU-R P.618/P.838 tropical severe proxy", 2.0),
    ]
    for case, note, loss_db in rain_cases:
        rows.append(
            {
                "mode": "rain_capacity",
                "tracker_case": case,
                "coherent_window_ms": "",
                "residual_doppler_hz": 0,
                "symbol_rate_hz": symbol_rate_hz,
                "ebn0_ref_db": "",
                "coherent_loss_db": loss_db,
                "c_0p01_bit_per_s_hz": exact_lognormal_capacity(gamma0_db, sigma_db, 0.01, loss_db),
                "rain_note": note,
            }
        )

    write_csv(GEO_OUT / "doppler_rain_sensitivity.csv", rows)

    fig, axes = plt.subplots(1, 2, figsize=(7.4, 3.55))
    for case, color, linestyle in [
        ("tracked", COLORS["exact"], "-"),
        ("slow_tracking", COLORS["bad"], "--"),
    ]:
        sub = [
            r
            for r in rows
            if r["mode"] == "doppler_ber" and r["tracker_case"] == case and abs(float(r["ebn0_ref_db"]) - 3.0) < 1e-9
        ]
        axes[0].semilogy(
            [float(r["residual_doppler_hz"]) for r in sub],
            [float(r["coded_ber_proxy"]) for r in sub],
            marker="o",
            markersize=3,
            linewidth=1.7,
            linestyle=linestyle,
            color=color,
            label=case.replace("_", " "),
        )
    axes[0].set_xlabel("Residual Doppler (Hz)")
    axes[0].set_ylabel("BER proxy")
    axes[0].set_ylim(1e-8, 1e-1)
    axes[0].set_title("(a) 2.4 kbps bearer Doppler sensitivity")
    polish_axes(axes[0], "y")
    axes[0].legend(frameon=False, loc="lower right")

    rain = [r for r in rows if r["mode"] == "rain_capacity"]
    labels = ["clear", "temp.", "humid", "tropical"]
    x = np.arange(len(rain))
    axes[1].bar(
        x,
        [float(r["c_0p01_bit_per_s_hz"]) for r in rain],
        color=[COLORS["accent"], COLORS["exact"], COLORS["warn"], COLORS["bad"]],
        width=0.58,
    )
    axes[1].set_xticks(x, labels)
    axes[1].set_ylabel(r"$C_{0.01}$ (bit/s/Hz)")
    axes[1].set_title("(b) S-band rain-margin shift")
    polish_axes(axes[1])
    save_plot(fig, "geo_satphone_doppler_rain_sensitivity", paper_dir=VOICE_LINK_PLOTS)
    return rows


def retuned_p_nn(p_los: float, p_ll: float) -> float:
    return (1.0 - 2.0 * p_los + p_los * p_ll) / (1.0 - p_los)


def generate_markov_alignment() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for sp in SCENARIOS:
        p_los = float(sp["p_los"])
        p_ll = float(sp["p_ll"])
        p_nn = retuned_p_nn(p_los, p_ll)
        stationary = (1.0 - p_nn) / (2.0 - p_ll - p_nn)
        rows.append(
            {
                "scenario": sp["key"],
                "scenario_label": sp["label"],
                "target_p_los": p_los,
                "p_ll": p_ll,
                "retuned_p_nn": p_nn,
                "stationary_p_los": stationary,
                "abs_stationary_error": abs(stationary - p_los),
                "mean_los_dwell_s": 1.0 / (1.0 - p_ll),
                "mean_nlos_dwell_s": 1.0 / (1.0 - p_nn),
                "source_basis": sp["dwell_class"],
            }
        )
    write_csv(GEO_OUT / "markov_stationary_alignment.csv", rows)

    labels = [r["scenario_label"] for r in rows]
    x = np.arange(len(rows))
    fig, ax = plt.subplots(figsize=(6.9, 3.55))
    ax.bar(x - 0.18, [float(r["target_p_los"]) for r in rows], 0.36, color=COLORS["exact"], label="target")
    ax.bar(x + 0.18, [float(r["stationary_p_los"]) for r in rows], 0.36, color=COLORS["accent"], label="stationary")
    ax.set_xticks(x, labels, rotation=18, ha="right")
    ax.set_ylabel("LOS probability")
    ax.set_ylim(0, 1.05)
    ax.yaxis.set_major_formatter(PercentFormatter(xmax=1.0, decimals=0))
    ax.set_title("Markov transition retuning preserves target LOS probability")
    polish_axes(ax)
    ax.legend(frameon=False, loc="upper right")
    save_plot(fig, "geo_satphone_markov_stationary_alignment", paper_dir=VOICE_LINK_PLOTS)
    return rows


def generate_public_inverse_alignment() -> list[dict[str, object]]:
    bandwidth_gain_db = 10.0 * math.log10(5e6 / 31.25e3)
    public_rsrp_gap_db = 24.0
    residual_gap_db = public_rsrp_gap_db - bandwidth_gain_db
    pcs_to_sband_db = 20.0 * math.log10(2185.0 / 1990.0)
    public_rate_bps = 3_000_000.0
    rows: list[dict[str, object]] = [
        {
            "check": "median_rsrp_gap",
            "public_anchor": "Starlink D2C median RSRP about 24 dB below terrestrial cellular",
            "model_mapping": "5 MHz to 31.25 kHz thermal-noise reduction",
            "public_value": public_rsrp_gap_db,
            "model_value": bandwidth_gain_db,
            "residual_or_error": residual_gap_db,
            "unit": "dB",
        },
        {
            "check": "pcs_to_sband_frequency_translation",
            "public_anchor": "PCS-band public D2C measurements translated to S-band path loss",
            "model_mapping": "20log10(2185/1990)",
            "public_value": 0.0,
            "model_value": pcs_to_sband_db,
            "residual_or_error": pcs_to_sband_db,
            "unit": "dB",
        },
        {
            "check": "outdoor_rate_scale_voice",
            "public_anchor": "announced outdoor DS2D data-service scale about 3 Mbps per beam",
            "model_mapping": "rate gap to 2.4 kbps voice bearer",
            "public_value": public_rate_bps,
            "model_value": 2400.0,
            "residual_or_error": 10.0 * math.log10(public_rate_bps / 2400.0),
            "unit": "dB rate ratio",
        },
        {
            "check": "outdoor_rate_scale_voice_text",
            "public_anchor": "announced outdoor DS2D data-service scale about 3 Mbps per beam",
            "model_mapping": "rate gap to 100 kbps voice+text service",
            "public_value": public_rate_bps,
            "model_value": 100_000.0,
            "residual_or_error": 10.0 * math.log10(public_rate_bps / 100_000.0),
            "unit": "dB rate ratio",
        },
    ]
    mae_db = (abs(residual_gap_db) + abs(pcs_to_sband_db)) / 2.0
    rows.append(
        {
            "check": "measurement_space_mae",
            "public_anchor": "aggregate public D2C anchors with directly comparable dB quantities",
            "model_mapping": "mean absolute residual over RSRP and frequency-translation checks",
            "public_value": "",
            "model_value": "",
            "residual_or_error": mae_db,
            "unit": "dB",
        }
    )
    write_csv(GEO_OUT / "public_d2c_inverse_alignment.csv", rows)

    fig, ax = plt.subplots(figsize=(6.6, 3.45))
    labels = ["RSRP residual", "PCS->S", "MAE"]
    vals = [residual_gap_db, pcs_to_sband_db, mae_db]
    ax.bar(np.arange(len(vals)), vals, color=[COLORS["exact"], COLORS["warn"], COLORS["accent"]], width=0.56)
    ax.axhline(0.0, color="#4D4D4D", linewidth=0.8)
    ax.set_xticks(np.arange(len(vals)), labels)
    ax.set_ylabel("Measurement-space residual (dB)")
    ax.set_title("Public D2C inverse-anchor residuals")
    polish_axes(ax)
    for i, val in enumerate(vals):
        ax.text(i, val + 0.08, f"{val:.2f}", ha="center", va="bottom", fontsize=8)
    save_plot(fig, "geo_satphone_public_d2c_inverse_alignment", paper_dir=VOICE_LINK_PLOTS)
    return rows


def generate_voice_availability_band() -> list[dict[str, object]]:
    samples = voice_link_common_random_samples()
    rows: list[dict[str, object]] = []
    for sp in VOICE_LINK_SCENARIOS:
        scenario = str(sp["key"])
        sample = samples[scenario]
        canonical = canonical_voice_metric(scenario, 2400.0)
        minus_1, _, _ = voice_link_availability(sp, sample, threshold_delta_db=-1.0)
        plus_1, _, _ = voice_link_availability(sp, sample, threshold_delta_db=1.0)
        rows.append(
            {
                "scenario": sp.get("scenario_key", scenario),
                "scenario_model_key": scenario,
                "scenario_label": sp["label"],
                "availability_minus_1db": minus_1,
                "availability_baseline": canonical["availability"],
                "availability_plus_1db": plus_1,
                "threshold_ebn0_db": canonical["threshold_ebn0_db"],
                "one_sigma_proxy": "PHY-threshold/posture calibration +/-1 dB",
            }
        )
    write_csv(GEO_OUT / "voice_availability_band.csv", rows)

    labels = [r["scenario_label"] for r in rows]
    x = np.arange(len(rows))
    baseline = np.array([float(r["availability_baseline"]) for r in rows])
    lower = np.maximum(0.0, baseline - np.array([float(r["availability_plus_1db"]) for r in rows]))
    upper = np.maximum(0.0, np.array([float(r["availability_minus_1db"]) for r in rows]) - baseline)
    fig, ax = plt.subplots(figsize=(6.9, 3.55))
    ax.errorbar(
        x,
        baseline,
        yerr=np.vstack([lower, upper]),
        fmt="o",
        color=COLORS["exact"],
        ecolor=COLORS["warn"],
        elinewidth=1.5,
        capsize=3,
    )
    ax.set_xticks(x, labels, rotation=18, ha="right")
    ax.set_ylabel("2.4 kbps voice availability")
    ax.set_ylim(0, 1.05)
    ax.yaxis.set_major_formatter(PercentFormatter(xmax=1.0, decimals=0))
    ax.set_title("Voice availability +/-1 dB calibration band")
    polish_axes(ax)
    save_plot(fig, "geo_satphone_voice_availability_band", paper_dir=VOICE_LINK_PLOTS)
    return rows


def generate_reference_voice_availability_plot() -> list[dict[str, object]]:
    rows = read_csv(GEO_OUT / "voice_availability.csv")
    scenarios = [str(sp["key"]) for sp in VOICE_LINK_SCENARIOS]
    labels = [str(sp["label"]) for sp in VOICE_LINK_SCENARIOS]
    rates = sorted(REFERENCE_THRESHOLDS_DB)
    x = np.arange(len(scenarios))
    width = 0.23
    styles = {
        1200.0: {"color": COLORS["accent"], "alpha": 1.0, "hatch": "", "edgecolor": "none"},
        2400.0: {"color": COLORS["exact"], "alpha": 1.0, "hatch": "", "edgecolor": "none"},
        4000.0: {"color": "#BDBDBD", "alpha": 0.65, "hatch": "//", "edgecolor": "#666666"},
    }
    fig, ax = plt.subplots(figsize=(7.2, 3.9))
    for i, rb in enumerate(rates):
        vals = [
            next(float(r["availability"]) for r in rows if r["scenario"] == sc and abs(float(r["voice_rate_bps"]) - rb) < 1e-9)
            for sc in scenarios
        ]
        ax.bar(x + (i - 1) * width, vals, width, label=f"{rb/1000:.1f} kbps", **styles.get(rb, {}))
    ax.set_xticks(x, labels, rotation=18, ha="right")
    ax.set_ylim(0, 1.05)
    ax.yaxis.set_major_formatter(PercentFormatter(xmax=1.0, decimals=0))
    ax.set_ylabel("Voice availability")
    ax.set_title("PHY-calibrated MATLAB/Simulink voice availability")
    polish_axes(ax)
    ax.legend(frameon=False, ncol=3, loc="upper center", bbox_to_anchor=(0.5, 1.18), borderaxespad=0.0)
    save_plot(fig, "geo_satphone_voice_availability", paper_dir=VOICE_LINK_PLOTS)
    return rows


VOICE_LINK_SCENARIOS = [
    {"key": "open", "label": "Open plain", "sigma_db": 2.5, "theta_mean": 8.0, "theta_std": 5.0, "extra_nlos_db": 8.0},
    {"key": "suburban", "label": "Forest edge", "sigma_db": 4.0, "theta_mean": 13.0, "theta_std": 8.0, "extra_nlos_db": 12.0},
    {"key": "urban", "label": "Canyon valley", "sigma_db": 7.0, "theta_mean": 20.0, "theta_std": 12.0, "extra_nlos_db": 18.0},
    {"key": "car", "label": "Moving trail", "sigma_db": 6.0, "theta_mean": 25.0, "theta_std": 14.0, "extra_nlos_db": 20.0},
    {"key": "indoor_window", "label": "Tent/shelter", "sigma_db": 9.0, "theta_mean": 30.0, "theta_std": 16.0, "extra_nlos_db": 26.0},
]


def configure_voice_link_reference_inputs() -> None:
    baseline_path = GEO_OUT / "voice_link_reference_baseline.json"
    availability_path = GEO_OUT / "voice_availability.csv"
    if not baseline_path.exists():
        raise SystemExit(f"Missing voice-link reference service baseline: {baseline_path}")
    if not availability_path.exists():
        raise SystemExit(f"Missing voice-link reference availability CSV: {availability_path}")
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    if baseline.get("reference_path") is not True or baseline.get("source") != "matlab_simulink_phy_threshold":
        raise SystemExit("voice-link service baseline is not from the MATLAB/Simulink reference path.")

    global SCENARIOS, VOICE_LINK_SCENARIOS, REFERENCE_THRESHOLDS_DB, REFERENCE_AVAILABILITY
    REFERENCE_THRESHOLDS_DB = {float(k): float(v) for k, v in baseline["thresholds"].items()}

    configured_scenarios: list[dict[str, object]] = []
    configured_availability_scenarios: list[dict[str, object]] = []
    for sc in baseline["scenarios"]:
        scenario = {
            "key": str(sc["scenario_key"]),
            "scenario_model_key": str(sc["scenario_model_key"]),
            "label": str(sc["label"]),
            "p_los": float(sc["p_los"]),
            "sigma_db": float(sc["sigma_db"]),
            "theta_mean": float(sc["theta_mean_deg"]),
            "theta_std": float(sc["theta_std_deg"]),
            "nlos_loss_db": float(sc["nlos_loss_db"]),
            "p_ll": float(sc["p_ll"]),
            "dwell_class": "MATLAB/Simulink co-sim inherited scenario",
        }
        configured_scenarios.append(scenario)
        configured_availability_scenarios.append(
            {
                "key": scenario["scenario_model_key"],
                "scenario_key": scenario["key"],
                "label": scenario["label"],
                "p_los": scenario["p_los"],
                "sigma_db": scenario["sigma_db"],
                "theta_mean": scenario["theta_mean"],
                "theta_std": scenario["theta_std"],
                "extra_nlos_db": scenario["nlos_loss_db"],
            }
        )
    SCENARIOS = configured_scenarios
    VOICE_LINK_SCENARIOS = configured_availability_scenarios

    REFERENCE_AVAILABILITY = {}
    for row in read_csv(availability_path):
        key = (row["scenario"], float(row["voice_rate_bps"]))
        REFERENCE_AVAILABILITY[key] = {
            "availability": float(row["availability"]),
            "p10_ebn0_db": float(row["p10_ebn0_db"]),
            "median_ebn0_db": float(row["median_ebn0_db"]),
            "threshold_ebn0_db": float(row["threshold_ebn0_db"]),
        }

    expected = {(str(s["key"]), rate) for s in VOICE_LINK_SCENARIOS for rate in REFERENCE_THRESHOLDS_DB}
    missing = sorted(expected - set(REFERENCE_AVAILABILITY))
    if missing:
        raise SystemExit(f"voice-link reference availability table is missing rows: {missing}")


def voice_threshold_db(rate_bps: float) -> float:
    if rate_bps not in REFERENCE_THRESHOLDS_DB:
        raise SystemExit(f"Missing reference PHY threshold for {rate_bps} bps")
    return REFERENCE_THRESHOLDS_DB[rate_bps]


def canonical_voice_metric(scenario_model_key: str, rate_bps: float = 2400.0) -> dict[str, float]:
    key = (scenario_model_key, rate_bps)
    if key not in REFERENCE_AVAILABILITY:
        raise SystemExit(f"Missing canonical voice metric for {scenario_model_key} at {rate_bps} bps")
    return REFERENCE_AVAILABILITY[key]


def voice_link_plos_elevation(elev_deg: float, scenario: str) -> float:
    shift = {"open": 12.0, "suburban": 18.0, "urban": 26.0, "car": 30.0, "indoor_window": 38.0}[scenario]
    scale = {"open": 6.0, "suburban": 7.0, "urban": 8.0, "car": 8.5, "indoor_window": 9.5}[scenario]
    cap = {"open": 0.98, "suburban": 0.92, "urban": 0.78, "car": 0.60, "indoor_window": 0.38}[scenario]
    return cap / (1.0 + math.exp(-(elev_deg - shift) / scale))


def voice_link_common_random_samples(seed: int = 20260608, n_mc: int = 200_000) -> dict[str, dict[str, np.ndarray]]:
    rng = np.random.default_rng(seed)
    samples: dict[str, dict[str, np.ndarray]] = {}
    for sp in VOICE_LINK_SCENARIOS:
        theta = np.clip(rng.normal(float(sp["theta_mean"]), float(sp["theta_std"]), n_mc), 0.0, 80.0)
        los_uniform = rng.random(n_mc)
        shadow_normal = rng.normal(0.0, 1.0, n_mc)
        samples[str(sp["key"])] = {
            "theta": theta,
            "los_uniform": los_uniform,
            "shadow_normal": shadow_normal,
        }
    return samples


def voice_link_availability(
    sp: dict[str, object],
    sample: dict[str, np.ndarray],
    *,
    p_los_delta: float = 0.0,
    nlos_delta_db: float = 0.0,
    sigma_delta_db: float = 0.0,
    theta_shift_deg: float = 0.0,
    added_loss_db: float = 0.0,
    threshold_delta_db: float = 0.0,
    force_single_state: bool = False,
) -> tuple[float, float, float]:
    metrics = voice_link_metrics(
        sp,
        sample,
        p_los_delta=p_los_delta,
        nlos_delta_db=nlos_delta_db,
        sigma_delta_db=sigma_delta_db,
        theta_shift_deg=theta_shift_deg,
        added_loss_db=added_loss_db,
        threshold_delta_db=threshold_delta_db,
        force_single_state=force_single_state,
    )
    return (
        float(metrics["availability"]),
        float(metrics["p10_ebn0_db"]),
        float(metrics["median_ebn0_db"]),
    )


def voice_link_screening_samples(
    sp: dict[str, object],
    sample: dict[str, np.ndarray],
    *,
    p_los_delta: float = 0.0,
    nlos_delta_db: float = 0.0,
    sigma_delta_db: float = 0.0,
    theta_shift_deg: float = 0.0,
    added_loss_db: float = 0.0,
    force_single_state: bool = False,
) -> tuple[np.ndarray, np.ndarray]:
    bw_hz = 31.25e3
    rb_bps = 2400.0
    theta = np.clip(sample["theta"] + theta_shift_deg, 0.0, 80.0)
    gt = orientation_gain_db(theta)
    snr_det = 34.0 + gt + 40.0 - fspl_db(36000.0, 1995.0) - 0.5 - 1.0 - noise_dbm(bw_hz, nf_db=2.0) - added_loss_db
    sigma_db = max(0.1, float(sp["sigma_db"]) + sigma_delta_db)
    shadow = sample["shadow_normal"] * sigma_db
    if force_single_state:
        nlos_loss = 0.0
    else:
        p_los = float(sp.get("p_los", voice_link_plos_elevation(45.0, str(sp["key"]))))
        p_los = float(np.clip(p_los + p_los_delta, 0.01, 0.99))
        los_state = sample["los_uniform"] < p_los
        nlos_loss = (~los_state) * max(0.0, float(sp["extra_nlos_db"]) + nlos_delta_db)
    snr_db = snr_det - shadow - nlos_loss
    ebn0 = snr_db + 10.0 * math.log10(bw_hz / rb_bps)
    return snr_db, ebn0


def voice_link_metrics(
    sp: dict[str, object],
    sample: dict[str, np.ndarray],
    *,
    p_los_delta: float = 0.0,
    nlos_delta_db: float = 0.0,
    sigma_delta_db: float = 0.0,
    theta_shift_deg: float = 0.0,
    added_loss_db: float = 0.0,
    threshold_delta_db: float = 0.0,
    force_single_state: bool = False,
) -> dict[str, float]:
    snr_db, ebn0 = voice_link_screening_samples(
        sp,
        sample,
        p_los_delta=p_los_delta,
        nlos_delta_db=nlos_delta_db,
        sigma_delta_db=sigma_delta_db,
        theta_shift_deg=theta_shift_deg,
        added_loss_db=added_loss_db,
        force_single_state=force_single_state,
    )
    threshold_db = voice_threshold_db(2400.0) + threshold_delta_db
    capacity = np.log2(1.0 + 10.0 ** (snr_db / 10.0))
    return {
        "availability": float(np.mean(ebn0 >= threshold_db)),
        "p10_ebn0_db": float(np.quantile(ebn0, 0.10)),
        "median_ebn0_db": float(np.median(ebn0)),
        "c0p01_bit_per_s_hz": float(np.quantile(capacity, 0.01)),
    }


def generate_screening_baseline_comparison(seed: int = 20260608, n_mc: int = 200_000) -> list[dict[str, object]]:
    samples = voice_link_common_random_samples(seed, n_mc)
    rows: list[dict[str, object]] = []
    bw_hz = 31.25e3
    rb_bps = 2400.0
    threshold_db = voice_threshold_db(rb_bps)
    for sp in VOICE_LINK_SCENARIOS:
        key = str(sp["key"])
        sample = samples[key]
        python_proposed, _, _ = voice_link_availability(sp, sample)
        canonical = canonical_voice_metric(key, rb_bps)
        proposed = canonical["availability"]
        single_state, _, _ = voice_link_availability(sp, sample, force_single_state=True)
        if abs(python_proposed - proposed) > PYTHON_BASELINE_TOLERANCE:
            raise SystemExit(
                f"Python baseline differs from MATLAB/Simulink canonical for {key}: "
                f"{python_proposed:.6f} vs {proposed:.6f}"
            )
        p_los = float(sp.get("p_los", voice_link_plos_elevation(45.0, key)))
        avg_ebn0 = (
            float(ul_snr_db(bw_hz, float(sp["theta_mean"])))
            - (1.0 - p_los) * float(sp["extra_nlos_db"])
            + 10.0 * math.log10(bw_hz / rb_bps)
        )
        average_snr = 1.0 if avg_ebn0 >= threshold_db else 0.0
        rows.append(
            {
                "scenario": key,
                "scenario_label": sp["label"],
                "average_snr_margin_db": avg_ebn0 - threshold_db,
                "average_snr_screening_availability": average_snr,
                "single_state_lognormal_availability": single_state,
                "proposed_mixture_availability": proposed,
                "average_minus_proposed_pp": 100.0 * (average_snr - proposed),
                "single_state_minus_proposed_pp": 100.0 * (single_state - proposed),
                "p10_ebn0_db": canonical["p10_ebn0_db"],
                "median_ebn0_db": canonical["median_ebn0_db"],
            }
        )
    write_csv(GEO_OUT / "screening_baseline_comparison.csv", rows)

    labels = [str(r["scenario_label"]) for r in rows]
    x = np.arange(len(rows))
    width = 0.25
    fig, ax = plt.subplots(figsize=(7.2, 3.45))
    ax.bar(x - width, [100.0 * float(r["average_snr_screening_availability"]) for r in rows], width, label="Average SNR", color=COLORS["ub"])
    ax.bar(x, [100.0 * float(r["single_state_lognormal_availability"]) for r in rows], width, label="Single-state", color=COLORS["warn"])
    ax.bar(x + width, [100.0 * float(r["proposed_mixture_availability"]) for r in rows], width, label="Proposed mixture", color=COLORS["exact"])
    ax.set_xticks(x, labels, rotation=18, ha="right")
    ax.set_ylabel("2.4 kbps availability (%)")
    ax.set_ylim(0, 105)
    ax.set_title("Average-SNR and single-state screening distort low-tail availability", pad=24)
    polish_axes(ax)
    ax.legend(
        frameon=False,
        ncol=3,
        loc="lower center",
        bbox_to_anchor=(0.5, 1.005),
        borderaxespad=0.0,
    )
    fig.subplots_adjust(top=0.78, bottom=0.26)
    save_plot(fig, "geo_satphone_screening_baseline_comparison", paper_dir=VOICE_LINK_PLOTS, tight=False)
    return rows


def generate_screening_sensitivity_ranking(seed: int = 20260608, n_mc: int = 200_000) -> list[dict[str, object]]:
    samples = voice_link_common_random_samples(seed + 17, n_mc)
    base = {
        str(sp["key"]): voice_link_metrics(sp, samples[str(sp["key"])])
        for sp in VOICE_LINK_SCENARIOS
    }
    for key in list(base):
        canonical = canonical_voice_metric(key, 2400.0)
        if abs(float(base[key]["availability"]) - canonical["availability"]) > PYTHON_BASELINE_TOLERANCE:
            raise SystemExit(
                f"Python sensitivity baseline differs from MATLAB/Simulink canonical for {key}: "
                f"{base[key]['availability']:.6f} vs {canonical['availability']:.6f}"
            )
        base[key]["availability"] = canonical["availability"]
    tracked_doppler_loss_db = -20.0 * math.log10(max(abs(np.sinc(100.0 * 0.001)), 1e-6))
    specs = [
        ("NLOS excess loss", "+/-5 dB", [{"nlos_delta_db": 5.0}, {"nlos_delta_db": -5.0}]),
        ("LOS probability", "+/-0.10", [{"p_los_delta": -0.10}, {"p_los_delta": 0.10}]),
        ("Shadowing sigma", "+/-2 dB", [{"sigma_delta_db": 2.0}, {"sigma_delta_db": -2.0}]),
        ("Posture angle", "+/-10 deg", [{"theta_shift_deg": 10.0}, {"theta_shift_deg": -10.0}]),
        ("Voice threshold", "+/-2 dB", [{"threshold_delta_db": 2.0}, {"threshold_delta_db": -2.0}]),
        ("Rain/atmospheric loss", "+2 dB", [{"added_loss_db": 2.0}]),
        ("PA compression loss", "+3 dB", [{"added_loss_db": 3.0}]),
        ("Residual Doppler", "100 Hz tracked", [{"added_loss_db": tracked_doppler_loss_db}]),
    ]
    rows: list[dict[str, object]] = []
    scenario_lookup = {str(sp["key"]): sp for sp in VOICE_LINK_SCENARIOS}
    for parameter, perturbation, variants in specs:
        best_availability: dict[str, object] | None = None
        best_c0p01: dict[str, object] | None = None
        for variant in variants:
            for key, sp in scenario_lookup.items():
                stressed = voice_link_metrics(sp, samples[key], **variant)
                delta_pp = 100.0 * abs(stressed["availability"] - base[key]["availability"])
                delta_c0p01 = abs(stressed["c0p01_bit_per_s_hz"] - base[key]["c0p01_bit_per_s_hz"])
                if best_availability is None or delta_pp > float(best_availability["max_abs_availability_delta_pp"]):
                    best_availability = {
                        "parameter": parameter,
                        "perturbation": perturbation,
                        "scenario_at_max": sp["label"],
                        "baseline_availability": base[key]["availability"],
                        "stressed_availability": stressed["availability"],
                        "max_abs_availability_delta_pp": delta_pp,
                    }
                if best_c0p01 is None or delta_c0p01 > float(best_c0p01["max_abs_c0p01_delta_bit_per_s_hz"]):
                    best_c0p01 = {
                        "scenario_at_max_c0p01": sp["label"],
                        "baseline_c0p01_bit_per_s_hz": base[key]["c0p01_bit_per_s_hz"],
                        "stressed_c0p01_bit_per_s_hz": stressed["c0p01_bit_per_s_hz"],
                        "max_abs_c0p01_delta_bit_per_s_hz": delta_c0p01,
                    }
        assert best_availability is not None
        assert best_c0p01 is not None
        rows.append({**best_availability, **best_c0p01})
    rows.sort(key=lambda r: float(r["max_abs_availability_delta_pp"]), reverse=True)
    write_csv(GEO_OUT / "screening_sensitivity_ranking.csv", rows)

    fig, ax = plt.subplots(figsize=(7.2, 3.6))
    plot_rows = list(reversed(rows))
    labels = [str(r["parameter"]) for r in plot_rows]
    vals = [float(r["max_abs_availability_delta_pp"]) for r in plot_rows]
    colors = [COLORS["bad"] if v >= 20.0 else COLORS["warn"] if v >= 8.0 else COLORS["exact"] for v in vals]
    ax.barh(np.arange(len(plot_rows)), vals, color=colors, height=0.62)
    ax.set_yticks(np.arange(len(plot_rows)), labels)
    ax.set_xlabel("Maximum availability change across scenarios (percentage points)")
    ax.set_title("Global sensitivity ranking for 2.4 kbps low-tail screening")
    polish_axes(ax, "x")
    for i, row in enumerate(plot_rows):
        ax.text(vals[i] + 0.5, i, str(row["scenario_at_max"]), va="center", fontsize=7)
    ax.set_xlim(0, max(vals) + 12.0)
    save_plot(fig, "geo_satphone_sensitivity_ranking", paper_dir=VOICE_LINK_PLOTS)

    c_rows = sorted(rows, key=lambda r: float(r["max_abs_c0p01_delta_bit_per_s_hz"]), reverse=True)
    fig, ax = plt.subplots(figsize=(7.2, 3.6))
    plot_rows = list(reversed(c_rows))
    labels = [str(r["parameter"]) for r in plot_rows]
    vals = [float(r["max_abs_c0p01_delta_bit_per_s_hz"]) for r in plot_rows]
    colors = [COLORS["bad"] if v >= 0.12 else COLORS["warn"] if v >= 0.04 else COLORS["exact"] for v in vals]
    ax.barh(np.arange(len(plot_rows)), vals, color=colors, height=0.62)
    ax.set_yticks(np.arange(len(plot_rows)), labels)
    ax.set_xlabel(r"Maximum $C_{0.01}$ change across scenarios (bit/s/Hz)")
    ax.set_title(r"Global $C_{0.01}$ sensitivity ranking")
    polish_axes(ax, "x")
    for i, row in enumerate(plot_rows):
        ax.text(vals[i] + 0.006, i, str(row["scenario_at_max_c0p01"]), va="center", fontsize=7)
    ax.set_xlim(0, max(vals) + 0.10)
    save_plot(fig, "geo_satphone_c0p01_sensitivity_ranking", paper_dir=VOICE_LINK_PLOTS)
    return rows


def generate_dwell_time_sensitivity(seed: int = 20260608, frames: int = 15_000) -> list[dict[str, object]]:
    rng = np.random.default_rng(seed + 53)
    rows: list[dict[str, object]] = []
    slot_s = 1.0
    factors = [0.5, 1.0, 2.0]

    for sp in SCENARIOS:
        p_los = float(sp["p_los"])
        base_p_ll = float(sp["p_ll"])
        base_p_nn = retuned_p_nn(p_los, base_p_ll)
        base_nlos_dwell_s = slot_s / (1.0 - base_p_nn)
        for factor in factors:
            target_nlos_dwell_s = base_nlos_dwell_s * factor
            p_nn = float(np.clip(1.0 - slot_s / target_nlos_dwell_s, 0.001, 0.999))
            p_ll = float(np.clip((2.0 * p_los - 1.0 + p_nn * (1.0 - p_los)) / p_los, 0.001, 0.999))

            los = np.empty(frames, dtype=bool)
            los[0] = rng.random() < p_los
            for idx in range(1, frames):
                if los[idx - 1]:
                    los[idx] = rng.random() < p_ll
                else:
                    los[idx] = rng.random() >= p_nn

            nlos_lengths: list[int] = []
            run = 0
            for state in los:
                if not state:
                    run += 1
                elif run:
                    nlos_lengths.append(run)
                    run = 0
            if run:
                nlos_lengths.append(run)
            burst_s = np.asarray(nlos_lengths, dtype=float) * slot_s
            p95 = float(np.quantile(burst_s, 0.95)) if burst_s.size else 0.0
            max_burst = float(np.max(burst_s)) if burst_s.size else 0.0
            rows.append(
                {
                    "scenario": sp["key"],
                    "scenario_label": sp["label"],
                    "nlos_dwell_factor": factor,
                    "p_ll": p_ll,
                    "p_nn": p_nn,
                    "target_p_los": p_los,
                    "empirical_p_los": float(np.mean(los)),
                    "mean_los_dwell_s": slot_s / (1.0 - p_ll),
                    "mean_nlos_dwell_s": slot_s / (1.0 - p_nn),
                    "p95_nlos_burst_s": p95,
                    "max_nlos_burst_s": max_burst,
                }
            )

    write_csv(GEO_OUT / "dwell_time_sensitivity.csv", rows)

    fig, ax = plt.subplots(figsize=(7.2, 3.55))
    for sp in SCENARIOS:
        subset = [r for r in rows if r["scenario"] == sp["key"]]
        subset.sort(key=lambda r: float(r["nlos_dwell_factor"]))
        ax.plot(
            [float(r["nlos_dwell_factor"]) for r in subset],
            [float(r["p95_nlos_burst_s"]) for r in subset],
            marker="o",
            linewidth=1.7,
            label=str(sp["label"]),
        )
    ax.set_xlabel("NLOS mean-dwell multiplier")
    ax.set_ylabel("P95 NLOS burst length (s)")
    ax.set_title("Dwell-time sensitivity at fixed stationary LOS probability")
    ax.set_xticks(factors)
    polish_axes(ax)
    ax.legend(frameon=False, ncol=2, loc="upper left")
    save_plot(fig, "geo_satphone_dwell_time_sensitivity", paper_dir=VOICE_LINK_PLOTS)
    return rows


def copy_manuscript_plot_set() -> None:
    screening_stems = [
        "GEO_SBand_Voice_Link_Screening_Workflow_Refined",
        "geo_satphone_doppler_rain_sensitivity",
        "geo_satphone_voice_availability",
        "geo_satphone_voice_availability_band",
        "geo_satphone_screening_baseline_comparison",
        "geo_satphone_sensitivity_ranking",
        "geo_satphone_c0p01_sensitivity_ranking",
        "geo_satphone_dwell_time_sensitivity",
        "outage_capacity_sigma",
        "outage_capacity_scenarios",
        "outage_capacity_composite_fading",
        "geo_satphone_frequency_acquisition",
        "geo_satphone_pa_et_tradeoff",
        "geo_satphone_access_latency",
        "geo_satphone_geometry_plos",
        "geo_satphone_link_budget",
        "geo_satphone_urban_ablation",
        "geo_satphone_markov_stationary_alignment",
        "geo_satphone_public_d2c_inverse_alignment",
    ]
    for stem in screening_stems:
        copy_to_paper_plots(stem, VOICE_LINK_PLOTS)

def main() -> None:
    configure_voice_link_reference_inputs()
    artifacts = {
        "doppler_rain": generate_doppler_rain(),
        "markov_alignment": generate_markov_alignment(),
        "public_inverse_alignment": generate_public_inverse_alignment(),
        "reference_voice_availability": generate_reference_voice_availability_plot(),
        "voice_availability_band": generate_voice_availability_band(),
        "screening_baseline_comparison": generate_screening_baseline_comparison(),
        "screening_sensitivity_ranking": generate_screening_sensitivity_ranking(),
        "dwell_time_sensitivity": generate_dwell_time_sensitivity(),
    }
    copy_manuscript_plot_set()
    (SCREENING_OUT / "screening_analysis_results.json").write_text(
        json.dumps(artifacts, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print("voice-link screening artifacts generated")
    print(SCREENING_OUT / "screening_analysis_results.json")


if __name__ == "__main__":
    main()
