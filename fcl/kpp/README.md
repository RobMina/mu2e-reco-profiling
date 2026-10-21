# KPP data reco configuration (tests A7, A8, E6)

The KPP (extracted tracker + CRV test stand) data tests unpack and reconstruct one raw file of cosmic run 124155
(`raw.mu2e.trk.vst.124155_000001.art`, `inputs.txt` I7):

| File | Role |
|---|---|
| `unpack_data_vst.fcl` | raw -> digis (CFO event header, straw digis with ADC waveforms, CRV digis) |
| `unpack_data_vst_fullmap.fcl` | the same with the complete 216-panel tracker panel map |
| `unpack_data_vst_fullmap_head.fcl` | the same for Offline after 1a89014e8 (`addressing: byMnid`); used by `../base_kpp_unpack.fcl` |
| `reco_data_vst.fcl` | off-spill KKLine + CRV reco on the extracted geometry |
| `reco_data_vst_daqana.fcl` | the same with the run-124155 calibration set; used by `../base_kpp_data.fcl` |

**The calibration set is not in this repository.** It is Mu2e-internal and not in Offline: tracker panel map
(`TrkPanelMap_124155_full.txt`), tracker panel and straw preamp delays (`TrkDelayPanel_124155_v1.txt`,
`TrkPreampStraw_pass1.txt`), CRV SiPM and time calibrations (`CRVSiPM_pass1.txt`, `CRVTime_cid_303.txt`) and
`strawResponse_pass1.fcl`. Mu2e members can ask the author for it. Put the six files in one directory and set
`RP_KPP_CALIB` to it before running a KPP test; `env.sh` adds it to `FHICL_FILE_PATH` and `MU2E_SEARCH_PATH`, and
`grid/submit_profile.sh` ships it with the job. The simulation tests (A1-A6, A9, A10, B-F except E6) do not need it.
