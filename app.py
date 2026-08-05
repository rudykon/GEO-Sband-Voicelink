#!/usr/bin/env python3
"""Streamlit dashboard for GEO S-band voice-link screening."""
from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd
import streamlit as st


ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))

from dashboard_model import (  # noqa: E402
    evaluate_voice_link,
    figure_paths,
    load_scenarios,
    load_table,
    load_thresholds,
    sensitivity_rows,
)


st.set_page_config(
    page_title="GEO S-band Voice-Link Screening",
    layout="wide",
)


@st.cache_data(show_spinner=False)
def cached_scenarios() -> list[dict[str, object]]:
    return load_scenarios()


@st.cache_data(show_spinner=False)
def cached_thresholds() -> dict[float, float]:
    return load_thresholds()


@st.cache_data(show_spinner=False)
def cached_table(name: str, group: str = "voice_link") -> pd.DataFrame:
    return pd.DataFrame(load_table(name, group=group))


def pct(value: float) -> str:
    return f"{100.0 * value:.2f}%"


def metric_delta_pp(value: float) -> str:
    return f"{value:+.2f} pp"


st.title("GEO S-band Satellite Phone Voice-Link Screening")
st.caption(
    "Interactive scenario exploration for low-rate voice-bearer availability, "
    "low-tail Eb/N0, outage-capacity screening, and baseline distortion checks. "
    "This dashboard uses the public reference snapshot and does not require MATLAB."
)

scenarios = cached_scenarios()
thresholds = cached_thresholds()
scenario_by_label = {str(row["label"]): row for row in scenarios}

with st.sidebar:
    st.header("Scenario")
    selected_label = st.selectbox("Environment", list(scenario_by_label.keys()), index=2)
    scenario = scenario_by_label[selected_label]
    voice_rate = st.selectbox(
        "Voice bearer rate",
        sorted(thresholds),
        index=sorted(thresholds).index(2400.0),
        format_func=lambda rate: f"{rate/1000:.1f} kbps",
    )

    st.header("Trust-layer Proxies")
    p_los = st.slider("LOS probability", 0.01, 0.99, float(scenario["p_los"]), 0.01)
    nlos_loss = st.slider("NLOS excess loss (dB)", 0.0, 40.0, float(scenario["nlos_loss_db"]), 0.5)
    sigma_db = st.slider("Shadowing sigma (dB)", 0.5, 15.0, float(scenario["sigma_db"]), 0.5)
    theta_shift = st.slider("Posture/elevation shift (deg)", -20.0, 25.0, 0.0, 1.0)

    st.header("Implementation Margin")
    added_loss = st.slider("Added link loss (dB)", 0.0, 8.0, 0.0, 0.5)
    threshold_delta = st.slider("PHY threshold delta (dB)", -3.0, 5.0, 0.0, 0.5)
    n_samples = st.select_slider("Monte-Carlo samples", options=[20_000, 40_000, 80_000, 120_000], value=80_000)

result = evaluate_voice_link(
    scenario,
    voice_rate_bps=float(voice_rate),
    p_los=p_los,
    nlos_loss_db=nlos_loss,
    sigma_db=sigma_db,
    theta_mean_shift_deg=theta_shift,
    added_loss_db=added_loss,
    threshold_delta_db=threshold_delta,
    n_samples=int(n_samples),
)

baseline_availability = float(scenario["availability_2400"]) if float(voice_rate) == 2400.0 else None

cols = st.columns(5)
cols[0].metric("Availability", pct(result["availability"]))
cols[1].metric("P10 Eb/N0", f"{result['p10_ebn0_db']:.2f} dB")
cols[2].metric("Median Eb/N0", f"{result['median_ebn0_db']:.2f} dB")
cols[3].metric("C0.01", f"{result['c0p01_bit_per_s_hz']:.3f} bit/s/Hz")
cols[4].metric("Avg-SNR margin", f"{result['average_snr_margin_db']:.2f} dB")

if baseline_availability is not None:
    st.caption(
        f"Reference 2.4 kbps co-simulation availability for {selected_label}: "
        f"{100.0 * baseline_availability:.2f}%."
    )

comparison = pd.DataFrame(
    [
        {"method": "LOS/NLOS mixture", "availability_pct": 100.0 * result["availability"]},
        {"method": "Average-SNR screen", "availability_pct": 100.0 * result["average_snr_screening_availability"]},
        {"method": "Single-state lognormal", "availability_pct": 100.0 * result["single_state_lognormal_availability"]},
    ]
)

left, right = st.columns([1.05, 1.0])
with left:
    st.subheader("Screening Decision Comparison")
    st.bar_chart(comparison.set_index("method"), y="availability_pct", height=310)
    st.dataframe(comparison, hide_index=True, use_container_width=True)

with right:
    st.subheader("Sensitivity Around Selected Scenario")
    sens = pd.DataFrame(sensitivity_rows(scenario, voice_rate_bps=float(voice_rate), n_samples=40_000))
    st.bar_chart(sens.set_index("parameter"), y="delta_pp", height=310)
    st.dataframe(sens, hide_index=True, use_container_width=True)

st.subheader("Reference Result Tables")
tab_base, tab_rank, tab_dwell = st.tabs(["Baseline comparison", "Sensitivity ranking", "Dwell-time"])
with tab_base:
    baseline = cached_table("screening_baseline_comparison.csv")
    st.dataframe(baseline, hide_index=True, use_container_width=True)
    st.download_button(
        "Download baseline CSV",
        baseline.to_csv(index=False).encode("utf-8"),
        "screening_baseline_comparison.csv",
        "text/csv",
    )
with tab_rank:
    ranking = cached_table("screening_sensitivity_ranking.csv")
    st.dataframe(ranking, hide_index=True, use_container_width=True)
    st.download_button(
        "Download sensitivity CSV",
        ranking.to_csv(index=False).encode("utf-8"),
        "screening_sensitivity_ranking.csv",
        "text/csv",
    )
with tab_dwell:
    dwell = cached_table("dwell_time_sensitivity.csv")
    st.dataframe(dwell, hide_index=True, use_container_width=True)
    st.download_button(
        "Download dwell-time CSV",
        dwell.to_csv(index=False).encode("utf-8"),
        "dwell_time_sensitivity.csv",
        "text/csv",
    )

st.subheader("Reference Figure Gallery")
figs = figure_paths(
    [
        "GEO_SBand_Voice_Link_Screening_Workflow_Refined.png",
        "geo_satphone_screening_baseline_comparison.png",
        "geo_satphone_sensitivity_ranking.png",
        "geo_satphone_dwell_time_sensitivity.png",
        "outage_capacity_scenarios.png",
    ]
)
gallery_cols = st.columns(2)
for idx, (name, path) in enumerate(figs.items()):
    with gallery_cols[idx % 2]:
        st.image(str(path), caption=name.replace("_", " ").replace(".png", ""), use_column_width=True)

with st.expander("Output layout"):
    st.markdown(
        """
        - Generated data: `outputs/data/voice_link/`, `outputs/data/outage_capacity/`,
          `outputs/data/screening_analysis/`, `outputs/data/reference_cosim/`
        - Generated figures: `outputs/figures/all/` and `outputs/figures/screening_report/`
        - Committed reference data and figures: `expected_outputs/data/` and `expected_outputs/figures/`
        """
    )
